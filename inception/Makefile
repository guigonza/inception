# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: guigonza <guigonza@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/08/13 21:09:40 by guigonza          #+#    #+#              #
#    Updated: 2026/08/13 21:09:45 by guigonza         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #


COMPOSE = docker compose -f srcs/docker-compose.yml --env-file srcs/.env
BONUS   = $(COMPOSE) --profile bonus
DOMAIN  = $(shell grep -m1 '^DOMAIN_NAME=' srcs/.env | cut -d= -f2)

all: up

# The named volumes are bind-mounted (via driver_opts) to $(HOME)/data/{mariadb,wordpress}
# on the host. Docker does NOT create that host path on its own for this kind of mount -
# it must already exist, or "up" fails the first time on a machine where it wasn't
# provisioned by setup_inception_vm.sh (e.g. after moving/copying this project elsewhere).
data-dirs:
	mkdir -p $(HOME)/data/mariadb $(HOME)/data/wordpress

up: data-dirs
	$(COMPOSE) up -d --build

open:
	@BROWSER="$$(command -v firefox || command -v firefox-esr)"; \
	if [ -z "$$BROWSER" ]; then \
		echo "firefox no está instalado (sudo apt-get install -y firefox-esr)"; \
		exit 1; \
	fi; \
	echo "Abriendo https://$(DOMAIN) con $$BROWSER..."; \
	nohup "$$BROWSER" "https://$(DOMAIN)" >/dev/null 2>&1 &

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

restart:
	$(COMPOSE) restart

build:
	$(COMPOSE) build

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

images:
	$(COMPOSE) images

volumes:
	docker volume ls
	docker volume inspect srcs_mariadb_data srcs_wordpress_data

networks:
	docker network ls
	docker network inspect srcs_inception

check-tls:
	curl -vk https://$(DOMAIN) 2>&1 | grep -i "SSL connection\|subject\|TLSv"
	@echo "--- TLS 1.2 (must succeed) ---"
	openssl s_client -connect $(DOMAIN):443 -tls1_2 </dev/null 2>&1 | grep -i "Verify\|Protocol"
	@echo "--- TLS 1.1 (must fail) ---"
	@if openssl s_client -connect $(DOMAIN):443 -tls1_1 </dev/null 2>&1 | grep -qi "Cipher is (NONE)\|no protocols\|alert"; then \
		echo "OK: TLS 1.1 rejected"; \
	else \
		echo "FAIL: TLS 1.1 connection was NOT rejected"; \
	fi
	@echo "--- Port 80 (must be refused, nginx only publishes 443) ---"
	-curl -sv http://$(DOMAIN) 2>&1 | grep -i "connection refused\|failed to connect"

check-wp:
	$(COMPOSE) exec wordpress wp user list --path=/var/www/html --allow-root
	@echo "--- WordPress DB tables (stock install: 12 tables) ---"
	$(COMPOSE) exec wordpress wp db tables --path=/var/www/html --allow-root

check-restart:
	docker inspect -f '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' mariadb wordpress nginx

check-isolation:
	@echo "--- mariadb (nginx must be absent) ---"
	@if $(COMPOSE) exec mariadb which nginx >/dev/null 2>&1; then \
		echo "FAIL: nginx found inside mariadb"; \
	else \
		echo "OK: nginx absent from mariadb"; \
	fi
	@echo "--- wordpress (nginx must be absent) ---"
	@if $(COMPOSE) exec wordpress which nginx >/dev/null 2>&1; then \
		echo "FAIL: nginx found inside wordpress"; \
	else \
		echo "OK: nginx absent from wordpress"; \
	fi

check: ps networks volumes check-tls check-wp check-restart check-isolation
	@echo "All checks completed."

# --- Bonus (only assessed once the mandatory part above is perfect) ---
# Bonus services carry the "bonus" compose profile, so plain `make up` never starts
# them; only these targets (via --profile bonus) do.
bonus-up: data-dirs
	$(BONUS) up -d --build

bonus-down:
	$(BONUS) down

bonus-ps:
	$(BONUS) ps

bonus-logs:
	$(BONUS) logs -f static-site adminer prometheus node-exporter redis ftp

check-bonus:
	$(BONUS) ps
	@echo "--- static site ---"
	curl -sI http://$(DOMAIN):8080 | head -1
	@echo "--- adminer ---"
	curl -sI http://$(DOMAIN):8081 | head -1
	@echo "--- prometheus targets (should list node-exporter as up) ---"
	curl -s http://$(DOMAIN):9090/api/v1/targets | grep -o '"health":"[a-z]*"'
	@echo "--- redis (wordpress object cache status) ---"
	-$(COMPOSE) exec wordpress wp redis status --path=/var/www/html --allow-root
	@echo "--- ftp (port 21 reachable) ---"
	-nc -z -w2 $(DOMAIN) 21 && echo "FTP port 21: open" || echo "FTP port 21: closed"

clean:
	$(COMPOSE) down -v

fclean: clean
	rm -rf $(HOME)/data/mariadb $(HOME)/data/wordpress

re: fclean up

help:
	@echo "make up             - build and start all services"
	@echo "make open           - open the site in firefox"
	@echo "make down           - stop and remove containers"
	@echo "make stop           - stop containers without removing them"
	@echo "make restart        - restart all services"
	@echo "make build          - build images"
	@echo "make logs           - follow logs"
	@echo "make ps             - container status"
	@echo "make images         - list built images"
	@echo "make volumes        - inspect the named volumes"
	@echo "make networks       - inspect the docker network"
	@echo "make check-tls      - verify TLS 1.2/1.3 work, TLS 1.1 fails"
	@echo "make check-wp       - list WordPress users"
	@echo "make check-restart  - show each container's restart policy"
	@echo "make check-isolation - confirm nginx is absent from wordpress/mariadb"
	@echo "make check          - run all checks above in sequence"
	@echo "make bonus-up       - build and start mandatory + bonus services"
	@echo "make bonus-down     - stop the bonus services"
	@echo "make bonus-ps       - bonus container status"
	@echo "make bonus-logs     - follow bonus service logs"
	@echo "make check-bonus    - verify static site, Adminer, Prometheus, Redis and FTP respond"
	@echo "make clean          - stop and remove containers, network, volumes"
	@echo "make fclean         - clean, then delete persisted data"
	@echo "make re             - fclean, then up"

.PHONY: up data-dirs open down stop restart build logs ps images volumes networks \
        check-tls check-wp check-restart check-isolation check \
        bonus-up bonus-down bonus-ps bonus-logs check-bonus \
        clean fclean re help
