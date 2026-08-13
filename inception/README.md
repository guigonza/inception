*This project has been created as part of the 42 curriculum by guigonza.*

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
plugin installed, this repository cloned onto it, and `srcs/.env` plus `secrets/`
in place (see [DEV_DOC.md](DEV_DOC.md) for the exact files and variables required).

1. Build and start the stack:
   ```
   make up
   ```
2. Open https://guigonza.42.fr in a browser running on the VM.

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
All three services (nginx, wordpress, mariadb) are built from `debian:12-slim`
(the penultimate Debian stable release), each from its own Dockerfile under
`srcs/requirements/<service>/`, with no pre-built service images pulled from a registry.

- **Virtual Machines vs Docker** — A VM virtualizes an entire machine (kernel, drivers,
  full OS) via a hypervisor, which gives strong isolation but costs more memory/CPU and
  takes longer to boot. Docker containers share the host kernel and only isolate the
  process/filesystem view, so they start in milliseconds and use a fraction of the
  resources, at the cost of weaker isolation than a full VM. This project runs Docker
  *inside* a VM: the VM gives a disposable, 42-provided machine boundary, while Docker
  is used to compose the actual application out of independent, reproducible services.

- **Secrets vs Environment Variables** — Plain environment variables (via `.env`/
  `env_file`) are visible to anything that can inspect the container (`docker inspect`,
  `/proc/<pid>/environ`) and are easy to leak into logs or crash dumps. Docker secrets
  are mounted as read-only, tmpfs-backed files under `/run/secrets/` only inside the
  containers that explicitly declare them, are never persisted in the image, and never
  appear in `docker inspect`. This project keeps non-sensitive configuration
  (`DOMAIN_NAME`, `MYSQL_DATABASE`, usernames) in `.env`, and every password
  (`db_password.txt`, `db_root_password.txt`, `credentials.txt`) as a Docker secret
  read at container startup, so no password ever appears in an image layer or in git.

- **Docker Network vs Host Network** — With `network_mode: host` a container shares the
  host's network namespace directly: no isolation, and every exposed port collides with
  the host's own ports. A user-defined bridge network (used here, `inception`) gives
  containers their own network namespace, private DNS-based service discovery by
  container name (e.g. `wordpress` resolves to the WordPress container from nginx), and
  lets you control exactly which ports reach the host (only 443, on nginx). This is why
  the subject forbids `network: host`/`--link`.

- **Docker Volumes vs Bind Mounts** — A bind mount maps an arbitrary host path straight
  into the container; Docker doesn't manage its lifecycle, permissions, or portability
  across hosts. A named volume is managed by Docker itself (`docker volume ls/inspect`)
  and is the recommended way to persist container data. Here, both persistent volumes
  (`mariadb_data`, `wordpress_data`) are declared as named volumes using the `local`
  driver with `driver_opts: {type: none, o: bind, device: ...}`, which points the named
  volume's storage at `/home/guigonza/data/...` on the host, as required by the
  subject: it satisfies "named volume" from Docker's point of view while guaranteeing the
  data lands in a specific, inspectable host directory rather than the opaque
  `/var/lib/docker/volumes/...` a plain named volume would use.
