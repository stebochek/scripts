#!/usr/bin/env bash
# Switch an EXISTING openflux-yandex installation to the modern Yandex Volga transport.
# Based on the openflux-yandex-install.sh layout; does not rebuild the image or change the key.
set -Eeuo pipefail
umask 077

ROOT_DIR="${OPENFLUX_HOME:-/opt/openflux-yandex}"
COMPOSE="$ROOT_DIR/compose.yaml"
ENTRYPOINT="$ROOT_DIR/exit-entrypoint.sh"
DOC_FILE="$ROOT_DIR/doc_url.txt"
SECRET_FILE="$ROOT_DIR/secret.txt"
IMAGE="openflux-yandex:v0.17.1"
PROJECT="openflux-yandex"

info() { printf '\n[+] %s\n' "$*"; }
fail() { printf '\n[!] %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail 'Запустите через sudo.'
for cmd in docker python3 qrencode; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Команда $cmd не найдена."
done
for f in "$COMPOSE" "$ENTRYPOINT" "$DOC_FILE" "$SECRET_FILE"; do
  [[ -f "$f" ]] || fail "Не найден файл: $f. Нужна существующая установка из прежнего скрипта."
done
docker compose version >/dev/null || fail 'Необходим docker compose v2.'
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "Не найден собранный образ $IMAGE."

NEW_URL="${1:-}"
if [[ -z "$NEW_URL" ]]; then
  printf 'Вставьте публичную ссылку на документ из НОВОГО редактора Яндекса (Volga):\n'
  read -r -p 'Ссылка: ' NEW_URL
fi
NEW_URL="$(python3 - "$NEW_URL" <<'PY'
import sys
from urllib.parse import urlsplit
url = sys.argv[1].strip()
p = urlsplit(url)
allowed = {'disk.yandex.ru', 'docs.yandex.ru', 'disk.360.yandex.ru'}
if p.scheme != 'https' or p.hostname not in allowed or not p.path.strip('/'):
    raise SystemExit('Некорректная ссылка. Используйте публичную HTTPS-ссылку на документ Яндекса.')
if any(ord(c) < 32 for c in url) or len(url) > 4000 or p.username or p.password:
    raise SystemExit('Некорректная ссылка.')
print(url)
PY
)" || fail 'Ссылка не прошла проверку.'

# Verify the exact original installer layout; do not modify unrelated deployments.
python3 - "$ENTRYPOINT" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if '--transports=yandex:100' not in s and '--transports=vyandex:100' not in s:
    raise SystemExit('Неизвестная структура entrypoint. Остановка во избежание повреждения установки.')
if '--encryption-key-file=/etc/openflux-secret.txt' not in s or '--negotiate' not in s:
    raise SystemExit('Ожидаемые настройки шифрования не найдены. Ничего не меняем.')
PY

BACKUP="$ROOT_DIR/backup-before-vyandex-$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$BACKUP"
for f in doc_url.txt exit-entrypoint.sh client.json client.link client.png; do
  [[ ! -f "$ROOT_DIR/$f" ]] || cp -p "$ROOT_DIR/$f" "$BACKUP/$f"
done

# If an operation after this point fails, restore previous configs and restart previous node.
rollback() {
  rc=$?
  trap - ERR
  printf '\n[!] Ошибка (код %s). Возвращаю прежние файлы из %s\n' "$rc" "$BACKUP" >&2
  for f in doc_url.txt exit-entrypoint.sh client.json client.link client.png; do
    if [[ -f "$BACKUP/$f" ]]; then cp -p "$BACKUP/$f" "$ROOT_DIR/$f"; fi
  done
  docker compose -f "$COMPOSE" -p "$PROJECT" up -d --no-build --force-recreate >/dev/null 2>&1 || true
  exit "$rc"
}
trap rollback ERR

info 'Переключаю exit-node на vyandex (старый ключ сохраняется)'
printf '%s\n' "$NEW_URL" > "$DOC_FILE"
python3 - "$ENTRYPOINT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('--transports=yandex:100', '--transports=vyandex:100')
p.write_text(s)
PY
chmod 0600 "$DOC_FILE"
chmod 0700 "$ENTRYPOINT"

info 'Создаю новый клиентский профиль со старым секретом'
python3 - "$DOC_FILE" "$SECRET_FILE" "$ROOT_DIR/client.json" <<'PY'
import json,sys
from pathlib import Path
url=Path(sys.argv[1]).read_text().strip()
secret=Path(sys.argv[2]).read_text().strip()
if len(secret) < 32:
    raise SystemExit('Секрет слишком короткий, установка остановлена.')
payload={
    'name': 'OpenFlux Yandex Volga',
    'negotiate': True,
    'codec': 'batched',
    'secret': secret,
    'context': url,
    'transports': [{'type': 'vyandex', 'priority': 100, 'url': url}]
}
Path(sys.argv[3]).write_text(json.dumps(payload, ensure_ascii=False)+'\n')
PY

LINK_JSON="$(docker run --rm -i --entrypoint /usr/local/bin/openflux \
  "$IMAGE" --make-link - < "$ROOT_DIR/client.json")"
CLIENT_LINK="$(printf '%s' "$LINK_JSON" | python3 -c '
import json,sys
obj=json.load(sys.stdin)
link=obj.get("link", "")
if not link.startswith("openflux://v1/"):
    raise SystemExit("Не удалось создать openflux:// ссылку: " + str(obj))
print(link)
')"
printf '%s\n' "$CLIENT_LINK" > "$ROOT_DIR/client.link"
qrencode -8 -l M -s 7 -m 3 -o "$ROOT_DIR/client.png" "$CLIENT_LINK"
chmod 0600 "$ROOT_DIR/client.json" "$ROOT_DIR/client.link" "$ROOT_DIR/client.png"

info 'Пересоздаю контейнер без сборки образа, автозапуск остаётся прежним'
docker compose -f "$COMPOSE" -p "$PROJECT" up -d --no-build --force-recreate
sleep 3
CID="$(docker compose -f "$COMPOSE" -p "$PROJECT" ps -q exit)"
[[ -n "$CID" ]] || { false; }  # triggers rollback
[[ "$(docker inspect -f '{{.State.Running}}' "$CID")" == 'true' ]] || { false; }

trap - ERR
printf '\n========== ГОТОВО: vyandex ==========\n'
printf 'Резервная копия: %s\n' "$BACKUP"
printf 'Клиентский профиль: %s/client.json\n' "$ROOT_DIR"
printf 'Ссылка: %s/client.link\n' "$ROOT_DIR"
printf 'QR: %s/client.png\n' "$ROOT_DIR"
printf '\nСсылка импорта (содержит ключ, не публикуйте):\n%s\n' "$CLIENT_LINK"
printf '\nQR-код в терминале:\n'
qrencode -t ANSIUTF8 -m 2 "$CLIENT_LINK" || true
printf '\nЛоги: docker compose -f %s -p %s logs -f --tail=80 exit\n' "$COMPOSE" "$PROJECT"
printf '\nПримечание: запуск контейнера не гарантирует работу Volga на вашем операторе.\n'
printf 'Если сервис требует авторизации / cookies, понадобится дополнительная настройка.\n'
