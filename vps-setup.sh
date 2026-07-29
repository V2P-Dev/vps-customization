#!/usr/bin/env bash
# ============================================================================
#  VPS Initial Setup Script — Ubuntu 24.04
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
    log_error "Скрипт нужно запускать от root (sudo ./vps-setup.sh)"
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

# --- SSH порт ---
while true; do
    read -rp "$(echo -e "${CYAN}Введите SSH-порт${NC} (1024–65535, Enter = 22): ")" SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 22 && SSH_PORT <= 65535 )); then
        break
    fi
    log_error "Порт должен быть числом от 22 до 65535"
done
log_ok "SSH порт: ${SSH_PORT}"

# --- Hostname ---
read -rp "$(echo -e "${CYAN}Введите hostname${NC} (Enter = оставить текущий \"$(hostname)\"): ")" NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-$(hostname)}"
log_ok "Hostname: ${NEW_HOSTNAME}"

# --- Веб-порты ---
read -rp "$(echo -e "${CYAN}Открыть порты 80/tcp и 443/tcp?${NC} (Y/n): ")" OPEN_WEB
OPEN_WEB="${OPEN_WEB:-y}"
if [[ "$OPEN_WEB" =~ ^[Yy]$ ]]; then
    log_ok "Порты 80 и 443 будут открыты"
else
    log_ok "Порты 80 и 443 НЕ будут открываться"
fi

# --- Подтверждение ---
echo ""
echo -e "${BOLD}┌──────────────────────────────────┐${NC}"
echo -e "${BOLD}│        ПЛАН ДЕЙСТВИЙ             │${NC}"
echo -e "${BOLD}├──────────────────────────────────┤${NC}"
echo -e "│ 1. Обновление системы            │"
echo -e "│ 2. Установка micro               │"
echo -e "│ 3. Отключение IPv6               │"
echo -e "│ 4. TCP-оптимизации (BBR)         │"
echo -e "│ 5. SSH порт → ${SSH_PORT}$(printf '%*s' $((19 - ${#SSH_PORT})) '')│"
echo -e "│ 6. UFW + блок ICMP               │"
if [[ "$OPEN_WEB" =~ ^[Yy]$ ]]; then
echo -e "│ 7. Открыть 80/tcp, 443/tcp       │"
fi
echo -e "│ 8. Hostname → ${NEW_HOSTNAME}$(printf '%*s' $((19 - ${#NEW_HOSTNAME})) '')│"
echo -e "${BOLD}└──────────────────────────────────┘${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Запускаем? (y/N):${NC} ")" GO
[[ "$GO" =~ ^[Yy]$ ]] || { log_warn "Отменено."; exit 0; }

# ============================================================================
#  УТИЛИТА: идемпотентная установка sysctl-параметра
# ============================================================================
set_sysctl() {
    local key="$1" value="$2" file="${3:-/etc/sysctl.conf}"
    # Удаляем все строки с этим ключом (закомментированные и нет), затем добавляем
    sed -i "/^[# ]*${key//./\\.}\s*=/d" "$file"
    echo "${key} = ${value}" >> "$file"
}

# ============================================================================
#  1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================================================
log_step "1/7 — ОБНОВЛЕНИЕ СИСТЕМЫ"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q
log_ok "Система обновлена"

# ============================================================================
#  2. УСТАНОВКА MICRO
# ============================================================================
log_step "2/7 — УСТАНОВКА MICRO"

if command -v micro &>/dev/null; then
    log_ok "micro уже установлен ($(micro --version 2>/dev/null | head -1))"
else
    apt-get install -y -q micro
    log_ok "micro установлен"
fi

# ============================================================================
#  3. SYSCTL — IPv6 OFF + TCP OPTIMIZATION
# ============================================================================
log_step "3/7 — SYSCTL (IPv6 OFF + ОПТИМИЗАЦИЯ)"

# --- Отключение IPv6 ---
set_sysctl "net.ipv6.conf.all.disable_ipv6" "1"
set_sysctl "net.ipv6.conf.default.disable_ipv6" "1"
set_sysctl "net.ipv6.conf.lo.disable_ipv6" "1"
log_ok "IPv6 отключён"

# --- TCP оптимизации ---
# BBR congestion control (лучше для VPS)
set_sysctl "net.core.default_qdisc" "fq"
set_sysctl "net.ipv4.tcp_congestion_control" "bbr"

# Backlog и очереди
set_sysctl "net.core.somaxconn" "65535"
set_sysctl "net.core.netdev_max_backlog" "65535"
set_sysctl "net.ipv4.tcp_max_syn_backlog" "65535"

# Буферы (в байтах: min default max)
set_sysctl "net.core.rmem_max" "16777216"
set_sysctl "net.core.wmem_max" "16777216"
set_sysctl "net.ipv4.tcp_rmem" "4096 87380 16777216"
set_sysctl "net.ipv4.tcp_wmem" "4096 65536 16777216"

# Быстрый TCP
set_sysctl "net.ipv4.tcp_fastopen" "3"
set_sysctl "net.ipv4.tcp_slow_start_after_idle" "0"
set_sysctl "net.ipv4.tcp_tw_reuse" "1"

# Keepalive (обнаружение мёртвых соединений быстрее)
set_sysctl "net.ipv4.tcp_keepalive_time" "300"
set_sysctl "net.ipv4.tcp_keepalive_intvl" "30"
set_sysctl "net.ipv4.tcp_keepalive_probes" "5"

# Защита от SYN-flood
set_sysctl "net.ipv4.tcp_syncookies" "1"

log_ok "TCP-оптимизации настроены"

# Применяем
sysctl -p /etc/sysctl.conf >/dev/null 2>&1
log_ok "sysctl применён"

# ============================================================================
#  4. SSH PORT
# ============================================================================
log_step "4/7 — SSH ПОРТ"

SSHD_CONFIG="/etc/ssh/sshd_config"

# Устанавливаем порт в основном конфиге
if grep -qE "^#?\s*Port\s+" "$SSHD_CONFIG"; then
    sed -i "s/^#*\s*Port\s\+.*/Port ${SSH_PORT}/" "$SSHD_CONFIG"
else
    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
fi

# Убираем переопределения порта из drop-in файлов (Ubuntu 24 может иметь cloud-init)
if [[ -d /etc/ssh/sshd_config.d ]]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -qE "^Port\s+" "$f" 2>/dev/null; then
            sed -i "s/^Port\s\+.*/#Port (overridden by vps-setup)/" "$f"
            log_warn "Переопределение порта закомментировано в $(basename "$f")"
        fi
    done
fi

systemctl daemon-reload 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

log_ok "SSH порт изменён на ${SSH_PORT}"

# Проверка
if ss -tlnp | grep -q ":${SSH_PORT}\b"; then
    log_ok "SSH слушает на порту ${SSH_PORT}"
else
    log_warn "SSH порт ${SSH_PORT} не обнаружен в ss — проверьте вручную: ss -ntpl"
fi

# ============================================================================
#  5. UFW
# ============================================================================
log_step "5/7 — UFW"

apt-get install -y -q ufw 2>/dev/null || true

# ВАЖНО: сначала добавляем правила, ПОТОМ включаем UFW
# Иначе можно потерять доступ к серверу!

# Стандартный SSH (22) — на всякий случай
ufw allow OpenSSH >/dev/null 2>&1
log_ok "Правило: OpenSSH (порт 22)"

# Кастомный порт
if [[ "$SSH_PORT" != "22" ]]; then
    ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
    log_ok "Правило: SSH кастомный порт ${SSH_PORT}/tcp"
fi

# Веб-порты (если выбрано)
if [[ "$OPEN_WEB" =~ ^[Yy]$ ]]; then
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    log_ok "Правило: HTTP (80/tcp), HTTPS (443/tcp)"
fi

# Включаем UFW (--force чтобы не спрашивал подтверждение)
ufw --force enable >/dev/null 2>&1
log_ok "UFW включён"

# ============================================================================
#  6. ОТКЛЮЧЕНИЕ ICMP (PING)
# ============================================================================
log_step "6/7 — БЛОКИРОВКА ICMP"

BEFORE_RULES="/etc/ufw/before.rules"

if [[ -f "$BEFORE_RULES" ]]; then
    # Создаём бэкап при первом запуске
    if [[ ! -f "${BEFORE_RULES}.bak.original" ]]; then
        cp "$BEFORE_RULES" "${BEFORE_RULES}.bak.original"
        log_ok "Бэкап: ${BEFORE_RULES}.bak.original"
    fi

    # Заменяем ACCEPT на DROP для всех ICMP-правил (input и forward)
    sed -i 's/\(-A ufw-before-input -p icmp --icmp-type .* -j \)ACCEPT/\1DROP/g' "$BEFORE_RULES"
    sed -i 's/\(-A ufw-before-forward -p icmp --icmp-type .* -j \)ACCEPT/\1DROP/g' "$BEFORE_RULES"

    # Добавляем source-quench если его нет
    if ! grep -q "icmp-type source-quench" "$BEFORE_RULES"; then
        # Вставляем после последнего ufw-before-input icmp правила
        sed -i '/^-A ufw-before-input -p icmp --icmp-type echo-request/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES"
        log_ok "Добавлено правило: source-quench DROP"
    fi

    log_ok "ICMP правила изменены на DROP"

    # Перезагружаем UFW для применения before.rules
    ufw --force disable >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    log_ok "UFW перезагружен"
else
    log_warn "${BEFORE_RULES} не найден — ICMP не заблокирован"
fi

# ============================================================================
#  7. HOSTNAME
# ============================================================================
log_step "7/7 — HOSTNAME"

CURRENT_HOSTNAME="$(hostname)"
if [[ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # Обновляем /etc/hosts если hostname там упоминается
    if grep -q "$CURRENT_HOSTNAME" /etc/hosts 2>/dev/null; then
        sed -i "s/${CURRENT_HOSTNAME}/${NEW_HOSTNAME}/g" /etc/hosts
    fi
    log_ok "Hostname изменён: ${CURRENT_HOSTNAME} → ${NEW_HOSTNAME}"
else
    log_ok "Hostname уже установлен: ${NEW_HOSTNAME}"
fi

# ============================================================================
#  ИТОГО
# ============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        НАСТРОЙКА ЗАВЕРШЕНА ✓             ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Hostname:  ${BOLD}${NEW_HOSTNAME}${NC}"
echo -e "${GREEN}║${NC} SSH порт:  ${BOLD}${SSH_PORT}${NC}"
echo -e "${GREEN}║${NC} IPv6:      ${BOLD}отключён${NC}"
echo -e "${GREEN}║${NC} TCP BBR:   ${BOLD}включён${NC}"
echo -e "${GREEN}║${NC} UFW:       ${BOLD}активен${NC}"
echo -e "${GREEN}║${NC} ICMP/Ping: ${BOLD}заблокирован${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠  ВАЖНО: Перед закрытием текущей сессии —${NC}"
echo -e "${YELLOW}   откройте НОВЫЙ терминал и проверьте подключение:${NC}"
echo -e "${BOLD}   ssh -p ${SSH_PORT} root@<IP>${NC}"
echo ""
echo -e "   Статус UFW:  ${CYAN}ufw status verbose${NC}"
echo -e "   Порты:       ${CYAN}ss -ntpl${NC}"
echo ""
