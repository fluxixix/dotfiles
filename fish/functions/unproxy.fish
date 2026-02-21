function unproxy --description "Disable Clash proxy"
    set -e HTTP_PROXY
    set -e HTTPS_PROXY
    set -e ALL_PROXY
    echo -e "\033[0;31m[✗] Proxy disabled\033[0m"
end
