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
