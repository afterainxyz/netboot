#!/bin/bash
source device_module.sh
source log.sh
source img.sh
source net.sh
source iso.sh
source service.sh

function usage() {
    local proc=$(basename $0)
    log -i "Uasge:"
    log -i "  $proc [command]"
    log -i "  -h,--help                       print this help message"
    log -i ""
    log -i "Available Commands:"
    log -i "  probe                           probe device id"
    log -i "  add <device_id> [options]"
    log -i "      <device_id>                 example(pc: 01-00-0c-29-4f-62-c7, raspberry pi: 7092246e)"
    log -i "      options: --node-address     address of static network(CIDR format. example: 192.168.0.6/24)"
    log -i "      options: --node-gateway     gateway of static network(example: 192.168.0.1)"
    log -i "      options: --node-dns         dns(example: 192.168.0.1)"
}

function check_depends() {
    local commands=(awk cat cp kpartx losetup mkdir mount mv grep systemctl tar targetcli tee wget xz)
    local not_exist_commands=()

    log --warn "checking depends"
    for c in ${commands[@]}; do
        has_command $c
        if [ $? -ne 0 ]; then
            not_exist_commands[${#not_exist_commands[@]}]=$c
        fi
    done

    if [ ${#not_exist_commands[@]} -gt 0 ]; then
        log --error "commands are not exist: ${not_exist_commands[@]}"
        return 1
    fi

    log --success "depends ok"
    return 0
}

function prepare_dist_dir() {
    #|--dist
    #   |--download
    #      |--tmp
    local dist_dir=$1/dist

    mkdir -p $dist_dir/download/tmp

    #/var/homelab
    #     |--tftproot
    #     |--httproot
    #     |--iscsiroot
    mkdir -p /var/homelab/tftproot
    mkdir -p /var/homelab/httproot
    mkdir -p /var/homelab/iscsiroot
}

function check_services() {
    local services=(dnsmasq nginx)

    for s in ${services[@]}; do
        service_enable_if_disabled $s
        if [ $? -ne 0 ]; then
            log --error "enable $s service failed"
            return 1
        fi
    done

    return 0
}

function configure_dhcp_and_tftp() {
    cat <<EOF | tee download/tmp/dnsmasq.conf 2>&1 1>/dev/null
port=0
log-dhcp
dhcp-range=$(get_default_broadcast),proxy
enable-tftp
tftp-root="/var/homelab/tftproot"
pxe-service=X86PC,"Boot x86 BIOS",lpxelinux.0
pxe-service=X86PC,"Raspberry Pi Boot"
pxe-service=X86-64_EFI,"PXELINUX (EFI 64)",efi64/syslinux.efi
pxe-service=IA64_EFI,"PXELINUX (EFI 64)",efi64/syslinux.efi
pxe-service=IA32_EFI,"PXELINUX (EFI 32)",efi32/syslinux.efi
pxe-prompt="PXE",0
EOF
    diff download/tmp/dnsmasq.conf /etc/dnsmasq.conf 2>&1 1>/dev/null
    if [ $? -ne 0 ]; then
        mv /etc/dnsmasq.conf /etc/dnsmasq.conf.$(date '+%Y%m%d_%H%M%S')
        cp download/tmp/dnsmasq.conf /etc/dnsmasq.conf
        service_restart 'dnsmasq'
    else
        service_restart_if_inactive 'dnsmasq'
    fi

    return $?
}

function configure_http() {
    cat <<EOF | tee download/tmp/nginx-homelab.conf 2>&1 1>/dev/null
server {
	listen 12345 default_server;
	listen [::]:12345 default_server;
	root /var/homelab/httproot;
	server_name _;
}
EOF
    diff download/tmp/nginx-homelab.conf /etc/nginx/sites-enabled/nginx-homelab.conf 2>&1 1>/dev/null
    if [ $? -ne 0 -o -f /etc/nginx/sites-enabled/default ]; then
        rm -rf /etc/nginx/sites-enabled/default
        cp download/tmp/nginx-homelab.conf /etc/nginx/sites-enabled/
        service_restart 'nginx'
    else
        service_restart_if_inactive 'nginx'
    fi

    return $?
}

function configure_services() {
    local ret

    configure_dhcp_and_tftp
    if [ $? -ne 0 ]; then
        return 1
    fi

    configure_http
    if [ $? -ne 0 ]; then
        return 1
    fi
}

function install_bootloader() {
    local tftproot="/var/homelab/tftproot"
    local download_file="download/syslinux-6.04-pre1.tar.xz"
    local syslinux_dir_prefix="syslinux-6.04-pre1"
    local bootloader_files=($tftproot/lpxelinux.0 $tftproot/ldlinux.c32 $tftproot/efi64/syslinux.efi $tftproot/efi64/ldlinux.e64 $tftproot/efi32/syslinux.efi $tftproot/efi32/ldlinux.e32)
    local miss_file=0

    for f in ${bootloader_files[@]}; do
        if [ ! -f $f ]; then
            miss_file=1
        fi
    done
    if [ $miss_file -eq 0 ]; then
        return 0
    fi

    log --warn "installing bootloader"
    log --warn "  downloading syslinux"
    syslinux_url="https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.xz"
    retry 3 download $syslinux_url $download_file
    if [ $? -ne 0 ]; then
        log --error "  download syslinux error"
        return 1
    fi

    log --warn "  extracting syslinux"
    extract_from_tar $download_file $syslinux_dir_prefix/bios/core/lpxelinux.0 $syslinux_dir_prefix/bios/com32/elflink/ldlinux/ldlinux.c32
    extract_from_tar $download_file $syslinux_dir_prefix/efi64/efi/syslinux.efi $syslinux_dir_prefix/efi64/com32/elflink/ldlinux/ldlinux.e64
    extract_from_tar $download_file $syslinux_dir_prefix/efi32/efi/syslinux.efi $syslinux_dir_prefix/efi32/com32/elflink/ldlinux/ldlinux.e32
    if [ $? -ne 0 ]; then
        log --error "  extract syslinux error"
        return 1
    fi

    log --warn "  installing syslinux"
    rm -rf download/tmp/$syslinux_dir_prefix
    mv -f $syslinux_dir_prefix download/tmp
    mv -f download/tmp/$syslinux_dir_prefix/bios/core/lpxelinux.0 $tftproot
    mv -f download/tmp/$syslinux_dir_prefix/bios/com32/elflink/ldlinux/ldlinux.c32 $tftproot
    mkdir -p $tftproot/efi64
    mv -f download/tmp/$syslinux_dir_prefix/efi64/efi/syslinux.efi $tftproot/efi64
    mv -f download/tmp/$syslinux_dir_prefix/efi64/com32/elflink/ldlinux/ldlinux.e64 $tftproot/efi64
    mkdir -p $tftproot/efi32
    mv -f download/tmp/$syslinux_dir_prefix/efi32/efi/syslinux.efi $tftproot/efi32
    mv -f download/tmp/$syslinux_dir_prefix/efi32/com32/elflink/ldlinux/ldlinux.e32 $tftproot/efi32

    log --success  "install bootloader done"
    return 0
}

function main() {
    local cmd=$1
    local node_address
    local node_gateway
    local node_dns
    local device_id
    local answer
    local ret1
    local ret2

    device_module_init 'device_module'
    if [ $# -eq 0 ]; then
        cmd="probe"
    fi
    if [ "$cmd" != "add" -a "$cmd" != "probe" ]; then
        usage
        return 1
    fi
    if [ "$cmd" == "add" ]; then
        device_check_id $2
        if [ $? -ne 0 ]; then
            usage
            return 1
        fi
        device_id=$2
    fi
    ARGS=$(getopt -l "node-address:,node-gateway:,node-dns:,help" -a -o "h" -- "$@")
    while [ ! -z "$1" ]; do
        case "$1" in
        -h | --help)
            usage
            return 0
            ;;
        --node-address)
            node_address=$2
            shift
            ;;
        --node-gateway)
            node_gateway=$2
            shift
            ;;
        --node-dns)
            node_dns=$2
            shift
            ;;
        *) ;;
        esac
        shift
    done

    check_depends
    if [ $? -ne 0 ]; then
        return 1
    fi

    work_dir=$(cd $(dirname $0) && pwd)
    prepare_dist_dir $work_dir
    cd $work_dir/dist

    check_services
    if [ $? -ne 0 ]; then
        return 1
    fi
    configure_services
    if [ $? -ne 0 ]; then
        return 1
    fi
    install_bootloader
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [ "$cmd" == "probe" ]; then
        while true; do
            log --warn "probing device..."
            while read line; do
                device_id=$(device_probe "$line")
                if [ ! -z "$device_id" ]; then
                    break
                fi
            done < <(tail -n 1 -f /var/log/syslog | grep --line-buffered dnsmasq)

            echo -n "add $device_id ?[<enter:probe next>|yes]"
            read answer
            if [ "$answer" == "yes" ]; then
                device_add $device_id $(get_default_ip) 12345 $node_address $node_gateway $node_dns
            fi
        done
    else
        device_add $device_id $(get_default_ip) 12345 $node_address $node_gateway $node_dns
    fi

    return 0
}

if [ -n "$BASH_SOURCE" -a "$BASH_SOURCE" == "$0" ]; then
    if [ "$(id -u)" != "0" ]; then
        log --error "need root privilege"
        exit 1
    fi

    main $@
fi
