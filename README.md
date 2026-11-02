<p align="center"><img src="docs/icon.png" width="128" alt="MacMote icon"></p>

<h1 align="center">MacMote</h1>

<p align="center">
  A tiny menu bar remote for <b>Android TV / Google TV</b> on macOS.
</p>

<p align="center"><b>English</b> · <a href="README.uk.md">Українська</a></p>

<p align="center"><img src="docs/screenshot.png" width="460" alt="MacMote in light and dark mode"></p>

## Features

- **Lives in the menu bar.** Click the icon to open the remote. It never steals focus from the app you're using.
- **Type with your Mac keyboard.** The ⌨ button (or `K`) opens a text field. What you type shows up on the TV instantly (any language), and `Enter` submits the search.
- **Keyboard control** while the remote is open:

  | Key | Action |
  |---|---|
  | `↑ ↓ ← →` | navigate |
  | `Enter` | OK |
  | `⌫` | back |
  | `Space` | play / pause |
  | `H` | home |
  | `M` | mute |
  | `+` / `−` | volume |
  | `K` | keyboard |
  | `Esc` | close the remote |

- **Press and hold** the arrows or volume to repeat.
- **Wake-on-LAN.** The power button wakes the TV from sleep (after the first connection).
- **Light / dark mode**, VoiceOver support, launch at login.
- **Lightweight.** Native Swift with no dependencies, a ~0.6 MB binary, and 0% CPU when idle. The TV connection closes 90 s after you close the remote, and the UI is unloaded from memory.

## Requirements

- macOS 15 Sequoia or later (Apple Silicon or Intel)
- An Android TV / Google TV with the Android TV Remote Service on the same network. That covers every modern Google TV, Chromecast with Google TV, Sony, TCL, Philips and others.

## Installation

1. Download `MacMote.zip` from [Releases](../../releases), unzip it and move `MacMote.app` to Applications.
2. The app is ad-hoc signed (no Apple Developer ID). On first launch, **right-click → Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacMote.app
   ```
3. Allow **Local Network** access when macOS asks.
4. Click the remote icon. A 6-character code appears on the TV: enter it and you're done. MacMote connects automatically from then on.

## Building from source

You only need the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh        # build/MacMote.app
./build.sh zip    # + build/MacMote.zip for a release
```

To regenerate the icon, run `swift scripts/make-icon.swift`.

## How it works

MacMote speaks the same protocol as the official Google TV phone app (**Android TV Remote v2**):

- **Discovery:** it finds the TV via Bonjour (`_androidtvremote2._tcp`).
- **Pairing:** TLS on port `6467`. MacMote generates a client certificate once (stored in `~/Library/Application Support/MacMote`). The code shown on the TV confirms a SHA-256 hash of both sides' public keys.
- **Control:** TLS on port `6466`, using protobuf messages with Android key codes. Text goes through IME batch edits.

| File | Contents |
|---|---|
| `Sources/main.swift` | menu bar item, panel, keyboard shortcuts |
| `Sources/RemoteView.swift` | remote UI (SwiftUI) |
| `Sources/TVClient.swift` | discovery, pairing, remote protocol, Wake-on-LAN |
| `Sources/Identity.swift` | client certificate and RSA keys |
| `Sources/Proto.swift` | minimal protobuf codec |

## Resetting the pairing

Right-click the icon → **Pair with TV again**.
