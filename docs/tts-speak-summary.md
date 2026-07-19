# Baton `speak_summary` — TTS Deployment & Integration Runbook

> The as-built record for Baton's spoken task-summary feature: an agent finishes a task,
> calls the `speak_summary` MCP tool, and Baton synthesizes the summary through a self-hosted
> TTS service and plays it (immediately, via an in-app banner, or via a macOS notification with
> a Play button), in a voice chosen per task category.
>
> Companion to the portable landscape survey in **`research-tts-voice-cloning.md`** (model/
> provider comparison, licensing, hardware sizing). This doc is the concrete *what we deployed
> and how to operate it*.
>
> **Built + validated end-to-end:** 2026-07-19. Branch `feature/tts-speak-summary`.

---

## 1. Architecture

```
Agent finishes a task
   └─►  MCP tool  speak_summary(text, category?, voice?, engine?, mode?)     [Baton's MCP server]
          │  1. resolve category → engine + voice   (SpeechConfig)
          │  2. POST /v1/audio/speech               (SpeechService → TTS host)
          │  3. deliver per mode:
          │        auto   → play now                (SpeechPlaybackEngine, AVAudioPlayer)
          │        banner → in-app banner + Play     (SpeechAlertOverlay)
          │        notify → macOS notification + Play (SpeechNotifier + delegate)
          ▼
   WAV audio plays on the Mac
```

Both TTS engines speak the **OpenAI `/v1/audio/speech`** API, so one client drives either and
either can be swapped for a cloud provider later.

**Local fallback:** if the self-hosted host is unreachable, Baton speaks the summary with the
**built-in macOS voice** (`AVSpeechSynthesizer`) instead of failing — on by default, toggle in
Settings → Speech. A summary is never silently dropped. Delivery still respects `mode`: `auto`
speaks natively immediately; `banner`/`notify` carry the raw text and speak it natively when you
press Play. The tool's result reports `"engine":"system (fallback)"` when this path is used.

---

## 2. Backend (self-hosted TTS)

Deployed on **ai-01 (`ai-01.local`)**, managed from `~/tts`. (web-01 was the first choice —
always-on web box — but its RTX 3090 Ti was 100% held by a vLLM engine; only disk was free.
ai-01 has idle Blackwell GPUs.)

| Service | Container | Port | Device | Image / build | Steady-state |
|---|---|---|---|---|---|
| **Kokoro** (54 preset voices, incl. Spanish; no cloning) | `tts-kokoro` | 8880 | **CPU** | `ghcr.io/remsky/kokoro-fastapi-cpu:latest` | ~0.17 s / short line |
| **Chatterbox** (voice cloning from 5–10 s; beats ElevenLabs in blind tests) | `chatterbox-tts-server-cu128` | 8004 | **GPU 2** (~5.4 GB) | built from `devnen/Chatterbox-TTS-Server`, `docker-compose-cu128.yml` | ~0.23 s / short line |

- Compose: `~/tts/docker-compose.yml` (Kokoro), `~/tts/Chatterbox-TTS-Server/docker-compose-cu128.yml` (Chatterbox).
- Both `restart: unless-stopped`; docker enabled at boot → **auto-return after a reboot**.
- Chatterbox default model = `chatterbox-turbo` (English). API **requires both `model` and
  `voice`** fields; voices are `*.wav` names from `GET /v1/audio/voices` (e.g. `Emily.wav`).
  Multilingual (Spanish) = switch the model in its `config.yaml`.
- GPU map on ai-01: GPU0 idle · GPU1 = vLLM-30B (~83 GB) · **GPU2 = Chatterbox** · GPU3 idle.

### Bring-up (reference)
```sh
# Kokoro (CPU)
mkdir -p ~/tts && cd ~/tts
# docker-compose.yml → image ghcr.io/remsky/kokoro-fastapi-cpu:latest, port 8880
docker compose up -d kokoro

# Chatterbox (GPU 2, Blackwell/CUDA 12.8)
git clone --depth 1 https://github.com/devnen/Chatterbox-TTS-Server.git
cd Chatterbox-TTS-Server
# edit docker-compose-cu128.yml: runtime: nvidia + NVIDIA_VISIBLE_DEVICES=2; drop HF_TOKEN placeholder
docker compose -f docker-compose-cu128.yml up -d --build
```

### Health / smoke test (on the host)
```sh
curl -s localhost:8880/health                       # Kokoro → 200
curl -s localhost:8004/v1/audio/voices | head -c 200 # Chatterbox voices
curl -s -X POST localhost:8004/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"chatterbox","voice":"Emily.wav","input":"hello","response_format":"wav"}' -o /tmp/t.wav
```

---

## 3. Backend learnings — Blackwell (RTX PRO 6000, sm_120) gotchas

1. **Blackwell needs CUDA 12.8+.** Chatterbox must use the `cu128` compose/Dockerfile. Kokoro's
   stock GPU image is **CUDA 12.6** → crashes with `no kernel image is available for execution on
   the device`. Fix: run Kokoro on the **CPU image** (fast enough — ~15× real-time on the 64-core
   host; the GPU buys nothing for a model this small).
2. **`CUDA unknown error` (999) in Docker after a driver reload.** Every *new* torch container
   fails `torch.cuda.is_available()` even though `nvidia-smi` works and `/dev/nvidia-uvm` is
   injected — a host-wide state issue, not per-container (whisperX showed it too; already-running
   vLLM predated the reload and was fine). **A full host reboot clears it** (a `nvidia_uvm` module
   reload can't run while vLLM holds the driver). Rebooting also recovered a flaky 4th GPU.
3. **GPU pinning:** use `runtime: nvidia` + `NVIDIA_VISIBLE_DEVICES=<idx>` — NOT that plus a
   `deploy.resources.reservations.devices` block (the double-restriction can itself trigger the
   999 error). Chatterbox `config.yaml` `device: auto` then self-selects `cuda`.

---

## 4. App integration (Baton, macOS/Swift)

### The MCP tool
`speak_summary` (registered in `BatonMCPToolCatalog`, marked open-world). Params:

| Param | Req | Meaning |
|---|---|---|
| `text` | ✅ | The summary to speak (a sentence or two). |
| `category` | | Task category → voice via the map (e.g. `ops`, `deploy`, `research`, `alert`, `es`). Falls back to `default`. |
| `voice` | | Explicit voice, overrides `category`. `"engine:voice"` (e.g. `kokoro:af_bella`, `chatterbox:Emily.wav`) or a bare id. |
| `engine` | | `kokoro` (default, fast presets) or `chatterbox` (premium / cloned). |
| `mode` | | `notify` (default — macOS notification + Play), `banner` (in-app banner + Play), `auto` (speak immediately). |

Example:
```json
{"name":"speak_summary","arguments":{
  "text":"Deploy finished — all checks green.",
  "category":"deploy",
  "mode":"notify"
}}
```

### New / changed files
```
app/Sources/Baton/Speech/SpeechConfig.swift          # hosts + category→voice map + fallback flag (UserDefaults)
app/Sources/Baton/Speech/SpeechService.swift         # OpenAI /v1/audio/speech POST → WAV Data; listVoices()
app/Sources/Baton/Speech/SpeechPlaybackEngine.swift  # AVAudioPlayer (server) + AVSpeechSynthesizer (fallback) + banner
app/Sources/Baton/Speech/SpeechNotifier.swift        # UserNotifications category + Play action + delegate
app/Sources/Baton/Shell/Music/BatonSpeechPane.swift  # Settings → Speech editor (hosts, voice map, preview, fallback)
app/Sources/Baton/MCP/BatonMCPSpeakTools.swift       # the tool: definition() + run()
app/Sources/Baton/Shell/Music/SpeechAlertOverlay.swift # interactive in-app banner (Play button)
# edits:
app/Sources/Baton/MCP/BatonMCPTools.swift            # register definition + dispatch case + openWorld set
app/Sources/Baton/Model/MusicModel.swift             # let speech = SpeechPlaybackEngine()  (music.speech)
app/Sources/Baton/Shell/Music/MusicView.swift        # .speechAlertBanner() next to .musicActionToast()
app/Sources/Baton/BatonApp.swift                     # install notification delegate + register category
app/project.yml                                      # ATS + Local Network keys (below)
```

Design mirrors existing patterns: `BatonMCPMixTools` (tool shape), `RadioPlaybackEngine` (one-off
player off `MusicModel`), `NavidromeConfig` (UserDefaults config), `MusicToastOverlay` (banner).

---

## 5. Configuration

Hosts + voice map live in the app's `UserDefaults` (suite `io.tonebox.baton`). **The real LAN
host IP is never committed** — source defaults to `http://127.0.0.1:8880/8004` placeholders (the
publish guard blocks `192.168.*`); set the real host at runtime:

```sh
defaults write io.tonebox.baton tonebox.speech.kokoroBaseURL     'http://ai-01.local:8880'
defaults write io.tonebox.baton tonebox.speech.chatterboxBaseURL 'http://ai-01.local:8004'
```

Default category → voice map (override by writing JSON to `tonebox.speech.voiceMap`):

| Category | Voice |
|---|---|
| `default` | `kokoro:af_heart` |
| `ops`, `deploy` | `kokoro:am_onyx` |
| `research` | `kokoro:af_bella` |
| `alert` | `kokoro:af_nova` |
| `premium` | `chatterbox:Emily.wav` |
| `es` (Spanish) | `kokoro:ef_dora` |

**In-app editor:** Settings → **Speech** (`BatonSpeechPane`) edits all of this without
`defaults write` — host fields for both engines (with a live ✓/voice-count badge), and an
editable category→voice table where each row's voice picker is populated from that server's
`GET /v1/audio/voices` (68 Kokoro / 28 Chatterbox voices) plus a ▶︎ **Preview** button that
synthesizes and plays the voice. The agent still picks per call; this screen configures the map.

---

## 6. macOS learnings (the tricky part)

1. **App Transport Security.** A `URLSession` POST to an `http://` host is blocked by default.
   The repo only had `NSAllowsArbitraryLoadsForMedia` (for AVFoundation radio streams). Added to
   `project.yml`:
   ```yaml
   NSAppTransportSecurity:
     NSAllowsArbitraryLoadsForMedia: true
     NSAllowsLocalNetworking: true          # cleartext to *.local + RFC-1918 LAN, not the internet
   NSLocalNetworkUsageDescription: "…"      # text for the Local Network privacy prompt
   ```
2. **Local Network privacy gate (the `-1009` red herring).** On modern macOS, an app must get
   user consent to talk to LAN devices. The **first** LAN call per launch fails with
   `NSURLErrorNotConnectedToInternet (-1009)` — *"The Internet connection appears to be offline"* —
   while the TCC prompt resolves, even though the host is reachable and ATS is fine. **Approve
   Baton in System Settings → Privacy & Security → Local Network**, then every call works.
   Diagnostic: `-1009` = Local Network privacy; `-1022`/`-1200` = ATS. `curl` from the Mac
   succeeding while the app fails is the tell.
3. **MCP auth.** The server requires a bearer token, generated on first run and stored in
   `~/Library/Application Support/Baton/mcp.json` (`{"token": …, "url": "http://127.0.0.1:8787/mcp"}`).
4. **Notifications need a signed bundle.** `notify` mode posts fine, but delivery is unreliable in
   unsigned local dev builds — `auto` and `banner` don't depend on signing.
5. **Build:** `./scripts/devrun.sh` runs `xcodegen generate` (auto-discovers new Swift files) then
   `xcodebuild`. A `project.yml` change (e.g. the ATS keys) requires the `xcodegen` step to land in
   the built `Info.plist`.
6. **Concurrency (Swift strict):** the `UNUserNotificationCenterDelegate` must be a plain
   (nonisolated) class — a `@MainActor` engine is implicitly `Sendable`, so hold it directly and
   hop via `await MainActor.run`; bind captured members to locals to avoid "sending `self`".

---

## 7. End-to-end test (validated)

App running (`open Baton.app`); token from `mcp.json`:

```sh
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/Baton/mcp.json'))['token'])")
call(){ curl -s -X POST http://127.0.0.1:8787/mcp -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" -d "$1"; }

# tools/list → confirm speak_summary present
call '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# auto (plays aloud); notify; banner
call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"speak_summary","arguments":{"text":"Deploy done.","category":"deploy","mode":"auto"}}}'
```

Verified: Kokoro auto (EN + Spanish `ef_dora`), Chatterbox premium (GPU), `notify`, `banner`,
category & explicit-voice resolution, and guardrails (missing `text`, bad `mode`). First post-launch
call returns `-1009` once (Local Network init), then consistent.

---

## 8. Operations & future work

- **Endpoints:** Kokoro `http://ai-01.local:8880`, Chatterbox `http://ai-01.local:8004` (both
  `/v1/audio/speech`, `/v1/audio/voices`). MCP `http://127.0.0.1:8787/mcp` (bearer token).
- **Restart:** `cd ~/tts && docker compose up -d`; `cd ~/tts/Chatterbox-TTS-Server && docker compose -f docker-compose-cu128.yml up -d`.
- **Future:** move Kokoro to web-01 (CPU, always-on) so presets survive when ai-01 is busy;
  a UI to upload Chatterbox cloning reference samples; cache text→audio by hash (low volume →
  not needed yet). *(In-app Settings → Speech editor for hosts + voice map is done.)*
- **Licensing:** Kokoro (Apache-2.0) + Chatterbox (MIT) are commercial-safe — matters because
  Baton is distributed. Do not bundle non-commercial weights (XTTS/F5/Fish). See the research doc.
```
