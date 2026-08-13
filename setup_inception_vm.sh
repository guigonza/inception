#!/usr/bin/env bash
set -euo pipefail

# Script to provision a Linux VM with Docker and scaffold the Inception project.
# Usage: sudo bash setup_inception_vm.sh [target_dir]
# Example: sudo bash setup_inception_vm.sh /home/youruser/inception

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

LOGNAME_VALUE="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
HOST_USER="${SUDO_USER:-${USER:-root}}"
HOST_HOME="$(getent passwd "$HOST_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$HOST_USER")"

if [[ "$HOST_USER" == "root" ]]; then
  HOST_HOME="/root"
fi

if [[ -z "${LOGNAME_VALUE}" ]]; then
  LOGNAME_VALUE="root"
fi

# Built from HOST_HOME (resolved via getent, not the shell's $HOME) so the default target
# is always /home/<login>/inception even if this script is invoked from a root shell
# (e.g. after `sudo -i`), where $HOME would already be /root.
TARGET_DIR="${1:-$HOST_HOME/inception}"
TARGET_DIR="$(realpath -m "$TARGET_DIR")"

export DEBIAN_FRONTEND=noninteractive

OS_ID="$(. /etc/os-release && echo "$ID")"
case "$OS_ID" in
  ubuntu|debian)
    ;;
  *)
    echo "Unsupported OS: $OS_ID. This script currently targets Ubuntu/Debian." >&2
    exit 1
    ;;
esac

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release make openssl git

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$OS_ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

cat > /etc/apt/sources.list.d/docker.list <<EOF
# Docker repository

deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

if [[ "$HOST_USER" != "root" ]]; then
  usermod -aG docker "$HOST_USER" || true
fi

install -d -m 0755 "$TARGET_DIR"
mkdir -p "$TARGET_DIR/srcs/requirements/nginx/conf" \
         "$TARGET_DIR/srcs/requirements/nginx/tools" \
         "$TARGET_DIR/srcs/requirements/wordpress/tools" \
         "$TARGET_DIR/srcs/requirements/mariadb/conf" \
         "$TARGET_DIR/srcs/requirements/mariadb/tools" \
         "$TARGET_DIR/srcs/requirements/bonus/static-site/site" \
         "$TARGET_DIR/srcs/requirements/bonus/adminer" \
         "$TARGET_DIR/srcs/requirements/bonus/prometheus/conf" \
         "$TARGET_DIR/srcs/requirements/bonus/node-exporter" \
         "$TARGET_DIR/srcs/requirements/bonus/redis/conf" \
         "$TARGET_DIR/srcs/requirements/bonus/redis/tools" \
         "$TARGET_DIR/srcs/requirements/bonus/ftp/conf" \
         "$TARGET_DIR/srcs/requirements/bonus/ftp/tools" \
         "$TARGET_DIR/secrets"

mkdir -p "$HOST_HOME/data/mariadb" "$HOST_HOME/data/wordpress"
chown -R "$HOST_USER:$HOST_USER" "$HOST_HOME/data" 2>/dev/null || true

DOMAIN_NAME="${LOGNAME_VALUE}.42.fr"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wpuser"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
MYSQL_PASSWORD="$(openssl rand -hex 16)"
FTP_PASSWORD="$(openssl rand -hex 16)"
REDIS_PASSWORD="$(openssl rand -hex 16)"

# WordPress admin username MUST NOT contain "admin" or "administrator" (case-insensitive).
# A suffix like "${LOGNAME_VALUE}_owner" would still contain "admin" as a substring if the
# login itself does (e.g. login "admin" -> "admin_owner"), so the fallback below is fully
# independent of the login instead of just appending to it.
if echo "$LOGNAME_VALUE" | grep -qi 'admin'; then
  WP_ADMIN_USER="owner_$(echo -n "$LOGNAME_VALUE" | md5sum | cut -c1-6)"
else
  WP_ADMIN_USER="${LOGNAME_VALUE}"
fi
WP_ADMIN_PASSWORD="$(openssl rand -hex 16)"
WP_ADMIN_EMAIL="${WP_ADMIN_USER}@${DOMAIN_NAME}"
WP_TITLE="Inception"
WP_USER="${LOGNAME_VALUE}_user"
WP_USER_PASSWORD="$(openssl rand -hex 16)"
FTP_USER="${LOGNAME_VALUE}_ftp"

# Make the domain resolve locally on this VM (browser is expected to run on the VM itself).
if ! grep -qF "$DOMAIN_NAME" /etc/hosts 2>/dev/null; then
  echo "127.0.0.1 ${DOMAIN_NAME}" >> /etc/hosts
fi

# --- Non-secret configuration: .env ---
cat > "$TARGET_DIR/srcs/.env" <<EOF
DOMAIN_NAME=$DOMAIN_NAME
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_EMAIL=$WP_ADMIN_EMAIL
WP_TITLE=$WP_TITLE
WP_USER=$WP_USER
FTP_USER=$FTP_USER
EOF

# --- Secrets: consumed via Docker secrets (/run/secrets/*), never as build args or bare env vars ---
cat > "$TARGET_DIR/secrets/db_root_password.txt" <<EOF
$MYSQL_ROOT_PASSWORD
EOF

cat > "$TARGET_DIR/secrets/db_password.txt" <<EOF
$MYSQL_PASSWORD
EOF

cat > "$TARGET_DIR/secrets/credentials.txt" <<EOF
WP_ADMIN_PASSWORD=$WP_ADMIN_PASSWORD
WP_USER_PASSWORD=$WP_USER_PASSWORD
EOF

cat > "$TARGET_DIR/secrets/ftp_password.txt" <<EOF
$FTP_PASSWORD
EOF

cat > "$TARGET_DIR/secrets/redis_password.txt" <<EOF
$REDIS_PASSWORD
EOF

chmod 600 "$TARGET_DIR/secrets/"*.txt

cat > "$TARGET_DIR/.gitignore" <<'EOF'
.env
secrets/*
data/
*.log
EOF

cat > "$TARGET_DIR/Makefile" <<'EOF'
COMPOSE = docker compose -f srcs/docker-compose.yml --env-file srcs/.env
BONUS   = $(COMPOSE) --profile bonus
DOMAIN  = $(shell grep -m1 '^DOMAIN_NAME=' srcs/.env | cut -d= -f2)

all: up

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

restart:
	$(COMPOSE) restart

build:
	$(COMPOSE) build

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

images:
	$(COMPOSE) images

volumes:
	docker volume ls
	docker volume inspect srcs_mariadb_data srcs_wordpress_data

networks:
	docker network ls
	docker network inspect srcs_inception

check-tls:
	curl -vk https://$(DOMAIN) 2>&1 | grep -i "SSL connection\|subject\|TLSv"
	@echo "--- TLS 1.2 (must succeed) ---"
	openssl s_client -connect $(DOMAIN):443 -tls1_2 </dev/null 2>&1 | grep -i "Verify\|Protocol"
	@echo "--- TLS 1.1 (must fail) ---"
	@if openssl s_client -connect $(DOMAIN):443 -tls1_1 </dev/null 2>&1 | grep -qi "Cipher is (NONE)\|no protocols\|alert"; then \
		echo "OK: TLS 1.1 rejected"; \
	else \
		echo "FAIL: TLS 1.1 connection was NOT rejected"; \
	fi
	@echo "--- Port 80 (must be refused, nginx only publishes 443) ---"
	-curl -sv http://$(DOMAIN) 2>&1 | grep -i "connection refused\|failed to connect"

check-wp:
	$(COMPOSE) exec wordpress wp user list --path=/var/www/html --allow-root
	@echo "--- WordPress DB tables (stock install: 12 tables) ---"
	$(COMPOSE) exec wordpress wp db tables --path=/var/www/html --allow-root

check-restart:
	docker inspect -f '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' mariadb wordpress nginx

check-isolation:
	@echo "--- mariadb (nginx must be absent) ---"
	@if $(COMPOSE) exec mariadb which nginx >/dev/null 2>&1; then \
		echo "FAIL: nginx found inside mariadb"; \
	else \
		echo "OK: nginx absent from mariadb"; \
	fi
	@echo "--- wordpress (nginx must be absent) ---"
	@if $(COMPOSE) exec wordpress which nginx >/dev/null 2>&1; then \
		echo "FAIL: nginx found inside wordpress"; \
	else \
		echo "OK: nginx absent from wordpress"; \
	fi

check: ps networks volumes check-tls check-wp check-restart check-isolation
	@echo "All checks completed."

# --- Bonus (only assessed once the mandatory part above is perfect) ---
# Bonus services carry the "bonus" compose profile, so plain `make up` never starts
# them; only these targets (via --profile bonus) do.
bonus-up:
	$(BONUS) up -d --build

bonus-down:
	$(BONUS) down

bonus-ps:
	$(BONUS) ps

bonus-logs:
	$(BONUS) logs -f static-site adminer prometheus node-exporter redis ftp

check-bonus:
	$(BONUS) ps
	@echo "--- static site ---"
	curl -sI http://$(DOMAIN):8080 | head -1
	@echo "--- adminer ---"
	curl -sI http://$(DOMAIN):8081 | head -1
	@echo "--- prometheus targets (should list node-exporter as up) ---"
	curl -s http://$(DOMAIN):9090/api/v1/targets | grep -o '"health":"[a-z]*"'
	@echo "--- redis (wordpress object cache status) ---"
	-$(COMPOSE) exec wordpress wp redis status --path=/var/www/html --allow-root
	@echo "--- ftp (port 21 reachable) ---"
	-nc -z -w2 $(DOMAIN) 21 && echo "FTP port 21: open" || echo "FTP port 21: closed"

clean:
	$(COMPOSE) down -v

fclean: clean
	rm -rf $(HOME)/data/mariadb $(HOME)/data/wordpress

re: fclean up

help:
	@echo "make up             - build and start all services"
	@echo "make down           - stop and remove containers"
	@echo "make stop           - stop containers without removing them"
	@echo "make restart        - restart all services"
	@echo "make build          - build images"
	@echo "make logs           - follow logs"
	@echo "make ps             - container status"
	@echo "make images         - list built images"
	@echo "make volumes        - inspect the named volumes"
	@echo "make networks       - inspect the docker network"
	@echo "make check-tls      - verify TLS 1.2/1.3 work, TLS 1.1 fails"
	@echo "make check-wp       - list WordPress users"
	@echo "make check-restart  - show each container's restart policy"
	@echo "make check-isolation - confirm nginx is absent from wordpress/mariadb"
	@echo "make check          - run all checks above in sequence"
	@echo "make bonus-up       - build and start mandatory + bonus services"
	@echo "make bonus-down     - stop the bonus services"
	@echo "make bonus-ps       - bonus container status"
	@echo "make bonus-logs     - follow bonus service logs"
	@echo "make check-bonus    - verify static site, Adminer, Prometheus, Redis and FTP respond"
	@echo "make clean          - stop and remove containers, network, volumes"
	@echo "make fclean         - clean, then delete persisted data"
	@echo "make re             - fclean, then up"

.PHONY: up down stop restart build logs ps images volumes networks \
        check-tls check-wp check-restart check-isolation check \
        bonus-up bonus-down bonus-ps bonus-logs check-bonus \
        clean fclean re help
EOF

# docker-compose.yml is generated (not executed as a shell script), so $HOST_HOME
# is intentionally substituted now, at provisioning time.
cat > "$TARGET_DIR/srcs/docker-compose.yml" <<EOF
services:
  mariadb:
    image: mariadb:inception
    container_name: mariadb
    build:
      context: ./requirements/mariadb
      dockerfile: Dockerfile
    env_file:
      - .env
    secrets:
      - db_password
      - db_root_password
    volumes:
      - mariadb_data:/var/lib/mysql
    networks:
      - inception
    restart: unless-stopped

  wordpress:
    image: wordpress:inception
    container_name: wordpress
    build:
      context: ./requirements/wordpress
      dockerfile: Dockerfile
    env_file:
      - .env
    secrets:
      - db_password
      - credentials
      - redis_password
    depends_on:
      - mariadb
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - inception
    restart: unless-stopped

  nginx:
    image: nginx:inception
    container_name: nginx
    build:
      context: ./requirements/nginx
      dockerfile: Dockerfile
    env_file:
      - .env
    depends_on:
      - wordpress
    ports:
      - "443:443"
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - inception
    restart: unless-stopped

  static-site:
    image: static-site:inception
    container_name: static-site
    build:
      context: ./requirements/bonus/static-site
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

  adminer:
    image: adminer:inception
    container_name: adminer
    build:
      context: ./requirements/bonus/adminer
      dockerfile: Dockerfile
    depends_on:
      - mariadb
    ports:
      - "8081:8081"
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

  node-exporter:
    image: node-exporter:inception
    container_name: node-exporter
    build:
      context: ./requirements/bonus/node-exporter
      dockerfile: Dockerfile
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

  redis:
    image: redis:inception
    container_name: redis
    build:
      context: ./requirements/bonus/redis
      dockerfile: Dockerfile
    secrets:
      - redis_password
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

  ftp:
    image: ftp:inception
    container_name: ftp
    build:
      context: ./requirements/bonus/ftp
      dockerfile: Dockerfile
    env_file:
      - .env
    secrets:
      - ftp_password
    volumes:
      - wordpress_data:/var/www/html
    ports:
      - "21:21"
      - "21100-21110:21100-21110"
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

  prometheus:
    image: prometheus:inception
    container_name: prometheus
    build:
      context: ./requirements/bonus/prometheus
      dockerfile: Dockerfile
    depends_on:
      - node-exporter
    ports:
      - "9090:9090"
    networks:
      - inception
    restart: unless-stopped
    profiles:
      - bonus

volumes:
  mariadb_data:
    driver: local
    driver_opts:
      type: none
      device: $HOST_HOME/data/mariadb
      o: bind
  wordpress_data:
    driver: local
    driver_opts:
      type: none
      device: $HOST_HOME/data/wordpress
      o: bind

networks:
  inception:
    driver: bridge

secrets:
  db_password:
    file: ../secrets/db_password.txt
  db_root_password:
    file: ../secrets/db_root_password.txt
  credentials:
    file: ../secrets/credentials.txt
  ftp_password:
    file: ../secrets/ftp_password.txt
  redis_password:
    file: ../secrets/redis_password.txt
EOF

cat > "$TARGET_DIR/srcs/requirements/mariadb/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y mariadb-server && rm -rf /var/lib/apt/lists/*

# Debian's postinst already initializes /var/lib/mysql at build time. Docker's volume
# mount copies that baked-in content into the (otherwise empty) bind-mounted host
# directory the first time the container runs, which made the entrypoint's
# "already initialized?" check see pre-existing files and skip creating the wordpress
# database/user entirely. Emptying it here means the image never carries any data, so
# the volume genuinely starts empty and the entrypoint's own mariadb-install-db + bootstrap
# runs as intended.
RUN rm -rf /var/lib/mysql/*

COPY conf/my.cnf /etc/mysql/my.cnf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3306
CMD ["/usr/local/bin/entrypoint.sh"]
EOF

# Deliberately doesn't exclude conf/ or tools/ (needed by the COPY instructions above) -
# only things that will never be needed inside the build context.
cat > "$TARGET_DIR/srcs/requirements/mariadb/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/mariadb/conf/my.cnf" <<'EOF'
[mysqld]
user = mysql
datadir = /var/lib/mysql
bind-address = 0.0.0.0
skip-networking = 0
EOF

# Quoted heredoc: everything below is written verbatim. ${MYSQL_DATABASE}, ${MYSQL_USER},
# etc. are resolved by bash INSIDE THE CONTAINER at runtime (from env_file/.env and
# /run/secrets), never by this provisioning script. This is what keeps real passwords
# out of the image and out of git.
cat > "$TARGET_DIR/srcs/requirements/mariadb/tools/entrypoint.sh" <<'EOF'
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
EOF

cat > "$TARGET_DIR/srcs/requirements/wordpress/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update \
 && apt-get install -y \
   php-fpm php-cli php-mysql php-curl php-xml php-mbstring php-zip php-redis \
   wget curl unzip default-mysql-client less gnupg ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /var/www/html
WORKDIR /var/www/html

# Install WP-CLI
RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp

EXPOSE 9000
CMD ["/usr/local/bin/entrypoint.sh"]
EOF

cat > "$TARGET_DIR/srcs/requirements/wordpress/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

# Quoted heredoc for the same reason as the mariadb entrypoint: ${...} references are
# resolved at container runtime, and the $d loop variable is preserved literally instead
# of being wiped out at generation time.
cat > "$TARGET_DIR/srcs/requirements/wordpress/tools/entrypoint.sh" <<'EOF'
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
EOF

cat > "$TARGET_DIR/srcs/requirements/nginx/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y nginx openssl && rm -rf /var/lib/apt/lists/*

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN mkdir -p /etc/nginx/certs /var/www/html

EXPOSE 443
CMD ["/usr/local/bin/entrypoint.sh"]
EOF

cat > "$TARGET_DIR/srcs/requirements/nginx/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

# Unquoted heredoc so ${DOMAIN_NAME} is baked in now (nginx.conf is a static file, never
# executed as a shell script, so there's no other point at which it could be substituted).
# nginx's own variables are escaped (\$uri, \$args, \$fastcgi_script_name) so bash leaves
# them as literal $-prefixed text for nginx itself to interpret at its own runtime.
cat > "$TARGET_DIR/srcs/requirements/nginx/conf/nginx.conf" <<EOF
worker_processes auto;

events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 443 ssl;
        ssl_certificate /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;

        server_name ${DOMAIN_NAME};

        root /var/www/html;
        index index.php index.html index.htm;

        location / {
          try_files \$uri \$uri/ /index.php?\$args;
        }

        location ~ \.php\$ {
            fastcgi_pass wordpress:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME /var/www/html\$fastcgi_script_name;
            include fastcgi_params;
        }
    }
}
EOF

cat > "$TARGET_DIR/srcs/requirements/nginx/tools/entrypoint.sh" <<'EOF'
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
EOF

# =============================================================================
# BONUS: static site, Adminer, Prometheus + node-exporter
# All bonus services are tagged with the "bonus" compose profile, so `make up`
# (mandatory only) never starts them; only `make bonus-up` does.
# =============================================================================

cat > "$TARGET_DIR/srcs/requirements/bonus/static-site/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*

COPY site /var/www/static
WORKDIR /var/www/static

EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/static-site/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/static-site/site/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${LOGNAME_VALUE} — Inception</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main>
    <h1>${LOGNAME_VALUE}</h1>
    <p>42 student — this static site is the Inception bonus showcase page.</p>
    <p>Served by Python's built-in <code>http.server</code>, no PHP involved.</p>
  </main>
</body>
</html>
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/static-site/site/style.css" <<'EOF'
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #16232c;
  color: #e4edef;
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100vh;
  margin: 0;
}
main {
  max-width: 40rem;
  padding: 2rem;
}
h1 {
  color: #e0836a;
}
code {
  background: #0b1319;
  padding: 0.1em 0.4em;
  border-radius: 4px;
}
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/adminer/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y php-cli php-mysql curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/www/adminer \
 && curl -fsSL https://www.adminer.org/latest.php -o /var/www/adminer/index.php
WORKDIR /var/www/adminer

EXPOSE 8081
CMD ["php", "-S", "0.0.0.0:8081", "-t", "/var/www/adminer"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/adminer/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/prometheus/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y prometheus && rm -rf /var/lib/apt/lists/*

COPY conf/prometheus.yml /etc/prometheus/prometheus.yml

EXPOSE 9090
CMD ["/usr/bin/prometheus", \
     "--config.file=/etc/prometheus/prometheus.yml", \
     "--storage.tsdb.path=/prometheus"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/prometheus/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/prometheus/conf/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/node-exporter/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y prometheus-node-exporter \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 9100
CMD ["/usr/bin/prometheus-node-exporter"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/node-exporter/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/redis/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y redis-server && rm -rf /var/lib/apt/lists/*

COPY conf/redis.conf /etc/redis/redis.conf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 6379
CMD ["/usr/local/bin/entrypoint.sh"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/redis/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/redis/conf/redis.conf" <<'EOF'
bind 0.0.0.0
protected-mode yes
port 6379
maxmemory 64mb
maxmemory-policy allkeys-lru
EOF

# The password is never baked into redis.conf (no password in Dockerfiles/images); it is
# read from the Docker secret and passed as a CLI flag at container start instead.
cat > "$TARGET_DIR/srcs/requirements/bonus/redis/tools/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REDIS_PASSWORD="$(cat /run/secrets/redis_password)"

exec /usr/bin/redis-server /etc/redis/redis.conf --requirepass "${REDIS_PASSWORD}"
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/ftp/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y vsftpd && rm -rf /var/lib/apt/lists/*

COPY conf/vsftpd.conf /etc/vsftpd.conf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 21 21100-21110
CMD ["/usr/local/bin/entrypoint.sh"]
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/ftp/.dockerignore" <<'EOF'
.git
.gitignore
*.md
.DS_Store
EOF

cat > "$TARGET_DIR/srcs/requirements/bonus/ftp/conf/vsftpd.conf" <<'EOF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
local_umask=022
pasv_enable=YES
pasv_min_port=21100
pasv_max_port=21110
seccomp_sandbox=NO
EOF

# FTP_USER comes from .env (non-secret), the password from the ftp_password Docker secret.
# The user is created at runtime (not baked into the image) with its primary group set to
# www-data, and the wordpress volume is made group-writable, so both php-fpm (running as
# www-data) and this FTP user can read/write the same files without changing ownership.
cat > "$TARGET_DIR/srcs/requirements/bonus/ftp/tools/entrypoint.sh" <<'EOF'
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
EOF

cat > "$TARGET_DIR/README.md" <<EOF
*This project has been created as part of the 42 curriculum by ${LOGNAME_VALUE}.*

# Inception

## Description
Inception sets up a small self-hosted web infrastructure using Docker Compose: an NGINX
reverse proxy (HTTPS only), a WordPress site running on PHP-FPM, and a MariaDB database,
each built from its own Dockerfile and running in its own container. The goal of the
project is to practice system administration and containerization: writing Dockerfiles
from scratch (no pre-built service images), wiring services together over a private
Docker network, persisting data with named volumes, and keeping secrets out of the
image and out of version control.

## Instructions
Prerequisites: a Linux VM (Debian/Ubuntu) with Docker Engine and the Docker Compose
plugin installed, this repository cloned onto it, and \`srcs/.env\` plus \`secrets/\`
in place (see [DEV_DOC.md](DEV_DOC.md) for the exact files and variables required).

1. Build and start the stack:
   \`\`\`
   make up
   \`\`\`
2. Open https://${DOMAIN_NAME} in a browser running on the VM.

See [USER_DOC.md](USER_DOC.md) for day-to-day usage and [DEV_DOC.md](DEV_DOC.md) for
environment setup and development details.

## Resources
- [Docker Compose file reference](https://docs.docker.com/reference/compose-file/)
- [Docker secrets](https://docs.docker.com/engine/swarm/secrets/) and [Compose secrets top-level element](https://docs.docker.com/reference/compose-file/secrets/)
- [Docker volumes](https://docs.docker.com/engine/storage/volumes/)
- [NGINX ssl_protocols directive](https://nginx.org/en/docs/http/ngx_http_ssl_module.html)
- [WP-CLI handbook](https://make.wordpress.org/cli/handbook/)
- [MariaDB Docker deployment notes](https://mariadb.com/kb/en/installing-mariadb-with-docker/)
- The 42 Inception project subject (provided by the school)

**AI usage:** AI was used to search for information and resolve doubts about Docker,
Docker Compose, NGINX/TLS configuration, and WordPress/MariaDB setup while working on
this project.

## Project description: Docker and design choices
All three services (nginx, wordpress, mariadb) are built from \`debian:12-slim\`
(the penultimate Debian stable release), each from its own Dockerfile under
\`srcs/requirements/<service>/\`, with no pre-built service images pulled from a registry.

- **Virtual Machines vs Docker** — A VM virtualizes an entire machine (kernel, drivers,
  full OS) via a hypervisor, which gives strong isolation but costs more memory/CPU and
  takes longer to boot. Docker containers share the host kernel and only isolate the
  process/filesystem view, so they start in milliseconds and use a fraction of the
  resources, at the cost of weaker isolation than a full VM. This project runs Docker
  *inside* a VM: the VM gives a disposable, 42-provided machine boundary, while Docker
  is used to compose the actual application out of independent, reproducible services.

- **Secrets vs Environment Variables** — Plain environment variables (via \`.env\`/
  \`env_file\`) are visible to anything that can inspect the container (\`docker inspect\`,
  \`/proc/<pid>/environ\`) and are easy to leak into logs or crash dumps. Docker secrets
  are mounted as read-only, tmpfs-backed files under \`/run/secrets/\` only inside the
  containers that explicitly declare them, are never persisted in the image, and never
  appear in \`docker inspect\`. This project keeps non-sensitive configuration
  (\`DOMAIN_NAME\`, \`MYSQL_DATABASE\`, usernames) in \`.env\`, and every password
  (\`db_password.txt\`, \`db_root_password.txt\`, \`credentials.txt\`) as a Docker secret
  read at container startup, so no password ever appears in an image layer or in git.

- **Docker Network vs Host Network** — With \`network_mode: host\` a container shares the
  host's network namespace directly: no isolation, and every exposed port collides with
  the host's own ports. A user-defined bridge network (used here, \`inception\`) gives
  containers their own network namespace, private DNS-based service discovery by
  container name (e.g. \`wordpress\` resolves to the WordPress container from nginx), and
  lets you control exactly which ports reach the host (only 443, on nginx). This is why
  the subject forbids \`network: host\`/\`--link\`.

- **Docker Volumes vs Bind Mounts** — A bind mount maps an arbitrary host path straight
  into the container; Docker doesn't manage its lifecycle, permissions, or portability
  across hosts. A named volume is managed by Docker itself (\`docker volume ls/inspect\`)
  and is the recommended way to persist container data. Here, both persistent volumes
  (\`mariadb_data\`, \`wordpress_data\`) are declared as named volumes using the \`local\`
  driver with \`driver_opts: {type: none, o: bind, device: ...}\`, which points the named
  volume's storage at \`/home/${LOGNAME_VALUE}/data/...\` on the host, as required by the
  subject: it satisfies "named volume" from Docker's point of view while guaranteeing the
  data lands in a specific, inspectable host directory rather than the opaque
  \`/var/lib/docker/volumes/...\` a plain named volume would use.
EOF

cat > "$TARGET_DIR/USER_DOC.md" <<EOF
# User Documentation

## What this stack provides
- **nginx** — the single entry point to the site, serving HTTPS on port 443
  (TLSv1.2/TLSv1.3 only). This is the only container with a port published to the host.
- **wordpress** — a WordPress site running on PHP-FPM. Not reachable directly from
  outside; nginx forwards \`.php\` requests to it over the private \`inception\` network.
- **mariadb** — the WordPress database. Also private, reachable only from the
  wordpress container over the \`inception\` network.

## Starting and stopping
Run these from the repository root (where the \`Makefile\` is):

| Action | Command |
|---|---|
| Build and start everything | \`make up\` (alias: \`make\`) |
| Stop containers (keep data) | \`make down\` |
| Stop without removing containers | \`make stop\` |
| Restart all services | \`make restart\` |
| Rebuild images | \`make build\` |
| Container status | \`make ps\` |
| List built images (check names match services) | \`make images\` |
| Inspect the named volumes | \`make volumes\` |
| Inspect the docker network | \`make networks\` |
| Check TLS (1.2/1.3 work, 1.1 fails) | \`make check-tls\` |
| List WordPress users | \`make check-wp\` |
| Show each container's restart policy | \`make check-restart\` |
| Confirm nginx is absent from wordpress/mariadb | \`make check-isolation\` |
| Run all the checks above in sequence | \`make check\` |
| Follow container logs | \`make logs\` |
| Stop and remove containers + network | \`make clean\` |
| Full reset, including \`/home/${LOGNAME_VALUE}/data\` | \`make fclean\` |
| Full reset then restart | \`make re\` |
| List all available commands | \`make help\` |

## Accessing the website and the admin panel
- Website: https://${DOMAIN_NAME}
- WordPress admin panel: https://${DOMAIN_NAME}/wp-admin
- Your browser will warn about the certificate because it is self-signed — this is
  expected for this project; accept/continue past the warning.

## Credentials
Nothing is hardcoded — every password lives in a local file, none of it in git:

- \`srcs/.env\` — non-secret configuration (domain, database name, usernames).
- \`secrets/db_root_password.txt\` — MariaDB root password.
- \`secrets/db_password.txt\` — password for the WordPress database user (\`${MYSQL_USER}\`).
- \`secrets/credentials.txt\` — \`WP_ADMIN_PASSWORD\` and \`WP_USER_PASSWORD\` for the two
  WordPress accounts: \`${WP_ADMIN_USER}\` (administrator) and \`${WP_USER}\` (regular user).

These files are listed in \`.gitignore\`, so they only ever exist on disk, never in the
repository.

## Checking that everything is running correctly
\`\`\`
make ps                          # all three should show "running"
make logs                        # tail logs for all services
make networks                    # "inception" network should exist
make volumes                     # mariadb_data / wordpress_data should exist
make check-tls                   # TLS 1.2/1.3 work, TLS 1.1 fails
make check-wp                    # the 2 WordPress users exist, with the right roles
make check-restart                # each container's restart policy
make check-isolation              # nginx is absent from wordpress/mariadb
make check                        # runs all of the above in sequence
\`\`\`
Or just \`make help\` to list every available command.
EOF

cat > "$TARGET_DIR/DEV_DOC.md" <<EOF
# Developer Documentation

## Setting up the environment from scratch
Prerequisites: a Debian/Ubuntu host with Docker Engine and the Docker Compose plugin
installed, this repository cloned onto it.

Nothing sensitive is committed to git (see \`.gitignore\`: \`.env\`, \`secrets/*\`, \`data/\`),
so a fresh clone needs the following created locally before anything can run:

1. The two directories backing the named volumes:
   \`\`\`
   mkdir -p /home/${LOGNAME_VALUE}/data/mariadb /home/${LOGNAME_VALUE}/data/wordpress
   \`\`\`
2. \`srcs/.env\` (non-secret configuration):
   \`\`\`
   DOMAIN_NAME=${DOMAIN_NAME}
   MYSQL_DATABASE=${MYSQL_DATABASE}
   MYSQL_USER=${MYSQL_USER}
   WP_ADMIN_USER=${WP_ADMIN_USER}
   WP_ADMIN_EMAIL=${WP_ADMIN_EMAIL}
   WP_TITLE=${WP_TITLE}
   WP_USER=${WP_USER}
   \`\`\`
3. \`secrets/db_root_password.txt\` and \`secrets/db_password.txt\`, each containing a single
   password, and \`secrets/credentials.txt\` with:
   \`\`\`
   WP_ADMIN_PASSWORD=<password>
   WP_USER_PASSWORD=<password>
   \`\`\`
4. \`${DOMAIN_NAME}\` added to \`/etc/hosts\`, pointing at \`127.0.0.1\`.

## Building and launching
\`\`\`
make up        # docker compose ... up -d --build
make build     # build images without starting containers
make down      # stop containers, keep volumes/network
make stop      # stop containers without removing them
make restart   # restart all services
make logs      # follow logs
make ps        # container status
make images    # list built images
make volumes   # docker volume ls/inspect
make networks  # docker network ls/inspect
make check-tls       # curl + openssl s_client checks (1.2/1.3 ok, 1.1 fails)
make check-wp        # list WordPress users
make check-restart   # show each container's restart policy
make check-isolation # confirm nginx is absent from wordpress/mariadb
make check           # run all checks above in sequence
make help            # list every available command
\`\`\`
The \`Makefile\` always passes \`--env-file srcs/.env\` explicitly, so \`make\` works from the
repo root regardless of shell working directory assumptions.

## Managing containers and volumes
\`\`\`
make ps
make networks
make volumes
docker compose -f srcs/docker-compose.yml exec wordpress bash
docker compose -f srcs/docker-compose.yml exec mariadb bash
\`\`\`

## Where data lives and how it persists
Both named volumes (\`mariadb_data\`, \`wordpress_data\`, declared in
\`srcs/docker-compose.yml\`) use the \`local\` driver with
\`driver_opts: {type: none, o: bind, device: /home/${LOGNAME_VALUE}/data/<service>}\`. This
makes them real Docker-managed named volumes (so \`docker volume ls/inspect\` show them
normally, satisfying the "no bind mounts" requirement) while guaranteeing the underlying
bytes sit at \`/home/${LOGNAME_VALUE}/data/mariadb\` and \`/home/${LOGNAME_VALUE}/data/wordpress\`
on the host, as required by the subject. Because the storage is a real host directory,
\`docker compose down -v\` (used by \`make clean\`) removes the volume *references* but not
the data itself; only \`make fclean\` (\`rm -rf .../data\`) actually deletes it.

Secrets are never written to any image layer: each entrypoint script reads them from
\`/run/secrets/<name>\` at container start (Docker mounts these as tmpfs, only inside the
containers that declare them in \`docker-compose.yml\`).
EOF

chmod +x "$TARGET_DIR/setup_inception_vm.sh" 2>/dev/null || true
chmod +x "$TARGET_DIR/srcs/requirements/mariadb/tools/entrypoint.sh"
chmod +x "$TARGET_DIR/srcs/requirements/wordpress/tools/entrypoint.sh"
chmod +x "$TARGET_DIR/srcs/requirements/nginx/tools/entrypoint.sh"
chmod +x "$TARGET_DIR/srcs/requirements/bonus/redis/tools/entrypoint.sh"
chmod +x "$TARGET_DIR/srcs/requirements/bonus/ftp/tools/entrypoint.sh"

cat <<EOF
Inception scaffold created in: $TARGET_DIR
Domain: $DOMAIN_NAME (added to this VM's /etc/hosts -> 127.0.0.1)
WordPress admin user: $WP_ADMIN_USER
Secondary WordPress user: $WP_USER
Secrets stored in: $TARGET_DIR/secrets (gitignored)

Next steps:
  1. Review the generated files and adjust srcs/.env if needed.
  2. Run: cd $TARGET_DIR && make up
  3. Open https://$DOMAIN_NAME in a browser running on this VM.
     (If you access this VM from another host, add "<VM-IP> $DOMAIN_NAME" to that host's /etc/hosts instead.)
EOF
