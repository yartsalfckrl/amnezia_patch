#!/usr/bin/env bash
#
# patch-client.sh — клиент (Arch): подменить Endpoint в экспортированном
# AmneziaWG-конфиге на адрес РУ-входа. Порт и вся крипта остаются родными.
#
# Запускается НА ТВОЕЙ МАШИНЕ после экспорта конфига из приложения Amnezia
# (Share -> AmneziaWG -> файл). Результат импортируешь в Amnezia как НОВОЕ
# подключение.
#
# Использование:
#   ./patch-client.sh --in awg.conf --ru 203.0.113.7
#   ./patch-client.sh --in awg.conf --ru 203.0.113.7 --out awg-relay.conf
#
set -euo pipefail

IN=""
RU_IP=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)  IN="$2";  shift 2 ;;
    --ru)  RU_IP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

die(){ echo "ОШИБКА: $*" >&2; exit 1; }

[[ -n "$IN"    ]] || die "не задан --in (экспортированный .conf)"
[[ -n "$RU_IP" ]] || die "не задан --ru (IP РУ-входа)"
[[ -f "$IN"    ]] || die "файл не найден: $IN"
[[ "$RU_IP" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "--ru должен быть IPv4"
[[ -n "$OUT" ]] || OUT="${IN%.conf}-relay.conf"

# 1) достать текущий Endpoint-хост (то, что меняем).
#    Строка вида:  Endpoint = 5.104.75.166:35662
EP_LINE="$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$IN" || true)"
[[ -n "$EP_LINE" ]] || die "в $IN нет строки Endpoint — это точно AmneziaWG .conf?"

BACKEND_HOST="$(sed -E 's/.*=[[:space:]]*([^:]+):.*/\1/' <<<"$EP_LINE" | tr -d '[:space:]')"
EP_PORT="$(sed -E 's/.*:([0-9]+).*/\1/' <<<"$EP_LINE")"
echo "[*] Backend в конфиге : $BACKEND_HOST:$EP_PORT"
echo "[*] Новый Endpoint    : $RU_IP:$EP_PORT  (порт не меняется)"

# 2) сборка нового конфига.
#    Меняем ТОЛЬКО хост в строке Endpoint. Остальное (ключи, Jc/S/H,
#    AllowedIPs, Address) не трогаем. Порт оставляем как был.
cp "$IN" "$OUT"
sed -i -E "s|^([[:space:]]*Endpoint[[:space:]]*=[[:space:]]*)[^:]+:|\1${RU_IP}:|I" "$OUT"

# 3) гарантировать PersistentKeepalive (держит UDP-сессию живой через NAT релея)
if ! grep -qiE '^[[:space:]]*PersistentKeepalive' "$OUT"; then
  # добавить в конец секции [Peer]
  printf '\nPersistentKeepalive = 25\n' >> "$OUT"
  echo "[*] Добавлен PersistentKeepalive = 25"
fi

# 4) проверка результата
NEW_EP="$(grep -iE '^[[:space:]]*Endpoint[[:space:]]*=' "$OUT")"
echo "[+] Записан: $OUT"
echo "    $NEW_EP"
echo
echo "[i] Дальше: импортируй $OUT в Amnezia как НОВОЕ подключение"
echo "    (Add -> Import from file), затем подключись и проверь mtr под нагрузкой."

# Предупреждение про обфускацию: без Jc/S/H на первом хопе поедет голый WG.
if ! grep -qiE '^[[:space:]]*(Jc|S1|H1)[[:space:]]*=' "$OUT"; then
  echo
  echo "[!] ВНИМАНИЕ: в конфиге не видно параметров обфускации (Jc/S1/H1)."
  echo "    Это похоже на чистый WireGuard, а не AmneziaWG — ТСПУ ловит его по"
  echo "    сигнатуре даже к российскому IP. Экспортируй именно AmneziaWG-профиль."
fi
