<p align="center"><img src="docs/icon.png" width="128" alt="MacMote icon"></p>

<h1 align="center">MacMote</h1>

<p align="center">
  Легкий пульт для <b>Android TV / Google TV</b> і телевізорів <b>Samsung на Tizen</b> у рядку меню macOS.
</p>

<p align="center"><a href="README.md">English</a> · <b>Українська</b></p>

<p align="center"><img src="docs/screenshot.png" width="460" alt="MacMote — світла і темна тема"></p>

## Можливості

- **Пульт у рядку меню** — клік по іконці відкриває пульт; він не забирає фокус в активної програми.
- **Android TV і Samsung** — MacMote сам знаходить обидва типи телевізорів у мережі. Якщо їх кілька, обери потрібний на пульті або через правий клік → **Телевізор**.
- **Набір тексту з клавіатури Mac** — кнопка ⌨ (або `K`) відкриває поле, текст одразу з'являється на TV (кирилиця теж), `Enter` — відправити пошук.
- **Керування клавішами**, поки пульт відкритий:

  | Клавіша | Дія |
  |---|---|
  | `↑ ↓ ← →` | навігація |
  | `Enter` | OK |
  | `⌫` | назад |
  | `Space` | відтворення / пауза |
  | `H` | головний екран |
  | `M` | без звуку |
  | `+` / `−` | гучність |
  | `K` | клавіатура |
  | `Esc` | закрити пульт |

- **Утримання** стрілок і гучності повторює натискання.
- **Wake-on-LAN** — кнопка живлення будить TV зі сну (після першого підключення).
- **Світла / темна тема**, VoiceOver, «Запускати при вході».
- **Легкість** — нативний Swift без залежностей, бінарник ~0.6 МБ, у простої 0% CPU. З'єднання з TV закривається через 90 с після закриття пульта, інтерфейс вивантажується з пам'яті.

## Вимоги

- macOS 15 Sequoia або новіша (Apple Silicon або Intel)
- Телевізор у тій самій мережі:
  - **Android TV / Google TV** з підтримкою Android TV Remote Service (усі сучасні TV з Google TV, Chromecast with Google TV, Sony, TCL, Philips тощо);
  - **Samsung Smart TV на Tizen** (2016 року і новіші).

## Встановлення

1. Завантаж `MacMote.zip` з [Releases](../../releases), розпакуй і перенеси `MacMote.app` у «Програми».
2. Програма підписана ad-hoc (без Apple Developer ID), тож при першому запуску: **правий клік → Відкрити**, або:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacMote.app
   ```
3. Дозволь доступ до **локальної мережі**, коли macOS запитає.
4. Клікни іконку пульта й сполучи TV один раз:
   - **Android TV:** на TV з'явиться 6-значний код — введи його на пульті.
   - **Samsung:** TV запитає, чи дозволити MacMote, — обери **Дозволити**.

   Далі підключення автоматичне.

Щоб Wake-on-LAN працював на Samsung, увімкни в налаштуваннях TV **«Увімкнення з мобільного»**.

## Збірка з вихідного коду

Потрібні лише Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh        # build/MacMote.app
./build.sh zip    # + build/MacMote.zip для релізу
```

Іконку перегенерувати: `swift scripts/make-icon.swift`.

## Як це працює

**Пошук** іде паралельно: Bonjour (`_androidtvremote2._tcp`) для Android TV, а для Samsung — SSDP з перевіркою `http://<ip>:8001/api/v2/`.

**Android TV / Google TV** — той самий протокол, що й в офіційному застосунку Google TV на телефоні (**Android TV Remote v2**):

- **Сполучення** — TLS на порту `6467`: клієнтський сертифікат (генерується один раз, `~/Library/Application Support/MacMote`) і код з екрана TV, що підтверджує SHA-256 від публічних ключів обох сторін.
- **Керування** — TLS на порту `6466`, protobuf-повідомлення з кодами клавіш Android, текст — через IME batch edit.

**Samsung Tizen** — WebSocket API SmartView:

- **Сполучення** — перше підключення до `wss://<ip>:8002/api/v2/channels/samsung.remote.control` показує на TV запит «Дозволити»; після нього TV видає токен, який MacMote зберігає для наступних підключень.
- **Керування** — JSON-повідомлення `ms.remote.control` з кодами `KEY_*`, текст — через `SendInputString`.

| Файл | Що всередині |
|---|---|
| `Sources/main.swift` | рядок меню, панель, клавіатурні скорочення |
| `Sources/RemoteView.swift` | інтерфейс пульта (SwiftUI) |
| `Sources/TVClient.swift` | вибір TV, перепідключення, коди клавіш, Wake-on-LAN |
| `Sources/Discovery.swift` | пошук через Bonjour і SSDP |
| `Sources/AndroidTV.swift` | протокол Android TV Remote v2 |
| `Sources/SamsungTV.swift` | протокол Samsung SmartView |
| `Sources/Identity.swift` | клієнтський сертифікат і RSA-ключі (Android TV) |
| `Sources/Proto.swift` | мінімальний protobuf-кодек (Android TV) |

## Скинути сполучення

Правий клік по іконці → **Сполучити з TV заново**.

## Автор

© 2026 klimasevskiy
