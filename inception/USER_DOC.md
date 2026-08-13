# User Documentation

## What this stack provides
- **nginx** — the single entry point to the site, serving HTTPS on port 443
  (TLSv1.2/TLSv1.3 only). This is the only container with a port published to the host.
- **wordpress** — a WordPress site running on PHP-FPM. Not reachable directly from
  outside; nginx forwards `.php` requests to it over the private `inception` network.
- **mariadb** — the WordPress database. Also private, reachable only from the
  wordpress container over the `inception` network.

## Starting and stopping
Run these from the repository root (where the `Makefile` is):

| Action | Command |
|---|---|
| Build and start everything | `make up` (alias: `make`) |
| Stop containers (keep data) | `make down` |
| Stop without removing containers | `make stop` |
| Restart all services | `make restart` |
| Rebuild images | `make build` |
| Container status | `make ps` |
| List built images (check names match services) | `make images` |
| Inspect the named volumes | `make volumes` |
| Inspect the docker network | `make networks` |
| Check TLS (1.2/1.3 work, 1.1 fails) | `make check-tls` |
| List WordPress users | `make check-wp` |
| Show each container's restart policy | `make check-restart` |
| Confirm nginx is absent from wordpress/mariadb | `make check-isolation` |
| Run all the checks above in sequence | `make check` |
| Follow container logs | `make logs` |
| Stop and remove containers + network | `make clean` |
| Full reset, including `/home/guigonza/data` | `make fclean` |
| Full reset then restart | `make re` |
| List all available commands | `make help` |

## Accessing the website and the admin panel
- Website: https://guigonza.42.fr
- WordPress admin panel: https://guigonza.42.fr/wp-admin
- Your browser will warn about the certificate because it is self-signed — this is
  expected for this project; accept/continue past the warning.

## Credentials
Nothing is hardcoded — every password lives in a local file, none of it in git:

- `srcs/.env` — non-secret configuration (domain, database name, usernames).
- `secrets/db_root_password.txt` — MariaDB root password.
- `secrets/db_password.txt` — password for the WordPress database user (`wpuser`).
- `secrets/credentials.txt` — `WP_ADMIN_PASSWORD` and `WP_USER_PASSWORD` for the two
  WordPress accounts: `guigonza` (administrator) and `guigonza_user` (regular user).

These files are listed in `.gitignore`, so they only ever exist on disk, never in the
repository.

## Checking that everything is running correctly
```
make ps                          # all three should show "running"
make logs                        # tail logs for all services
make networks                    # "inception" network should exist
make volumes                     # mariadb_data / wordpress_data should exist
make check-tls                   # TLS 1.2/1.3 work, TLS 1.1 fails
make check-wp                    # the 2 WordPress users exist, with the right roles
make check-restart                # each container's restart policy
make check-isolation              # nginx is absent from wordpress/mariadb
make check                        # runs all of the above in sequence
```
Or just `make help` to list every available command.
