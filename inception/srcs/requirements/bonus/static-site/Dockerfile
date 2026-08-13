FROM debian:12-slim

RUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*

COPY site /var/www/static
WORKDIR /var/www/static

EXPOSE 8080
CMD ["python3", "-m", "http.server", "8080"]
