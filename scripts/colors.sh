#!/usr/bin/env bash

export RED='\033[1;31m'
export YELLOW='\033[1;33m'
export GREEN='\033[1;32m'
export RESET='\033[0m'

print_error() {
    printf "${RED}ERROR: $1${RESET}\n" >&2
}

print_warning() {
    printf "${YELLOW}WARNING: $1${RESET}\n"
}

print_success() {
    printf "${GREEN}OK: $1${RESET}\n"
}

print_info() {
    printf "$1\n"
}