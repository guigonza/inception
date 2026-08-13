# Developer Documentation

## Setting up the environment from scratch
Prerequisites: a Debian/Ubuntu host with Docker Engine and the Docker Compose plugin
installed, this repository cloned onto it.

Nothing sensitive is committed to git (see `.gitignore`: `.env`, `secrets/*`, `data/`),
so a fresh clone needs the following created locally before anything can run:

1. The two directories backing the named volumes:
   ```
   mkdir -p /home/guigonza/data/mariadb /home/guigonza/data/wordpress
   ```
2. `srcs/.env` (non-secret configuration):
   ```
   DOMAIN_NAME=guigonza.42.fr
   MYSQL_DATABASE=wordpress
   MYSQL_USER=wpuser
   WP_ADMIN_USER=guigonza
   WP_ADMIN_EMAIL=guigonza@guigonza.42.fr
   WP_TITLE=Inception
   WP_USER=guigonza_user
   ```
3. `secrets/db_root_password.txt` and `secrets/db_password.txt`, each containing a single
   password, and `secrets/credentials.txt` with:
   ```
   WP_ADMIN_PASSWORD=<password>
   WP_USER_PASSWORD=<password>
   ```
4. `guigonza.42.fr` added to `/etc/hosts`, pointing at `127.0.0.1`.

## Building and launching
```
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
```
The `Makefile` always passes `--env-file srcs/.env` explicitly, so `make` works from the
repo root regardless of shell working directory assumptions.

## Managing containers and volumes
```
make ps
make networks
make volumes
docker compose -f srcs/docker-compose.yml exec wordpress bash
docker compose -f srcs/docker-compose.yml exec mariadb bash
```

## Where data lives and how it persists
Both named volumes (`mariadb_data`, `wordpress_data`, declared in
`srcs/docker-compose.yml`) use the `local` driver with
`driver_opts: {type: none, o: bind, device: /home/guigonza/data/<service>}`. This
makes them real Docker-managed named volumes (so `docker volume ls/inspect` show them
normally, satisfying the "no bind mounts" requirement) while guaranteeing the underlying
bytes sit at `/home/guigonza/data/mariadb` and `/home/guigonza/data/wordpress`
on the host, as required by the subject. Because the storage is a real host directory,
`docker compose down -v` (used by `make clean`) removes the volume *references* but not
the data itself; only `make fclean` (`rm -rf .../data`) actually deletes it.

Secrets are never written to any image layer: each entrypoint script reads them from
`/run/secrets/<name>` at container start (Docker mounts these as tmpfs, only inside the
containers that declare them in `docker-compose.yml`).
