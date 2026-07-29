#!/usr/bin/env bash
# ============================================================================
#  Cloudflare WARP Setup Script — Ubuntu 24.04
#  Идемпотентный: безопасен для повторного запуска.
# ============================================================================
set -euo pipefail

# ─── Цвета ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

# ─── Проверка root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт нужно запускать от root (sudo ./warp-setup.sh)"
    exit 1
fi

# ─── Проверка ОС ────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_warn "Обнаружена ОС: ${PRETTY_NAME:-unknown}. Скрипт рассчитан на Ubuntu."
        read -rp "Продолжить всё равно? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi
fi

# ============================================================================
#  ИНТЕРАКТИВНЫЙ ВВОД
# ============================================================================
log_step "НАСТРОЙКА ПАРАМЕТРОВ"

# --- Локальный SOCKS5 порт WARP-прокси ---
while true; do
    read -rp "$(echo -e "${CYAN}Локальный порт WARP proxy${NC} (Enter = 40000): ")" WARP_PORT
    WARP_PORT="${WARP_PORT:-40000}"
    if [[ "$WARP_PORT" =~ ^[0-9]+$ ]] && (( WARP_PORT >= 1024 && WARP_PORT <= 65535 )); then
        break
    fi
    log_error "Порт должен быть числом от 1024 до 65535"
done
log_ok "WARP proxy порт: 127.0.0.1:${WARP_PORT}"

# --- Автоперезапуск systemd ---
read -rp "$(echo -e "${CYAN}Включить автоперезапуск warp-svc через systemd?${NC} (Y/n): ")" AUTO_RESTART
AUTO_RESTART="${AUTO_RESTART:-y}"

# --- Подтверждение ---
echo ""
echo -e "${BOLD}┌──────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│              ПЛАН ДЕЙСТВИЙ                │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────┤${NC}"
echo -e "│ 1. Установка cloudflare-warp               │"
echo -e "│ 2. Регистрация клиента                     │"
echo -e "│ 3. Режим proxy, порт ${WARP_PORT}$(printf '%*s' $((20 - ${#WARP_PORT})) '')│"
echo -e "│ 4. Подключение и проверка статуса           │"
if [[ "$AUTO_RESTART" =~ ^[Yy]$ ]]; then
echo -e "│ 5. systemd Restart=always для warp-svc      │"
fi
echo -e "│ 6. Проверка доступа в интернет через WARP   │"
echo -e "${BOLD}└──────────────────────────────────────────┘${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Запускаем? (y/N):${NC} ")" GO
[[ "$GO" =~ ^[Yy]$ ]] || { log_warn "Отменено."; exit 0; }

# ============================================================================
#  1. УСТАНОВКА WARP
# ============================================================================
log_step "1/6 — УСТАНОВКА CLOUDFLARE WARP"

export DEBIAN_FRONTEND=noninteractive

if command -v warp-cli &>/dev/null; then
    log_ok "cloudflare-warp уже установлен ($(warp-cli --version 2>/dev/null | head -1))"
else
    apt-get update -q
    apt-get install -y -q curl gnupg lsb-release

    KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
    if [[ ! -f "$KEYRING" ]]; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o "$KEYRING"
        log_ok "GPG-ключ Cloudflare добавлен"
    fi

    REPO_FILE="/etc/apt/sources.list.d/cloudflare-client.list"
    echo "deb [signed-by=${KEYRING}] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > "$REPO_FILE"

    apt-get update -q
    apt-get install -y -q cloudflare-warp
    log_ok "cloudflare-warp установлен"
fi

# ============================================================================
#  2. РЕГИСТРАЦИЯ
# ============================================================================
log_step "2/6 — РЕГИСТРАЦИЯ КЛИЕНТА"

# Даём демону время подняться после установки/старта
for i in {1..10}; do
    systemctl is-active --quiet warp-svc && break
    sleep 1
done

if warp-cli --accept-tos status 2>/dev/null | grep -qiE "Registration Missing|not registered"; then
    warp-cli --accept-tos registration new
    log_ok "Клиент зарегистрирован"
else
    log_ok "Клиент уже зарегистрирован"
fi

# ============================================================================
#  3. РЕЖИМ PROXY
# ============================================================================
log_step "3/6 — РЕЖИМ PROXY"

warp-cli --accept-tos mode proxy >/dev/null 2>&1 || log_warn "Не удалось выставить режим proxy — проверьте вручную: warp-cli mode proxy"
log_ok "Режим: proxy"

# Кастомный порт (если поддерживается текущей версией CLI)
if [[ "$WARP_PORT" != "40000" ]]; then
    if warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1; then
        log_ok "Порт proxy изменён на ${WARP_PORT}"
    else
        log_warn "Команда 'warp-cli proxy port' не поддерживается этой версией — используется порт по умолчанию 40000"
        WARP_PORT="40000"
    fi
fi

# ============================================================================
#  4. ПОДКЛЮЧЕНИЕ
# ============================================================================
log_step "4/6 — ПОДКЛЮЧЕНИЕ"

warp-cli --accept-tos connect >/dev/null 2>&1 || true

CONNECTED=0
for i in {1..15}; do
    if warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
        CONNECTED=1
        break
    fi
    sleep 1
done

if [[ "$CONNECTED" -eq 1 ]]; then
    log_ok "Статус: Connected"
else
    log_error "WARP не подключился за 15 секунд. Проверьте: warp-cli status"
fi

if ss -lntp 2>/dev/null | grep -q "127.0.0.1:${WARP_PORT}"; then
    log_ok "Прокси слушает на 127.0.0.1:${WARP_PORT}"
else
    log_warn "Порт 127.0.0.1:${WARP_PORT} не найден в ss — проверьте вручную: ss -lntp | grep ${WARP_PORT}"
fi

# ============================================================================
#  5. SYSTEMD АВТОПЕРЕЗАПУСК
# ============================================================================
if [[ "$AUTO_RESTART" =~ ^[Yy]$ ]]; then
    log_step "5/6 — SYSTEMD АВТОПЕРЕЗАПУСК"

    WARP_SVC="$(systemctl list-units --type=service --all 2>/dev/null | grep -oE 'warp-svc\.service' | head -1)"

    if [[ -n "$WARP_SVC" ]]; then
        OVERRIDE_DIR="/etc/systemd/system/warp-svc.service.d"
        mkdir -p "$OVERRIDE_DIR"
        cat > "${OVERRIDE_DIR}/override.conf" <<'EOF'
[Service]
Restart=always
RestartSec=10
EOF
        systemctl daemon-reload
        systemctl restart warp-svc
        log_ok "Restart=always настроен для warp-svc"

        # После рестарта демона нужно снова дождаться подключения
        sleep 3
        for i in {1..15}; do
            warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected" && break
            sleep 1
        done
    else
        log_warn "Сервис warp-svc не найден — автоперезапуск не настроен"
    fi
else
    log_step "5/6 — SYSTEMD АВТОПЕРЕЗАПУСК (пропущено)"
fi

# ============================================================================
#  6. ПРОВЕРКА ИНТЕРНЕТА ЧЕРЕЗ WARP
# ============================================================================
log_step "6/6 — ПРОВЕРКА ДОСТУПА В ИНТЕРНЕТ"

TRACE="$(curl -s --socks5-hostname "127.0.0.1:${WARP_PORT}" --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"

if echo "$TRACE" | grep -q "warp=on"; then
    log_ok "Трафик через прокси идёт через WARP (warp=on)"
elif [[ -n "$TRACE" ]]; then
    log_warn "Прокси отвечает, но WARP не подтверждён в trace:"
    echo "$TRACE" | sed 's/^/    /'
else
    log_error "Не удалось получить ответ через прокси 127.0.0.1:${WARP_PORT} — проверьте статус: warp-cli status"
fi

# ============================================================================
#  ИТОГО
# ============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        WARP НАСТРОЕН ✓                   ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Режим:        ${BOLD}proxy${NC}"
echo -e "${GREEN}║${NC} SOCKS5:       ${BOLD}127.0.0.1:${WARP_PORT}${NC}"
echo -e "${GREEN}║${NC} Автостарт:    ${BOLD}$([[ "$AUTO_RESTART" =~ ^[Yy]$ ]] && echo "включён" || echo "не настроен")${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}В 3x-ui / Xray добавьте outbound типа socks с адресом:${NC}"
echo -e "   ${BOLD}127.0.0.1:${WARP_PORT}${NC}"
echo ""
echo -e "   Статус WARP:  ${CYAN}warp-cli status${NC}"
echo -e "   Порты:        ${CYAN}ss -lntp | grep ${WARP_PORT}${NC}"
echo -e "   Логи демона:  ${CYAN}journalctl -u warp-svc -f${NC}"
echo ""
