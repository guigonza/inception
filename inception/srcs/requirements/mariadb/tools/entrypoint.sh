#!/usr/bin/env bash
set -euo pipefail

MYSQL_PASSWORD="$(cat /run/secrets/db_password)"
MYSQL_ROOT_PASSWORD="$(cat /run/secrets/db_root_password)"

mkdir -p /var/lib/mysql
chown -R mysql:mysql /var/lib/mysql

# Debian normally has systemd create this at boot (tmpfiles.d); since we exec mysqld
# directly with no systemd in the container, nobody creates it otherwise, and mysqld
# fails with "Bind on unix socket: No such file or directory" on every single start.
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

if [ ! -d /var/lib/mysql/mysql ]; then
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null

  /usr/sbin/mysqld --user=mysql --bootstrap <<SQL
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE};
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'%';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
fi

exec /usr/sbin/mysqld --user=mysql
