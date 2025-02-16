#!/bin/bash

function log() {
    local level=$1
    shift 1

    case "$level" in
    -i | --info)
        echo -e "\033[37m$@\033[0m"
        ;;
    -w | --warn)
        echo -e "\033[33m$@\033[0m"
        ;;
    -s | --success)
        echo -e "\033[32m$@\033[0m"
        ;;
    -e | --error)
        echo -e "\033[31m$@\033[0m"
        ;;
    *)
        echo -e "\033[31mlog() error: level($level) not exist\033[0m"
        ;;
    esac
}
