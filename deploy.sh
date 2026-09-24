#!/usr/bin/env bash
# Установка и обновление Hermes Agent (Telegram-бот на русском) на VPS.
#
#   git clone https://github.com/vladicgall-ux/Hermes && cd Hermes && ./deploy.sh
#
# Первый запуск: ставит Docker, спрашивает токены и запускает бота.
# Повторный запуск: обновляет Hermes до свежей версии, ключи не спрашивает.
# Сменить ключи: ./deploy.sh --reconfigure
set -euo pipefail

MODEL="nvidia/nemotron-3-ultra-550b-a55b:free"      # основная модель — бесплатная, 1М контекста; смените на своё усмотрение через /model
AUX_MODEL="nvidia/nemotron-3-ultra-550b-a55b:free"  # модель для служебных задач (заголовки, сжатие истории) — тоже бесплатная
# Примечание: не все бесплатные модели OpenRouter годятся — Hermes требует
# минимум 64K токенов контекста, а у части бесплатных моделей (например,
# z-ai/glm-5.2:free) он урезан до 32K и агент откажется стартовать.
TIMEZONE_DEFAULT="Europe/Moscow"

SCRIPT="$(readlink -f "$0")"
cd "$(dirname "$SCRIPT")"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo HERMES_DATA="${HERMES_DATA:-$HOME/.hermes}" bash "$SCRIPT" "$@"
fi

RECONFIGURE=0
[ "${1:-}" = "--reconfigure" ] && RECONFIGURE=1

export HERMES_DATA="${HERMES_DATA:-$HOME/.hermes}"
ENV_FILE="$HERMES_DATA/.env"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }

get_env() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [ -f "$ENV_FILE" ]; then
    grep -vE "^$key=" "$ENV_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

hermes() {
  docker compose run --rm --no-deps hermes "$@"
}

# --- 1. Docker ------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Устанавливаю Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "не найден docker compose. Установите пакет docker-compose-plugin."
systemctl enable --now docker >/dev/null 2>&1 || true

# --- 2. Подкачка на слабых серверах ---------------------------------------
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_mb" -lt 3500 ] && [ "$swap_mb" -lt 1024 ] && [ ! -f /swapfile ]; then
  say "Памяти ${mem_mb} МБ — добавляю файл подкачки 2 ГБ, чтобы бот не падал"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 3. Ключи --------------------------------------------------------------
mkdir -p "$HERMES_DATA"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

ask() {
  # ask KEY "вопрос" secret(0/1) regex "подсказка при ошибке" [значение по умолчанию]
  local key="$1" prompt="$2" secret="$3" re="$4" hint="$5" def="${6:-}" value
  if [ "$RECONFIGURE" -eq 0 ] && [ -n "$(get_env "$key")" ]; then
    return
  fi
  while true; do
    if [ "$secret" = 1 ]; then
      read -rsp "$prompt: " value; echo
    else
      read -rp "$prompt${def:+ [$def]}: " value
    fi
    value="${value:-$def}"
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    if printf '%s' "$value" | grep -Eq "$re"; then
      set_env "$key" "$value"
      return
    fi
    warn "$hint"
  done
}

say "Настройка ключей (вводимые токены на экране не отображаются)"
ask TELEGRAM_BOT_TOKEN "Токен бота от @BotFather" 1 \
  '^[0-9]+:[A-Za-z0-9_-]{30,}$' "Токен выглядит как 123456789:AAH... — скопируйте его из @BotFather целиком."
ask TELEGRAM_ALLOWED_USERS "Ваш Telegram ID (узнать у @userinfobot; несколько — через запятую)" 0 \
  '^[0-9]+(,[0-9]+)*$' "Нужны только цифры, например 123456789."
ask OPENROUTER_API_KEY "Ключ OpenRouter (sk-or-...)" 1 \
  '^sk-or-[A-Za-z0-9_-]{20,}$' "Ключ OpenRouter начинается с sk-or- — возьмите его на openrouter.ai/keys."
ask HERMES_TIMEZONE "Часовой пояс" 0 '^[A-Za-z_]+(/[A-Za-z_+-]+)*$' "Например Europe/Moscow." "$TIMEZONE_DEFAULT"
set_env HERMES_LANGUAGE ru

# --- 4. Образ и настройки --------------------------------------------------
say "Скачиваю свежую версию Hermes"
docker compose pull

if [ ! -f "$HERMES_DATA/.ru-kit-installed" ]; then
  say "Применяю русские настройки и модель $MODEL"
  install -m 644 SOUL.md "$HERMES_DATA/SOUL.md"
  hermes config set model.provider openrouter
  hermes config set model.default "$MODEL"
  hermes config set auxiliary.openrouter_model "$AUX_MODEL"
  hermes config set auxiliary.free_only true
  hermes config set display.language ru
  hermes config set stt.language ru
  hermes config set stt.local.model small          # base плохо понимает русский
  hermes config set tts.provider edge              # бесплатный синтез речи
  hermes config set tts.edge.voice ru-RU-DmitryNeural
  touch "$HERMES_DATA/.ru-kit-installed"
fi

# --- 5. Запуск -------------------------------------------------------------
say "Запускаю бота"
docker compose up -d --force-recreate

sleep 15
if docker compose logs --tail 200 hermes 2>&1 | grep -qi "token .* rejected"; then
  warn "Telegram отклонил токен бота. Запустите ./deploy.sh --reconfigure и введите токен заново."
  exit 1
fi

cat <<EOF

Готово! Бот запущен и будет сам перезапускаться после сбоев и перезагрузки сервера.

  Откройте своего бота в Telegram и напишите ему «Привет».

Полезное:
  docker compose logs -f hermes        — смотреть журнал (выход: Ctrl+C)
  docker compose restart hermes        — перезапустить бота
  ./deploy.sh                          — обновить Hermes до новой версии
  ./deploy.sh --reconfigure            — сменить токены и ключи
  Данные бота: $HERMES_DATA
EOF
