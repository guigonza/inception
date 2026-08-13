#!/usr/bin/env bash
set -euo pipefail

REDIS_PASSWORD="$(cat /run/secrets/redis_password)"

exec /usr/bin/redis-server /etc/redis/redis.conf --requirepass "${REDIS_PASSWORD}"
