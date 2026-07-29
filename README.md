# 🚀 VPS Customization

Автоматическая настройка VPS на **Ubuntu 24.04** с нуля за одну команду.

## ⚡ Быстрая установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/V2P-Dev/vps-customization/main/vps-setup.sh)
```

> Запускать от **root**. Скрипт задаст интерактивные вопросы перед началом работы.

---

## 📋 Что настраивает

| Компонент | Действие |
|-----------|----------|
| **Система** | `apt update && upgrade`, установка `micro` |
| **IPv6** | Полное отключение через `sysctl` |
| **TCP** | BBR congestion control, увеличенные буферы, fast open, оптимизация keepalive |
| **SSH** | Смена порта (спрашивает при запуске) |
| **UFW** | Файрвол с правилами для SSH, опционально 80/443 |
| **ICMP** | Блокировка ping и всех ICMP-типов |
| **Hostname** | Установка нового hostname (спрашивает при запуске) |

## 🔒 Безопасность

- UFW-правила добавляются **до** включения файрвола — нет риска потерять SSH-доступ
- Порт 22 остаётся открытым как подстраховка при смене SSH-порта
- Бэкап `before.rules` создаётся при первом запуске
- Скрипт **идемпотентный** — безопасен для повторного запуска
- SYN-flood защита через `tcp_syncookies`

## 🛡️ Sysctl-оптимизации

```
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn              = 65535
net.core.netdev_max_backlog     = 65535
net.ipv4.tcp_max_syn_backlog    = 65535
net.core.rmem_max               = 16777216
net.core.wmem_max               = 16777216
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_keepalive_time     = 300
net.ipv4.tcp_keepalive_intvl    = 30
net.ipv4.tcp_keepalive_probes   = 5
net.ipv4.tcp_syncookies         = 1
```

## ⚠️ После запуска

**Не закрывайте текущую SSH-сессию!** Откройте новый терминал и проверьте подключение:

```bash
ssh -p <ваш_порт> root@<IP>
```

Проверка статуса:
```bash
ufw status verbose
ss -ntpl
```

---

# 🌐 WARP Proxy Setup

Настройка Cloudflare WARP в режиме локального SOCKS5-прокси.

## ⚡ Быстрая установка

```bash
bash <(curl -sL https://raw.githubusercontent.com/V2P-Dev/vps-customization/main/warp-setup.sh)
```

> Запускать от **root** на сервере.

## 📋 Что делает `warp-setup.sh`

| Шаг | Действие |
|-----|----------|
| 1 | Установка `cloudflare-warp` из официального репозитория |
| 2 | Регистрация клиента (`warp-cli registration new`) |
| 3 | Режим `proxy`, порт настраивается (по умолчанию `40000`) |
| 4 | Подключение и проверка статуса (`Connected`) + проверка `ss -lntp` |
| 5 | `systemd` override `Restart=always` для `warp-svc` (автоперезапуск при падении) |
| 6 | Проверка реального выхода в интернет через WARP (`cdn-cgi/trace`, ждём `warp=on`) |

Скрипт идемпотентный: повторный запуск не ломает существующую установку — проверяет текущее состояние перед каждым шагом.

## 🔌 Использование с 3x-ui / Xray

После успешной настройки в конфиге Xray добавьте outbound:

```json
{
  "protocol": "socks",
  "settings": {
    "servers": [{ "address": "127.0.0.1", "port": 40000 }]
  },
  "tag": "warp-out"
}
```

и направьте нужный routing-rule на `warp-out`.

## 🛠 Диагностика

```bash
warp-cli status                 # статус подключения
ss -lntp | grep 40000           # прокси слушает локально
journalctl -u warp-svc -f       # логи демона
curl --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

Если `warp-svc` падает — override `/etc/systemd/system/warp-svc.service.d/override.conf` с `Restart=always` перезапускает демон автоматически через 10 секунд.

## 📄 Лицензия

MIT
