# Runbook — Inception

Notas operativas para levantar, verificar y depurar el stack que genera `setup_inception_vm.sh`. Todo se ejecuta en la VM, dentro del repo generado (por defecto `~/inception`), como el usuario normal (no `sudo`) una vez el grupo `docker` está activo.

## Servicios

| Servicio | Rol | Puerto publicado |
|---|---|---|
| `nginx` | único punto de entrada, TLSv1.2/1.3 | 443 |
| `wordpress` | WordPress + php-fpm | interno (9000) |
| `mariadb` | base de datos de WordPress | interno (3306) |
| `static-site` *(bonus)* | sitio estático sin PHP | 8080 |
| `adminer` *(bonus)* | cliente web para MariaDB | 8081 |
| `prometheus` + `node-exporter` *(bonus)* | métricas del host | 9090 |
| `redis` *(bonus)* | object cache de WordPress | interno (6379) |
| `ftp` *(bonus)* | acceso FTP al volumen de WordPress | 21, 21100–21110 |

Los tres primeros son el stack mínimo (`make up`); todo lo demás vive bajo el perfil `bonus` de Compose (`make bonus-up`) y no arranca con `make up` a secas.

## Ciclo de vida

```
make up          # build + arrancar el stack mínimo
make bonus-up     # stack mínimo + los servicios bonus
make down         # parar y quitar contenedores
make stop         # parar sin quitar contenedores
make restart      # reiniciar todo
make logs         # seguir logs de todos los servicios
make fclean       # down -v + borra los datos persistidos en ~/data
make re           # fclean + up (reset completo)
```

Para un reset realmente limpio (sin nada de Docker cacheado, no solo `down`/`up`):

```
docker stop $(docker ps -qa); docker rm $(docker ps -qa)
docker rmi -f $(docker images -qa)
docker volume rm $(docker volume ls -q)
docker network rm $(docker network ls -q) 2>/dev/null
make up
```

## Verificar la infraestructura

```
make ps                          # los 3 contenedores deben estar "Up"
docker compose -f srcs/docker-compose.yml images   # ningún tag debe ser "latest"
make networks                    # red bridge "inception" presente
make volumes                     # ambos volúmenes con device en /home/<login>/data
make check-restart                # restart policy "unless-stopped" en los 3
make check-isolation              # nginx debe estar ausente de mariadb y wordpress
```

### TLS

```
make check-tls
```

Comprueba: TLS 1.3 conecta, TLS 1.2 conecta, TLS 1.1 se rechaza, y el puerto 80 no responde (nginx solo publica 443).

### WordPress

```
make check-wp
```

Lista los dos usuarios (uno `administrator`, uno `author`) y las tablas de la base de datos.

Prueba funcional (no solo listar usuarios) — hazla desde el navegador, es el método normal y el más representativo:

```
make open   # abre https://<dominio> en firefox
```

1. En el sitio público, comenta con la cuenta `guigonza_user`.
2. Entra en `https://<dominio>/wp-admin` con `guigonza` (admin), edita una página y guarda.
3. Recarga el sitio y confirma el cambio a simple vista.

Alternativa por terminal (útil si no hay entorno gráfico disponible):

```
docker compose -f srcs/docker-compose.yml exec wordpress \
  wp comment create --comment_post_ID=1 --comment_author=guigonza_user \
  --comment_content="prueba" --comment_approve=1 \
  --path=/var/www/html --allow-root

docker compose -f srcs/docker-compose.yml exec wordpress \
  wp post list --post_type=page --path=/var/www/html --allow-root
docker compose -f srcs/docker-compose.yml exec wordpress \
  wp post update <ID> --post_title="Editado" --path=/var/www/html --allow-root
```

### MariaDB

```
# root sin contraseña debe fallar
docker compose -f srcs/docker-compose.yml exec mariadb mysql -u root -e "SELECT 1"

# root con la contraseña del secret debe funcionar
docker compose -f srcs/docker-compose.yml exec mariadb \
  sh -c 'mysql -u root -p"$(cat /run/secrets/db_root_password)" -e "SELECT 1"'

# usuario de la app, base de datos con contenido
docker compose -f srcs/docker-compose.yml exec mariadb \
  sh -c 'mysql -u wpuser -p"$(cat /run/secrets/db_password)" wordpress -e "SHOW TABLES"'
```

### Persistencia

Los datos viven en volúmenes nombrados respaldados por `/home/<login>/data/{mariadb,wordpress}` en el host, no dentro de los contenedores. Para confirmar que sobreviven a un reinicio completo, haz primero el comentario/edición de la sección de WordPress de arriba y luego:

```
sudo reboot
# tras el reinicio:
cd ~/inception && make up && make open
# el comentario y la edición hechos antes del reboot deben seguir ahí
```

El reinicio en sí solo se puede hacer por terminal; el resto (crear el contenido y verificar que persiste) es más fiable hacerlo mirando la página real que reconstruyendo el estado a ciegas por wp-cli.

## Bonus

```
make bonus-up
make check-bonus
make bonus-logs
```

`check-bonus` cubre static-site, adminer, prometheus y redis. FTP se prueba mejor a mano:

```
ftp <dominio>
# usuario: valor de FTP_USER en srcs/.env
# contraseña: cat secrets/ftp_password.txt
ftp> put test.txt
# y confirmar que aparece en ~/data/wordpress/test.txt desde el host
```

Redis se activa solo si el contenedor `redis` está corriendo en el momento en que WordPress hace el bootstrap inicial (primera vez que se crea `wp-config.php`). Si arrancaste primero sin bonus y luego añades `redis`, hace falta un `make fclean && make bonus-up` para que el plugin se active.

## Dónde están las credenciales

| Archivo | Contenido |
|---|---|
| `srcs/.env` | dominio, nombre de la base de datos, usernames — no sensible |
| `secrets/db_password.txt` | password del usuario de la base de datos de WordPress |
| `secrets/db_root_password.txt` | password root de MariaDB |
| `secrets/credentials.txt` | `WP_ADMIN_PASSWORD` y `WP_USER_PASSWORD` |
| `secrets/ftp_password.txt` | password del usuario FTP |
| `secrets/redis_password.txt` | `requirepass` de Redis |

Ninguno de estos archivos se versiona (`.gitignore` excluye `.env`, `secrets/*` y `data/`). Se leen dentro de cada contenedor desde `/run/secrets/<nombre>`, nunca como variable de entorno plana — así no aparecen en `docker inspect`.

## Decisiones de diseño

- **Volúmenes con `driver_opts` en vez de bind mounts directos**: Docker los gestiona como volúmenes nombrados (`docker volume ls/inspect`), pero los datos físicos caen en una ruta concreta del host (`/home/<login>/data/...`) en vez del `/var/lib/docker/volumes/...` opaco por defecto.
- **Red bridge dedicada (`inception`)** en vez de `network_mode: host`: cada contenedor tiene su propio namespace de red, resolución DNS por nombre de servicio, y solo nginx expone un puerto al host.
- **Secrets de Docker para contraseñas, `.env` para configuración no sensible**: los secrets se montan como archivos de solo lectura solo dentro de los contenedores que los declaran; una variable de entorno normal es visible con `docker inspect` o `/proc/<pid>/environ`.
- **Tags de imagen explícitos** (`:inception`, nunca `latest`): sin tag, Docker etiqueta la imagen construida como `latest` por defecto, así que cada servicio lo fija explícitamente en `docker-compose.yml`.
