FROM debian:12-slim

RUN apt-get update && apt-get install -y prometheus && rm -rf /var/lib/apt/lists/*

COPY conf/prometheus.yml /etc/prometheus/prometheus.yml

EXPOSE 9090
CMD ["/usr/bin/prometheus", \
     "--config.file=/etc/prometheus/prometheus.yml", \
     "--storage.tsdb.path=/prometheus"]
