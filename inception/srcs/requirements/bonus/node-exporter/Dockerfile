FROM debian:12-slim

RUN apt-get update && apt-get install -y prometheus-node-exporter \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 9100
CMD ["/usr/bin/prometheus-node-exporter"]
