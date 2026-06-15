#!/usr/bin/env bash
set -euo pipefail

TAG="relay-managed"
DIR="/etc/relay"
SYSCTL="/etc/sysctl.d/99-relay.conf"
UNIT="/etc/systemd/system/relay.service"
SELF="$(readlink -f "$0")"

NAME=""; DEST=""; DPORT=""; LPORT=""; PROTO="udp"

die(){ echo "Ошибка: $*" >&2; exit 1; }
root(){ [[ $EUID -eq 0 ]] || die "нужен root"; }
ufw_on(){ command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; }

usage(){
cat <<U
relay — форвардинг порта на backend.

  add    --name N --dest IP --dport PORT [--lport PORT] [--proto udp|tcp]
  remove --name N
  list
  reapply
  purge
U
}

[[ $# -gt 0 ]] || { usage; exit 1; }
ACTION="$1"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --dport) DPORT="$2"; shift 2 ;;
    --lport) LPORT="$2"; shift 2 ;;
    --proto) PROTO="$2"; shift 2 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

tune(){
  cat > "$SYSCTL" <<EOF
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_udp_timeout=120
net.netfilter.nf_conntrack_udp_timeout_stream=600
EOF
  sysctl -q -p "$SYSCTL" 2>/dev/null || true
}

clear_route(){
  { iptables-save -t nat | { grep -v -- "--comment $1" || true; }; } | iptables-restore -T nat
}

add_rules(){
  iptables -t nat -A PREROUTING -p "$4" --dport "$3" -j DNAT --to-destination "${1}:${2}" -m comment --comment "$5"
  iptables -t nat -A POSTROUTING -p "$4" -d "$1" --dport "$2" -j MASQUERADE -m comment --comment "$5"
  ufw_on && ufw allow "${3}/${4}" >/dev/null 2>&1 || true
}

unit(){
  cat > "$UNIT" <<EOF
[Unit]
Description=relay routes
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF reapply
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable relay.service >/dev/null 2>&1 || true
}

case "$ACTION" in
  add)
    root
    [[ -n "$NAME" && -n "$DEST" && -n "$DPORT" ]] || die "нужны --name --dest --dport"
    [[ "$DEST" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "--dest должен быть IPv4"
    LPORT="${LPORT:-$DPORT}"
    for f in "$DIR"/*.route; do
      [[ -e "$f" ]] || continue
      n=$(. "$f"; echo "$NAME"); p=$(. "$f"; echo "$LPORT"); pr=$(. "$f"; echo "$PROTO")
      [[ "$n" != "$NAME" && "$p" == "$LPORT" && "$pr" == "$PROTO" ]] && die "порт $LPORT/$PROTO занят маршрутом '$n'"
    done
    tune
    clear_route "${TAG}:${NAME}"
    add_rules "$DEST" "$DPORT" "$LPORT" "$PROTO" "${TAG}:${NAME}"
    mkdir -p "$DIR"
    printf 'NAME=%s\nDEST=%s\nDPORT=%s\nLPORT=%s\nPROTO=%s\n' "$NAME" "$DEST" "$DPORT" "$LPORT" "$PROTO" > "$DIR/$NAME.route"
    unit
    echo "Добавлен: $NAME  :$LPORT/$PROTO -> $DEST:$DPORT"
    ;;
  remove)
    root; [[ -n "$NAME" ]] || die "нужен --name"
    clear_route "${TAG}:${NAME}"
    [[ -f "$DIR/$NAME.route" ]] && { p=$(. "$DIR/$NAME.route"; echo "$LPORT"); pr=$(. "$DIR/$NAME.route"; echo "$PROTO"); ufw_on && ufw delete allow "${p}/${pr}" >/dev/null 2>&1 || true; rm -f "$DIR/$NAME.route"; }
    echo "Удалён: $NAME"
    ;;
  list)
    for f in "$DIR"/*.route; do
      [[ -e "$f" ]] || { echo "Маршрутов нет"; break; }
      ( . "$f"; printf '%s  :%s/%s -> %s:%s\n' "$NAME" "$LPORT" "$PROTO" "$DEST" "$DPORT" )
    done
    ;;
  reapply)
    root; tune
    for f in "$DIR"/*.route; do
      [[ -e "$f" ]] || continue
      ( . "$f"; clear_route "${TAG}:${NAME}"; add_rules "$DEST" "$DPORT" "$LPORT" "$PROTO" "${TAG}:${NAME}" )
    done
    echo "Маршруты восстановлены"
    ;;
  purge)
    root
    { iptables-save -t nat | { grep -v -- "--comment $TAG" || true; }; } | iptables-restore -T nat
    systemctl disable --now relay.service 2>/dev/null || true
    rm -f "$UNIT" "$SYSCTL"; rm -rf "$DIR"; systemctl daemon-reload 2>/dev/null || true
    echo "Всё удалено"
    ;;
  *) usage; exit 1 ;;
esac
