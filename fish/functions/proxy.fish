function proxy --description "Enable Clash proxy"
    set -gx HTTP_PROXY http://127.0.0.1:7890
    set -gx HTTPS_PROXY http://127.0.0.1:7890
    set -gx ALL_PROXY socks5://127.0.0.1:7890
    echo -e "\033[0;32m[✓] Proxy enabled\033[0m"
end
