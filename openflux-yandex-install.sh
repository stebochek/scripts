#!/usr/bin/env bash
# OpenFlux Yandex.Docs exit-node installer (Debian/Ubuntu VPS)
# Pinned to upstream v0.17.1 (f492a1a). Does not expose a direct listener.
set -Eeuo pipefail
umask 077

ROOT_DIR="${OPENFLUX_HOME:-/opt/openflux-yandex}"
REPO='https://github.com/p1neappleXpress/OpenFlux.git'
TAG='v0.17.1'
EXPECTED_COMMIT_PREFIX='f492a1a'
IMAGE='openflux-yandex:v0.17.1'

info() { printf '\n\033[1;34m[+] %s\033[0m\n' "$*"; }
fail() { printf '\n[!] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == 0 ]] || fail 'Запустите от root: sudo bash openflux-yandex-install.sh'
[[ -r /etc/os-release ]] || fail 'Поддерживаются Ubuntu и Debian.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'ubuntu' || "${ID:-}" == 'debian' ]] || fail 'Поддерживаются только Ubuntu и Debian.'
[[ -n "${VERSION_CODENAME:-}" ]] || fail 'Не удалось определить VERSION_CODENAME.'
command -v systemctl >/dev/null || fail 'Требуется VPS с systemd.'
[[ -d "$ROOT_DIR" && -e "$ROOT_DIR/compose.yaml" ]] && fail "Установка уже существует: $ROOT_DIR (не перезаписываю ключи)."

DOC_URL="${1:-}"
if [[ -z "$DOC_URL" ]]; then
  printf 'Вставьте ссылку на публичный редактируемый документ Yandex.Docs (старый редактор):\n'
  read -r -p 'https://disk.yandex.ru/i/... : ' DOC_URL
fi
# Be strict to avoid accidental use of a Yandex.Disk folder or a new-editor link.
[[ "$DOC_URL" =~ ^https://disk\.yandex\.ru/i/[[:alnum:]_-]+([?\#][^[:space:]]*)?$ ]] || \
  fail 'Нужна ссылка формата https://disk.yandex.ru/i/XXXXXXXX. Документ должен быть доступен для редактирования по ссылке.'

info 'Установка системных зависимостей'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git python3 qrencode

if ! command -v docker >/dev/null 2>&1; then
  info 'Установка Docker Engine + Compose plugin из официального репозитория Docker'
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  ARCH="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$ARCH" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
elif ! docker compose version >/dev/null 2>&1; then
  fail 'Docker уже есть, но docker compose отсутствует. Не заменяю установленный Docker автоматически: установите Compose v2 и запустите скрипт ещё раз.'
fi
systemctl enable --now docker
docker compose version >/dev/null || fail 'Docker Compose v2 недоступен.'

info "Клонирование OpenFlux ${TAG}"
install -d -m 0700 "$ROOT_DIR"
git clone --depth 1 --branch "$TAG" "$REPO" "$ROOT_DIR/src"
ACTUAL_COMMIT="$(git -C "$ROOT_DIR/src" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == "${EXPECTED_COMMIT_PREFIX}"* ]] || \
  fail "Неожиданный SHA для $TAG: $ACTUAL_COMMIT (ожидался $EXPECTED_COMMIT_PREFIX...). Установка остановлена."
printf 'Исходный коммит: %s\n' "$ACTUAL_COMMIT"

printf '%s' "$DOC_URL" > "$ROOT_DIR/doc_url.txt"
od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]' > "$ROOT_DIR/secret.txt"
install -d -m 0700 "$ROOT_DIR/data"
chmod 0600 "$ROOT_DIR/doc_url.txt" "$ROOT_DIR/secret.txt"

cat > "$ROOT_DIR/exit-entrypoint.sh" <<'ENTRYPOINT'
#!/bin/sh
set -eu
# The userspace TCP stack needs the kernel's stray RSTs dropped;
# applies ONLY to this Docker container's network namespace.
iptables -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || \
  iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP
DOC_URL="$(cat /etc/openflux-doc-url.txt)"
exec /usr/local/bin/openflux \
  --role=exit \
  --mode=l4 \
  --codec=batched \
  --negotiate \
  --transports=yandex:100 \
  --encryption-key-file=/etc/openflux-secret.txt \
  --url="$DOC_URL"
ENTRYPOINT
chmod 0700 "$ROOT_DIR/exit-entrypoint.sh"

cat > "$ROOT_DIR/compose.yaml" <<'COMPOSE'
services:
  exit:
    image: openflux-yandex:v0.17.1
    build:
      context: ./src
      dockerfile: Dockerfile
    restart: unless-stopped
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
      - NET_RAW
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
      - /run
    working_dir: /data
    volumes:
      - ./data:/data
      - ./secret.txt:/etc/openflux-secret.txt:ro
      - ./doc_url.txt:/etc/openflux-doc-url.txt:ro
      - ./exit-entrypoint.sh:/usr/local/bin/exit-entrypoint.sh:ro
    entrypoint: ["/bin/sh", "/usr/local/bin/exit-entrypoint.sh"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    # No ports are published. Both endpoints meet via Yandex.Docs.
COMPOSE
chmod 0600 "$ROOT_DIR/compose.yaml"

info 'Сборка контейнера OpenFlux из зафиксированного релиза'
docker compose -f "$ROOT_DIR/compose.yaml" -p openflux-yandex build

info 'Создание openflux:// ссылки штатной командой ядра'
PAYLOAD="$(python3 - "$ROOT_DIR/doc_url.txt" "$ROOT_DIR/secret.txt" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    url = f.read().strip()
with open(sys.argv[2], encoding="utf-8") as f:
    secret = f.read().strip()
print(json.dumps({
    "name": "OpenFlux Yandex",
    "negotiate": True,
    "codec": "batched",
    "secret": secret,
    "context": url,
    "transports": [{"type": "yandex", "priority": 100, "url": url}],
}, ensure_ascii=False))
PY
)"
LINK_RESULT="$(printf '%s' "$PAYLOAD" | docker run --rm -i --entrypoint /usr/local/bin/openflux "$IMAGE" --make-link -)"
CLIENT_LINK="$(printf '%s' "$LINK_RESULT" | python3 -c 'import json,sys; obj=json.load(sys.stdin); assert obj.get("link", "").startswith("openflux://v1/"); print(obj["link"])')" || \
  fail 'Не удалось создать корректную ссылку клиента.'
printf '%s\n' "$PAYLOAD" > "$ROOT_DIR/client.json"
printf '%s\n' "$CLIENT_LINK" > "$ROOT_DIR/client.link"
chmod 0600 "$ROOT_DIR/client.json" "$ROOT_DIR/client.link"
qrencode -8 -l M -s 7 -m 3 -o "$ROOT_DIR/client.png" "$CLIENT_LINK"
chmod 0600 "$ROOT_DIR/client.png"

info 'Запуск выходной ноды; Docker будет перезапускать её после ребута'
docker compose -f "$ROOT_DIR/compose.yaml" -p openflux-yandex up -d --no-build
sleep 2
CONTAINER_ID="$(docker compose -f "$ROOT_DIR/compose.yaml" -p openflux-yandex ps -q exit)"
[[ -n "$CONTAINER_ID" ]] || fail 'Контейнер не создался. Проверьте docker compose logs.'
IS_RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_ID")"
if [[ "$IS_RUNNING" != 'true' ]]; then
  docker compose -f "$ROOT_DIR/compose.yaml" -p openflux-yandex logs --tail=80 exit >&2 || true
  fail 'Контейнер не запущен. См. логи выше.'
fi

printf '\n========== ГОТОВО ==========\n'
printf 'Конфигурация: %s/client.json' "$ROOT_DIR"
printf '\nСсылка:        %s/client.link' "$ROOT_DIR"
printf '\nQR-код PNG:   %s/client.png' "$ROOT_DIR"
printf '\n\nСсылка для импорта (СЕКРЕТ, не публикуйте):\n%s\n' "$CLIENT_LINK"
printf '\nQR в терминале:\n'
qrencode -t ANSIUTF8 -m 2 "$CLIENT_LINK" || true
printf '\nПроверка: docker compose -f %q -p openflux-yandex ps\n' "$ROOT_DIR/compose.yaml"
printf 'Логи:     docker compose -f %q -p openflux-yandex logs -f --tail=100 exit\n' "$ROOT_DIR/compose.yaml"
printf 'Стоп:     docker compose -f %q -p openflux-yandex stop\n' "$ROOT_DIR/compose.yaml"
printf '\nВАЖНО: QR содержит ключ шифрования и ссылку на редактируемый документ.\n'
printf 'Запуск контейнера ещё не доказывает работоспособность в условиях белого списка.\n'
