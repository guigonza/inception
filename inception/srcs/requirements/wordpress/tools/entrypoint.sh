#!/usr/bin/env bash
set -euo pipefail

MYSQL_PASSWORD="$(cat /run/secrets/db_password)"
WP_ADMIN_PASSWORD="$(grep '^WP_ADMIN_PASSWORD=' /run/secrets/credentials | cut -d= -f2-)"
WP_USER_PASSWORD="$(grep '^WP_USER_PASSWORD=' /run/secrets/credentials | cut -d= -f2-)"

mkdir -p /var/www/html

for d in /etc/php/*/fpm; do
  mkdir -p "$d/pool.d"
  cat > "$d/pool.d/www.conf" <<CONF
[www]
user = www-data
group = www-data
listen = 0.0.0.0:9000
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
CONF
done

if [ ! -f /var/www/html/wp-config.php ]; then
  echo "Bootstrapping WordPress files..."
  curl -fsSL https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
  tar -xzf /tmp/wordpress.tar.gz -C /tmp
  cp -a /tmp/wordpress/. /var/www/html/
  rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
  chown -R www-data:www-data /var/www/html

  echo "Waiting for mariadb..."
  until mysqladmin ping -h mariadb -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent; do
    sleep 1
  done

  cd /var/www/html
  cp wp-config-sample.php wp-config.php
  sed -i "s/database_name_here/${MYSQL_DATABASE}/" wp-config.php
  sed -i "s/username_here/${MYSQL_USER}/" wp-config.php
  sed -i "s/password_here/${MYSQL_PASSWORD}/" wp-config.php
  sed -i "s/localhost/mariadb/" wp-config.php
  curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> wp-config.php

  export PATH="${PATH}:/usr/local/bin"
  wp core install --url="https://${DOMAIN_NAME}" --title="${WP_TITLE}" --admin_user="${WP_ADMIN_USER}" --admin_password="${WP_ADMIN_PASSWORD}" --admin_email="${WP_ADMIN_EMAIL}" --path=/var/www/html --allow-root
  wp user create "${WP_USER}" "${WP_USER}@${DOMAIN_NAME}" --user_pass="${WP_USER_PASSWORD}" --role=author --path=/var/www/html --allow-root

  # Bonus: only wired up when the "redis" container is actually reachable on the network
  # (i.e. the stack was started with the "bonus" compose profile). This keeps the
  # mandatory-only stack fully functional even though the plugin is always attempted here.
  if getent hosts redis >/dev/null 2>&1; then
    echo "Redis detected - enabling WordPress object cache..."
    REDIS_PASSWORD="$(cat /run/secrets/redis_password)"
    wp plugin install redis-cache --activate --path=/var/www/html --allow-root
    wp config set WP_REDIS_HOST redis --path=/var/www/html --allow-root
    wp config set WP_REDIS_PASSWORD "${REDIS_PASSWORD}" --path=/var/www/html --allow-root
    wp redis enable --path=/var/www/html --allow-root || true
  fi

  chown -R www-data:www-data /var/www/html
fi

if command -v php-fpm >/dev/null 2>&1; then
  exec php-fpm --nodaemonize
elif command -v php-fpm8.2 >/dev/null 2>&1; then
  exec php-fpm8.2 --nodaemonize
else
  exec /usr/sbin/php-fpm --nodaemonize
fi
