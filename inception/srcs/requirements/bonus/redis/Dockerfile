FROM debian:12-slim

RUN apt-get update && apt-get install -y redis-server && rm -rf /var/lib/apt/lists/*

COPY conf/redis.conf /etc/redis/redis.conf
COPY tools/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 6379
CMD ["/usr/local/bin/entrypoint.sh"]
