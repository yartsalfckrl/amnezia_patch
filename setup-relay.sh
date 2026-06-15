#!/usr/bin/env bash
set -euo pipefail

TAG="relay-managed"
ENV_DIR="/etc/relay"
SYSCTL_FILE="/etc/sysctl.d/99-relay.conf"
UNIT_FILE="/etc/systemd/system/relay.service"
SELF_PATH="$(readlink -f "$0")"

ACTION=""
NAME=""
DEST=""
DPORT=""
LPORT=""
PROTO="udp"

usage(){
  cat <<USAGE
relay — форвардинг порта на backend. Несколько маршрутов работают параллельно.

  add     --name N --dest IP --dport PORT [--lport PORT] [--proto udp|tcp]
  remove  --name N
  list
  reapply
  purge

  --name   уникальное имя маршрута (метка правил и ключ для удаления)
  --dest   IP backend
  --dport  порт на backend
  --lport  входной порт на этом сервере (по умолчанию = --dport)
  --proto  udp (по умолчанию) или tcp
USAGE
}

die(){ echo "ОШИБКА: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "нужен root (sudo)"; }
have_ufw(){ command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; }

[[ $# -gt 0 ]] || { usage; exit 1; }
ACTION="$1"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --dest)  DEST="$2"; shift 2 ;;
    --dport) DPORT="$2"; shift 2 ;;
    --lport) LPORT="$2"; shift 2 ;;
    --proto) PROTO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

enable_forwarding(){
  echo 'net.ipv4.ip_forward=1' > "$SYSCTL_FILE"
  sysctl -q -p "$SYSCTL_FILE"
}

# Снять правила одного маршрута по его метке "TAG:NAME".
clear_route(){
  local label="$1"
  { iptables-save -t nat \
      | { grep -v -- "--comment ${label}\b" || true; } \
      | { grep -v -- "--comment \"${label}\"" || true; }
  } | iptables-restore -T nat
}

install_unit(){
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=relay routes (DNAT to backends)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_PATH reapply

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable relay.service >/dev/null 2>&1 || true
}

apply_route(){
  local name="$1" dest="$2" dport="$3" lport="$4" proto="$5"
  local label="${TAG}:${name}"
  iptables -t nat -A PREROUTING  -p "$proto" --dport "$lport" \
    -j DNAT --to-destination "${dest}:${dport}" \
    -m comment --comment "$label"
  iptables -t nat -A POSTROUTING -p "$proto" -d "$dest" --dport "$dport" \
    -j MASQUERADE \
    -m comment --comment "$label"
  if have_ufw; then ufw allow "${lport}/${proto}" >/dev/null || true; fi
}

save_route(){
  mkdir -p "$ENV_DIR"
  cat > "${ENV_DIR}/${1}.route" <<ROUTE
NAME=$1
DEST=$2
DPORT=$3
LPORT=$4
PROTO=$5
ROUTE
}

do_add(){
  need_root
  [[ -n "$NAME"  ]] || die "не задан --name"
  [[ -n "$DEST"  ]] || die "не задан --dest"
  [[ -n "$DPORT" ]] || die "не задан --dport"
  [[ "$DEST" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "--dest должен быть IPv4"
  [[ "$PROTO" == "udp" || "$PROTO" == "tcp" ]] || die "--proto: udp или tcp"
  LPORT="${LPORT:-$DPORT}"
  command -v iptables >/dev/null || { apt-get update -qq; apt-get install -y iptables; }

  for f in "${ENV_DIR}"/*.route; do
    [[ -e "$f" ]] || continue
    local en ep epr
    en="$(.  "$f"; echo "$NAME")"
    ep="$(.  "$f"; echo "$LPORT")"
    epr="$(. "$f"; echo "$PROTO")"
    if [[ "$en" != "$NAME" && "$ep" == "$LPORT" && "$epr" == "$PROTO" ]]; then
      die "входной порт ${LPORT}/${PROTO} уже занят маршрутом '$en' — задай другой --lport"
    fi
  done

  enable_forwarding
  clear_route "${TAG}:${NAME}"
  apply_route "$NAME" "$DEST" "$DPORT" "$LPORT" "$PROTO"
  save_route "$NAME" "$DEST" "$DPORT" "$LPORT" "$PROTO"
  install_unit

  echo "[+] маршрут '$NAME' добавлен:  :${LPORT}/${PROTO}  ->  ${DEST}:${DPORT}"
  do_list
  echo
  echo "[i] проверка с клиента под нагрузкой:"
  echo "      mtr <этот_сервер>     # первый хоп, потери ~0"
  echo "      mtr ${DEST}           # путь до backend"
}

do_remove(){
  need_root
  [[ -n "$NAME" ]] || die "не задан --name"
  clear_route "${TAG}:${NAME}"
  if [[ -f "${ENV_DIR}/${NAME}.route" ]]; then
    local lp pr; lp="$(. "${ENV_DIR}/${NAME}.route"; echo "$LPORT")"; pr="$(. "${ENV_DIR}/${NAME}.route"; echo "$PROTO")"
    have_ufw && ufw delete allow "${lp}/${pr}" >/dev/null 2>&1 || true
    rm -f "${ENV_DIR}/${NAME}.route"
  fi
  echo "[+] маршрут '$NAME' снят"
  do_list
}

do_list(){
  echo "== активные маршруты =="
  local found=0
  for f in "${ENV_DIR}"/*.route; do
    [[ -e "$f" ]] || continue
    found=1
    ( . "$f"; printf "  %-12s :%s/%s -> %s:%s\n" "$NAME" "$LPORT" "$PROTO" "$DEST" "$DPORT" )
  done
  [[ $found -eq 1 ]] || echo "  (нет)"
  echo "== правила в iptables (nat) =="
  iptables -t nat -S | grep -- "$TAG" | sed 's/^/  /' || echo "  (нет)"
}

do_reapply(){
  need_root
  enable_forwarding
  for f in "${ENV_DIR}"/*.route; do
    [[ -e "$f" ]] || continue
    ( . "$f"
      { iptables-save -t nat | { grep -v -- "--comment ${TAG}:${NAME}\b" || true; }; } | iptables-restore -T nat
      iptables -t nat -A PREROUTING  -p "$PROTO" --dport "$LPORT" -j DNAT --to-destination "${DEST}:${DPORT}" -m comment --comment "${TAG}:${NAME}"
      iptables -t nat -A POSTROUTING -p "$PROTO" -d "$DEST" --dport "$DPORT" -j MASQUERADE -m comment --comment "${TAG}:${NAME}"
    )
  done
  do_list
}

do_purge(){
  need_root
  { iptables-save -t nat | { grep -v -- "--comment ${TAG}" || true; } | { grep -v -- "--comment \"${TAG}" || true; }; } | iptables-restore -T nat
  systemctl disable --now relay.service 2>/dev/null || true
  rm -f "$UNIT_FILE" "$SYSCTL_FILE"
  rm -rf "$ENV_DIR"
  systemctl daemon-reload 2>/dev/null || true
  echo "[+] все маршруты и юнит удалены"
}

case "$ACTION" in
  add)     do_add ;;
  remove)  do_remove ;;
  list)    do_list ;;
  reapply) do_reapply ;;
  purge)   do_purge ;;
  *) usage; exit 1 ;;
esac
