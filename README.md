# OpenCode Companion (Flutter)

An Android companion app for [OpenCode](https://opencode.ai) - run AI coding
sessions from your phone against a server you host yourself.

The phone is a **thin client**: it speaks the OpenCode HTTP + SSE API directly.
There is no proxy and no backend, so your code and your provider API keys never
leave the machine running `opencode serve`.

> Not affiliated with the OpenCode / Anomaly team. Community-built client.

---

## Features

- **Streaming chat** - token-by-token responses, reasoning blocks, and tool call
  cards rendered as they happen.
- **Approvals from your phone** - when the agent wants to run a command or edit a
  file, it stops and waits for you to approve or reject it.
- **Question prompts** - the server's "form" prompts render as tappable option
  chips or free-text fields.
- **Session list** - browse, create, rename, and delete sessions, with live
  busy/idle status from the event stream.
- **Diff viewer** - session diffs and the VCS working-tree diff, in a unified
  view sized for a 720x1600 phone.
- **File browser** - walk the project on the server and read files.
- **Model picker** - provider/model/variant selection per session.
- **QR pairing** - scan a code printed by the server instead of typing a URL.
- **Multi-connection** - LAN, Tailscale, Cloudflare Tunnel, or ngrok.
- **Credential storage** - passwords live in the Android Keystore, never in
  app preferences.

## Requirements

| | |
| --- | --- |
| Flutter | 3.35+ (Dart 3.9+) |
| Android | 6.0 (API 23) or newer |
| OpenCode | v2.x recommended; v1.x supported as a fallback |

## Running the server

```bash
# on the machine that hosts your project
npm install -g @opencode/cli

# password protects the server (HTTP basic auth)
export OPENCODE_SERVER_PASSWORD=a-long-random-password

# 0.0.0.0 is required - the default 127.0.0.1 is unreachable from your phone
opencode serve --hostname 0.0.0.0 --port 4096
```

### Reaching it from your phone

**Same Wi-Fi (quickest test)**

```bash
opencode serve --hostname 0.0.0.0 --port 4096
# then in the app: http://192.168.1.23:4096
```

**Tailscale (works anywhere, recommended)**

1. Install Tailscale on both machines and log in.
2. Start the server as above.
3. In the app, use the Tailscale IP: `http://100.64.0.1:4096`

**Cloudflare Tunnel / ngrok**

```bash
cloudflared tunnel --url http://127.0.0.1:4096
# then in the app: https://<random>.trycloudflare.com
```

The app sends `Bypass-Tunnel-Reminder` and `ngrok-skip-browser-warning` headers
so those tunnels do not show an interstitial page.

## Pairing with a QR code

OpenCode has built-in device pairing, and the app speaks it directly.

**Easiest: use the OpenCode desktop app's Pairing page** (Settings → Pairing →
Pair device). It shows a QR code and a five-minute countdown. In the app:
**Add server → Scan QR**.

The scanner has three ways to read the code, because a pairing payload is dense
(a 100-character JSON payload at error-correction level M is roughly 50x50
modules) and phone cameras struggle with dense codes at a distance:

- **Live camera** with tap-to-focus, a zoom slider, and a torch toggle
- **Pick image** — screenshot the code on the server machine and pick it from
  the gallery; this avoids focus and distance entirely
- **Manual entry** — type the address and password, no QR at all

The scanner understands everything OpenCode produces:

| Payload | Source |
| --- | --- |
| `{"code":"...","urls":["http://..."]}` | desktop app pairing QR |
| `http://host:port/auth/connect/<code>` | `opencode pair` printed link |
| `{"v":1,"url":...,"username":...,"password":...}` | `tool/qr_serve --mode password` |
| `http://host:port` | bare address, password entered by hand |

**Headless server?** Either run `opencode pair` on it, or generate an equivalent
code yourself:

```bash
cd tool/qr_serve
dart pub get
dart run bin/qr_serve.dart --url http://100.64.0.1:4096 --password "$OPENCODE_SERVER_PASSWORD"
```

That calls `POST /api/pair` and prints the same payload the desktop app would.

### How the token works

```
POST /api/pair                 -> { code, expires_in: 300 }        (basic auth)
GET  /auth/connect/<code>      -> { token }                        (no auth)
Authorization: Basic opencode:<token>                               (every call)
```

The pairing token is accepted exactly where `OPENCODE_SERVER_PASSWORD` is
accepted, so the app needs no special case for it - and the token never appears
in a QR code.

## Building

```bash
flutter pub get
flutter analyze
flutter test

flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```

The release build is currently signed with the debug key. To sign properly:

```bash
keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
# then fill in android/key.properties and point build.gradle.kts at it
```

## How it works

```
┌──────────────────────────┐
│  OpenCode Companion      │
│  (Flutter, this repo)    │
└───────────┬──────────────┘
            │  HTTP + SSE (LAN / Tailscale / tunnel)
            ▼
┌──────────────────────────┐
│  opencode serve          │
│  on your laptop / VPS    │
└───────────┬──────────────┘
            │  provider API calls
            ▼
┌──────────────────────────┐
│  Your AI provider        │
│  Your keys, your bill    │
└──────────────────────────┘
```

### Two server API generations

OpenCode changed its HTTP API in v2. The app probes which one a server speaks
and picks the right client:

| | v1 (<= 1.18.x) | v2 (2.x, current) |
| --- | --- | --- |
| Health | `GET /global/health` | `GET /api/info` |
| Sessions | `GET /session` | `GET /api/session` |
| Events | `GET /event` | `GET /api/event` |
| Prompt | `POST /session/:id/prompt_async` | `POST /api/session/:id/prompt` |
| Directory scope | `x-opencode-directory` header | `location[directory]` query |

The probe uses **content type**, never status code: an unknown route on either
server answers `200 text/html` from the web app, so a v1 server can pass a v2
health check and then fail on every later call.

## Project layout

```
lib/
  core/
    api/          HTTP transport, SSE parser + stream, v1/v2 clients, API probe
    chat/         message merge rules
    connections/  saved connections, keystore-backed credentials
    events/       raw SSE event -> typed event translation
  features/
    onboarding/   connection list, add/edit, QR scan
    sessions/     session list
    chat/         chat screen, message bubble, tool card, approval prompts
    diff/         diff computation + unified viewer
    files/        server-side file browser
    settings/     model picker
  shared/         theme
tool/qr_serve/    server-side QR generator
test/             unit tests (SSE framing, API probe, event translation, merges)
```

## Testing

```bash
flutter test
```

The tests cover the parts that are easy to get wrong without a device:

- SSE framing, including frames split across network reads
- v1/v2 server detection from response envelopes
- the full v2 event taxonomy, using payloads captured from a live v2.2.6 server
- optimistic message resolution (the "second message vanishes" bug)
- the v2 client against canned responses captured from a live server
- the whole connect -> save -> session list -> chat flow, end to end

## Verified on real hardware

Tested on a Samsung Galaxy A06 (SM-A065F, Android 16 / API 36, arm64-v8a,
720x1600) against OpenCode v2.2.6 running on a Windows desktop over Wi-Fi:

- connection probe detects `v2 API 2.2.6`
- session list, chat history, and a live prompt/response round trip
- reasoning blocks, tool-call cards, and streaming text

## Notes and limitations

- **Background notifications are not implemented.** While the app is open you
  see everything live; a true "the agent finished" push needs either a persistent
  foreground service or FCM, which needs a server-side component.
- **Cleartext HTTP is allowed** because LAN and Tailscale addresses are usually
  plain `http://`. Tunnel URLs are HTTPS and unaffected.
- The SSE stream has a 45-second idle watchdog. Android can leave a socket
  half-open after the app is backgrounded; without the watchdog the UI would show
  "connected" with a frozen stream.

## Credits

- [OpenCode](https://github.com/anomalyco/opencode) - the agent this app drives
- [opencode-mobile](https://github.com/dzianisv/opencode-mobile) - the React
  Native client whose API mapping and edge-case handling this project ported
  (MIT). Copyright (c) 2026 VIBE TECHNOLOGIES, LLC.