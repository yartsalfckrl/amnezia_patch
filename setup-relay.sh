#!/usr/bin/env bash
#
# setup-relay.sh — РУ-вход: форвардинг UDP-порта AmneziaWG на backend (NUXTCLOUD).
#
# Запускается НА РОССИЙСКОМ сервере (чистый AS).
# Тупой ретранслятор: принимает UDP на :PORT и шлёт на DEST:PORT.
# Крипту не трогает, шифрование остаётся end-to-end клиент<->backend.
#
# Идемпотентно: можно запускать сколько угодно раз, состояние одинаковое.
# Правила помечаются comment'ом RELAY_TAG, при перезапуске сносятся только свои.
#
# Использование:
#   sudo ./setup-relay.sh --dest 5.104.75.166 --port 35662
#   sudo ./setup-relay.sh --dest 5.104.75.166 --port 35662 --tcp 4443   # +Reality-фолбэк
#   sudo ./setup-relay.sh --status     # показать текущие правила
#   sudo ./setup-relay.sh --remove     # снять всё, что поставил скрипт
#
set -euo pipefail

RELAY_TAG="relay-managed"          # маркер наших правил в iptables
ENV_FILE="/etc/relay/relay.env"    # сюда сохраняем вводные для systemd/перезапуска
SYSCTL_FILE="/etc/sysctl.d/99-relay.conf"
UNIT_FILE="/etc/systemd/system/relay.service"
SELF_PATH="$(readlink -f "$0")"

DEST_IP=""
UDP_PORT=""
TCP_PORT=""        # опционально: проброс TCP (для Reality-запаски через тот же вход)
ACTION="apply"

# ---------- разбор аргументов ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)   DEST_IP="$2"; shift 2 ;;
    --port)   UDP_PORT="$2"; shift 2 ;;
    --tcp)    TCP_PORT="$2"; shift 2 ;;
    --status) ACTION="status"; shift ;;
    --remove) ACTION="remove"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

# ---------- утилиты ----------
die(){ echo "ОШИБКА: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "нужен root (sudo)"; }

# Удалить ВСЕ наши правила (по RELAY_TAG) из таблицы nat, не трогая чужие.
# iptables-save -t nat -> выкидываем строки с нашим тегом -> грузим обратно.
clear_our_rules(){
  iptables-save -t nat \
    | grep -v -- "--comment ${RELAY_TAG}" \
    | grep -v -- "--comment \"${RELAY_TAG}\"" \
    | iptables-restore -T nat
}

load_env(){ [[ -f "$ENV_FILE" ]] && . "$ENV_FILE" || true; }

# ---------- действия ----------
do_status(){
  echo "== Наши NAT-правила (${RELAY_TAG}) =="
  iptables -t nat -S | grep -- "${RELAY_TAG}" || echo "(нет)"
  echo
  echo "== net.ipv4.ip_forward =="
  sysctl -n net.ipv4.ip_forward
  echo
  echo "== relay.service =="
  systemctl is-enabled relay.service 2>/dev/null || echo "(не установлен)"
  [[ -f "$ENV_FILE" ]] && { echo "== $ENV_FILE =="; cat "$ENV_FILE"; }
}

do_remove(){
  need_root
  echo "[*] Снимаю правила relay..."
  clear_our_rules
  rm -f "$SYSCTL_FILE"
  systemctl disable --now relay.service 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload 2>/dev/null || true
  echo "[+] Удалено. (ENV $ENV_FILE оставлен — удали вручную при желании.)"
}

do_apply(){
  need_root

  # Если вводные не переданы в этот запуск — взять из сохранённого env
  # (так systemd при ребуте поднимает то же самое).
  if [[ -z "$DEST_IP" || -z "$UDP_PORT" ]]; then
    load_env
    DEST_IP="${DEST_IP:-${RELAY_DEST:-}}"
    UDP_PORT="${UDP_PORT:-${RELAY_UDP_PORT:-}}"
    TCP_PORT="${TCP_PORT:-${RELAY_TCP_PORT:-}}"
  fi
  [[ -n "$DEST_IP"  ]] || die "не задан --dest (IP backend)"
  [[ -n "$UDP_PORT" ]] || die "не задан --port (UDP-порт AmneziaWG)"
  [[ "$DEST_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "--dest должен быть IPv4"

  command -v iptables >/dev/null || { apt-get update -qq && apt-get install -y iptables; }

  echo "[*] Backend  : $DEST_IP"
  echo "[*] UDP-порт : $UDP_PORT"
  [[ -n "$TCP_PORT" ]] && echo "[*] TCP-порт : $TCP_PORT (Reality-фолбэк)"

  # 1) включить маршрутизацию пакетов между интерфейсами
  echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE"

  # 2) идемпотентность: снести прошлые наши правила
  clear_our_rules

  # 3) поставить заново, с маркером RELAY_TAG
  # UDP — основной трафик AmneziaWG
  iptables -t nat -A PREROUTING  -p udp --dport "$UDP_PORT" \
    -j DNAT --to-destination "${DEST_IP}:${UDP_PORT}" \
    -m comment --comment "$RELAY_TAG"
  iptables -t nat -A POSTROUTING -p udp -d "$DEST_IP" --dport "$UDP_PORT" \
    -j MASQUERADE \
    -m comment --comment "$RELAY_TAG"

  # TCP — опционально (Reality на том же входе)
  if [[ -n "$TCP_PORT" ]]; then
    iptables -t nat -A PREROUTING  -p tcp --dport "$TCP_PORT" \
      -j DNAT --to-destination "${DEST_IP}:${TCP_PORT}" \
      -m comment --comment "$RELAY_TAG"
    iptables -t nat -A POSTROUTING -p tcp -d "$DEST_IP" --dport "$TCP_PORT" \
      -j MASQUERADE \
      -m comment --comment "$RELAY_TAG"
  fi

  # 4) открыть порт в ufw, если он активен (иначе пропускаем молча)
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${UDP_PORT}/udp" >/dev/null || true
    [[ -n "$TCP_PORT" ]] && ufw allow "${TCP_PORT}/tcp" >/dev/null || true
    echo "[*] ufw: порты открыты"
  fi

  # 5) сохранить вводные для перезапуска/ребута
  mkdir -p "$(dirname "$ENV_FILE")"
  {
    echo "RELAY_DEST=$DEST_IP"
    echo "RELAY_UDP_PORT=$UDP_PORT"
    echo "RELAY_TCP_PORT=$TCP_PORT"
  } > "$ENV_FILE"

  # 6) systemd-unit: при загрузке заново прогоняет этот же скрипт.
  #    Переживает reboot И смену вводных (поправил env -> systemctl restart relay).
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AmneziaWG UDP relay (DNAT to backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=$ENV_FILE
ExecStart=$SELF_PATH
ExecStop=$SELF_PATH --remove

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable relay.service >/dev/null 2>&1 || true

  echo
  echo "[+] Готово. Текущие правила:"
  iptables -t nat -S | grep -- "${RELAY_TAG}" | sed 's/^/    /'
  echo
  echo "[i] Проверка с клиента ПОД НАГРУЗКОЙ (качай что-то через VPN параллельно):"
  echo "      mtr 10.8.1.1            # внутренний адрес туннеля"
  echo "      mtr $DEST_IP           # путь до backend"
  echo "[i] Если первый хоп клиент->этот сервер чистый и потери не растут — успех."
}

case "$ACTION" in
  apply)  do_apply  ;;
  status) do_status ;;
  remove) do_remove ;;
esac
