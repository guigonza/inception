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
