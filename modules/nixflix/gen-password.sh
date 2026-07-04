#!/usr/bin/env bash
read -p "Enter password: " password
echo $password
echo "@ByteArray($(nix run git+https://codeberg.org/feathecutie/qbittorrent_password -- -p $password))"
    