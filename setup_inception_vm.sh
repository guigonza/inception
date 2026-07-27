#!/usr/bin/env bash
set -euo pipefail

# Script to provision a Linux VM with Docker and scaffold the Inception project.
# Usage: sudo bash setup_inception_vm.sh [target_dir]
# Example: sudo bash setup_inception_vm.sh /home/youruser/inception

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

TARGET_DIR="${1:-$HOME/inception}"
TARGET_DIR="$(realpath -m "$TARGET_DIR")"
LOGNAME_VALUE="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
HOST_USER="${SUDO_USER:-${USER:-root}}"
HOST_HOME="$(getent passwd "$HOST_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$HOST_USER")"

if [[ "$HOST_USER" == "root" ]]; then
  HOST_HOME="/root"
fi

if [[ -z "${LOGNAME_VALUE}" ]]; then
  LOGNAME_VALUE="root"
fi

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
         "$TARGET_DIR/secrets"

mkdir -p "$HOST_HOME/data/mariadb" "$HOST_HOME/data/wordpress"
chown -R "$HOST_USER:$HOST_USER" "$HOST_HOME/data" 2>/dev/null || true

DOMAIN_NAME="${LOGNAME_VALUE}.42.fr"
MYSQL_DATABASE="wordpress"
MYSQL_USER="wpuser"
MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
MYSQL_PASSWORD="$(openssl rand -hex 16)"

# WordPress admin username MUST NOT contain "admin" or "administrator" (case-insensitive).
if echo "$LOGNAME_VALUE" | grep -qi 'admin'; then
  WP_ADMIN_USER="${LOGNAME_VALUE}_owner"
else
  WP_ADMIN_USER="${LOGNAME_VALUE}"
fi
WP_ADMIN_PASSWORD="$(openssl rand -hex 16)"
WP_ADMIN_EMAIL="${WP_ADMIN_USER}@${DOMAIN_NAME}"
WP_TITLE="Inception"
WP_USER="${LOGNAME_VALUE}_user"
WP_USER_PASSWORD="$(openssl rand -hex 16)"

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

chmod 600 "$TARGET_DIR/secrets/"*.txt

cat > "$TARGET_DIR/.gitignore" <<'EOF'
.env
secrets/*
data/
*.log
EOF

cat > "$TARGET_DIR/Makefile" <<'EOF'
.PHONY: up down build logs clean fclean re

all: up

up:
	docker compose -f srcs/docker-compose.yml --env-file srcs/.env up -d --build

down:
	docker compose -f srcs/docker-compose.yml --env-file srcs/.env down
build:
	docker compose -f srcs/docker-compose.yml --env-file srcs/.env build
logs:
	docker compose -f srcs/docker-compose.yml --env-file srcs/.env logs -f
clean:
	docker compose -f srcs/docker-compose.yml --env-file srcs/.env down -v
fclean: clean
	rm -rf $(PWD)/data
re: fclean up
EOF

# docker-compose.yml is generated (not executed as a shell script), so $HOST_HOME
# is intentionally substituted now, at provisioning time.
cat > "$TARGET_DIR/srcs/docker-compose.yml" <<EOF
services:
  mariadb:
    image: mariadb
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
    image: wordpress
    container_name: wordpress
    build:
      context: ./requirements/wordpress
      dockerfile: Dockerfile
    env_file:
      - .env
    secrets:
      - db_password
      - credentials
    depends_on:
      - mariadb
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - inception
    restart: unless-stopped

  nginx:
    image: nginx
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
EOF

cat > "$TARGET_DIR/srcs/requirements/mariadb/Dockerfile" <<'EOF'
FROM debian:12-slim

RUN apt-get update && apt-get install -y mariadb-server && rm -rf /var/lib/apt/lists/*

COPY conf/my.cnf /etc/mysql/my.cnf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3306
CMD ["/usr/local/bin/entrypoint.sh"]
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
   php-fpm php-cli php-mysql php-curl php-xml php-mbstring php-zip \
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
Prerequisites: a Linux VM (Debian/Ubuntu), sudo access.

1. Clone this repository onto the VM.
2. Bootstrap the environment (installs Docker, generates \`srcs/.env\` and \`secrets/\`,
   adds \`${DOMAIN_NAME}\` to \`/etc/hosts\`):
   \`\`\`
   sudo bash setup_inception_vm.sh "\$(pwd)"
   \`\`\`
3. Build and start the stack:
   \`\`\`
   make up
   \`\`\`
4. Open https://${DOMAIN_NAME} in a browser running on the VM.

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

**AI usage:** Claude (Anthropic) was used as a reviewer/pair-programmer for the
\`setup_inception_vm.sh\` provisioning script: it reviewed the script against the project
subject, identified functional bugs (unquoted heredocs causing NGINX/PHP-FPM variables
and the Makefile's \`\$(PWD)\` to be expanded too early, and a MariaDB remote-auth issue
that broke the WordPress startup wait-loop), rewired credential handling to use real
Docker secrets instead of hardcoded values, and drafted this README and the
USER_DOC.md/DEV_DOC.md files. All generated code and docs were reviewed and adjusted by
the author before use; no AI tool had access to real secrets or the VM.

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
| Rebuild images | \`make build\` |
| Stop and remove containers + network | \`make clean\` |
| Full reset, including \`/home/${LOGNAME_VALUE}/data\` | \`make fclean\` |
| Full reset then restart | \`make re\` |
| Follow container logs | \`make logs\` |

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

These files are created once by \`setup_inception_vm.sh\` and are listed in \`.gitignore\`,
so they only ever exist on disk, never in the repository.

## Checking that everything is running correctly
\`\`\`
docker compose -f srcs/docker-compose.yml ps      # all three should show "running"
docker compose -f srcs/docker-compose.yml logs -f # tail logs for all services
docker network ls                                  # "inception" network should exist
docker volume ls                                    # mariadb_data / wordpress_data should exist
curl -vk https://${DOMAIN_NAME}                     # -k: ignore the self-signed cert
\`\`\`
EOF

cat > "$TARGET_DIR/DEV_DOC.md" <<EOF
# Developer Documentation

## Setting up the environment from scratch
Prerequisites: a Debian/Ubuntu VM with sudo access, this repository cloned onto it.

Nothing sensitive is committed to git (see \`.gitignore\`: \`.env\`, \`secrets/*\`, \`data/\`),
so a fresh clone needs \`srcs/.env\` and \`secrets/*.txt\` generated before anything can run.
\`setup_inception_vm.sh\` does this in one step:

\`\`\`
sudo bash setup_inception_vm.sh "\$(pwd)"
\`\`\`

This installs Docker (if missing), writes \`srcs/.env\` (domain, DB name, usernames — no
passwords), generates random passwords into \`secrets/db_password.txt\`,
\`secrets/db_root_password.txt\` and \`secrets/credentials.txt\`, creates the
\`/home/${LOGNAME_VALUE}/data/{mariadb,wordpress}\` directories that back the named
volumes, and adds \`${DOMAIN_NAME}\` to \`/etc/hosts\` pointing at \`127.0.0.1\`.

Re-running the script overwrites the \`srcs/\` tree (Dockerfiles, configs, compose file)
from its built-in templates — treat it as the source of truth for the infrastructure
code, and edit the templates inside the script (or the generated files, then port the
change back) rather than hand-editing \`srcs/\` and re-running the script afterward.

## Building and launching
\`\`\`
make up      # docker compose ... up -d --build
make build   # build images without starting containers
make down    # stop containers, keep volumes/network
make logs    # follow logs
\`\`\`
The \`Makefile\` always passes \`--env-file srcs/.env\` explicitly, so \`make\` works from the
repo root regardless of shell working directory assumptions.

## Managing containers and volumes
\`\`\`
docker compose -f srcs/docker-compose.yml ps
docker compose -f srcs/docker-compose.yml exec wordpress bash
docker compose -f srcs/docker-compose.yml exec mariadb bash
docker network inspect inception
docker volume inspect srcs_mariadb_data srcs_wordpress_data   # names may be prefixed by the compose project
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
