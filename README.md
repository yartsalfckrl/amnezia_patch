# awg-relay

Цепочка `клиент → РУ-вход (чистый AS) → backend (Amnezia/AmneziaWG)` для обхода
деградации трафика по AS на флагнутом зарубежном хостинге.

ТСПУ душит трафик к флагнутому AS backend'а. Решение — поставить впереди
**российский** сервер на чистом AS: ТСПУ видит лишь «абонент РФ → российский IP»
(норма), а хоп «РУ-вход → backend» идёт сервер-сервер и не привязан к абоненту.

Шифрование остаётся end-to-end между клиентом и backend. РУ-вход —
тупой ретранслятор UDP, крипту не трогает.

```
клиент (Amnezia GUI) --UDP:35662--> РУ-вход (DNAT) --UDP:35662--> backend (awg2)
```

## Полный цикл

1. **Backend.** Настроить Amnezia как обычно (поднимает контейнер `amnezia-awg2`).
   Backend про РУ-вход знать не должен.
2. **Экспорт.** В GUI Amnezia: Share → **AmneziaWG** → файл → `awg.conf`.
   (Именно AmneziaWG, не «нативный WireGuard» — нужен блок обфускации Jc/S/H.)
   Запомнить порт из строки `Endpoint` (напр. `35662`).
3. **РУ-вход.** Купить VPS у крупного РФ-провайдера (Timeweb/Selectel/RuVDS…),
   Ubuntu. Затем:
   ```bash
   git clone <repo> && cd awg-relay
   sudo ./setup-relay.sh --dest 5.104.75.166 --port 35662
   ```
4. **Патч клиента.**
   ```bash
   ./patch-client.sh --in awg.conf --ru <RU_ENTRY_IP>
   # -> awg-relay.conf
   ```
5. **Импорт.** В Amnezia: Add → Import from file → `awg-relay.conf` → подключиться.
6. **Проверка под нагрузкой** (качать что-то через VPN параллельно):
   ```bash
   mtr 10.8.1.1          # внутренний адрес туннеля
   mtr 5.104.75.166      # путь до backend
   ```
   Первый хоп `клиент → РУ-вход` должен быть чистым, потери не растут под нагрузкой.

## Скрипты

### setup-relay.sh (на РУ-входе, root)
Идемпотентный. Ставит DNAT/MASQUERADE для UDP-порта, включает ip_forward,
ставит systemd-unit (переживает reboot и смену вводных).
```bash
sudo ./setup-relay.sh --dest <BACKEND_IP> --port <PORT>          # основное
sudo ./setup-relay.sh --dest <BACKEND_IP> --port <PORT> --tcp 4443  # +Reality-фолбэк
sudo ./setup-relay.sh --status                                   # показать правила
sudo ./setup-relay.sh --remove                                   # снять всё
```
Правила помечаются comment'ом `relay-managed` — повторный запуск пересоздаёт
только свои правила, чужой firewall не трогает.

### patch-client.sh (на клиенте)
Меняет в экспортированном `.conf` только хост в `Endpoint` на РУ-вход.
Порт, ключи, Jc/S/H, AllowedIPs — не трогает. Добавляет PersistentKeepalive=25.
```bash
./patch-client.sh --in awg.conf --ru <RU_ENTRY_IP> [--out awg-relay.conf]
```

## Если первый хоп всё равно топит под нагрузкой

Релей лечит деградацию **по AS**. Если после него хоп `клиент → РУ-вход`
проседает именно под нагрузкой — причина не AS, а одно из:
- **UDP-шейпинг** у мобильного оператора (AWG — это UDP). Лечится уходом на TCP:
  пробросить TCP-порт Reality (`--tcp 4443`) и переключиться на Xray-профиль.
- **Сигнатура** AWG. У тебя CPS/I-параметры (`I2..I5`) пустые — есть куда расти
  (QUIC-мимикрия), либо тот же уход на Reality.

## Безопасность
- Не оформляй РУ-вход как публичный VPN-сервис, держи низкий профиль.
- В экспортах/конфиге Amnezia встречается root-пароль backend в открытом виде —
  смени его на SSH-ключи.
