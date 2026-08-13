#!/usr/bin/env bash
set -euo pipefail

mkdir -p /etc/nginx/certs
if [ ! -f /etc/nginx/certs/server.crt ]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/certs/server.key \
    -out /etc/nginx/certs/server.crt \
    -subj "/CN=${DOMAIN_NAME}" >/dev/null 2>&1
fi

exec nginx -g 'daemon off;'
