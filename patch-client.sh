#!/usr/bin/env bash
set -euo pipefail

IN=""; RELAY=""; OUT=""; LPORT=""

die(){ echo "Ошибка: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)    IN="$2"; shift 2 ;;
    --relay) RELAY="$2"; shift 2 ;;
    --lport) LPORT="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    -h|--help)
      echo "patch-client --in FILE --relay IP [--lport PORT] [--out FILE]"; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ -n "$IN" ]]    || die "не задан --in"
[[ -n "$RELAY" ]] || die "не задан --relay"
[[ -f "$IN" ]]    || die "файл не найден: $IN"
[[ "$RELAY" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "--relay должен быть IPv4"
[[ -n "$OUT" ]]   || OUT="${IN%.conf}-relay.conf"

EP="$(grep -iE '^[[:space:]]*Endpoint' "$IN" || true)"
[[ -n "$EP" ]] || die "в $IN нет строки Endpoint"
PORT="${LPORT:-$(sed -E 's/.*:([0-9]+).*/\1/' <<<"$EP")}"

cp "$IN" "$OUT"
sed -i -E "s|^([[:space:]]*Endpoint[[:space:]]*=[[:space:]]*).*$|\1${RELAY}:${PORT}|I" "$OUT"

if grep -qiE '^[[:space:]]*PersistentKeepalive' "$OUT"; then
  sed -i -E "s|^([[:space:]]*PersistentKeepalive[[:space:]]*=[[:space:]]*).*$|\115|I" "$OUT"
else
  printf '\nPersistentKeepalive = 15\n' >> "$OUT"
fi

echo "Готово: $OUT"
grep -iE '^[[:space:]]*Endpoint' "$OUT" | sed 's/^/  /'
