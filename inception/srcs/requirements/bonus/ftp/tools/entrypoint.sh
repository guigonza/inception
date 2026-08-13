#!/usr/bin/env bash
set -euo pipefail

FTP_PASSWORD="$(cat /run/secrets/ftp_password)"

grep -qxF /usr/sbin/nologin /etc/shells || echo /usr/sbin/nologin >> /etc/shells

if ! id "${FTP_USER}" >/dev/null 2>&1; then
  useradd -d /var/www/html -g www-data -s /usr/sbin/nologin "${FTP_USER}"
fi
echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd

chmod -R g+w /var/www/html

exec /usr/sbin/vsftpd /etc/vsftpd.conf
