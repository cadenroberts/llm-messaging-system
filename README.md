# iMessageAI

A real-time LLM messaging system on macOS that ingests iMessage events (chat.db), generates structured mood-conditioned responses via a local Ollama model, and enables human-in-the-loop reply selection through AppleScript automation.

## System Overview

The system operates as a real-time, event-driven pipeline:

- **Ingestion** — monitors iMessage events via the chat.db SQLite store
- **Generation** — produces structured, mood-conditioned outputs via local LLM inference
- **Validation** — enforces JSON schema compliance with retry logic
- **Control** — enables human-in-the-loop response selection
- **Execution** — dispatches messages through AppleScript automation

The design emphasizes robustness under imperfect model outputs, explicit system boundaries, and safe deployment of LLM-generated content.

## Key Properties

- Real-time event-driven pipeline (`chat.db` ingestion)
- Local LLM inference (Ollama, no external API)
- Structured output enforcement (JSON schema + retry loop)
- Human-in-the-loop control for safe execution
- Cross-language system (Swift + Python + AppleScript)

## Why This Matters

LLM systems are often treated as black-box components. This system explores how to integrate local LLM inference into real-time pipelines with explicit constraints, validation layers, and human control, highlighting the challenges of deploying generative models in interactive systems.

## Demo

### Prerequisites

- macOS 13+ (Ventura or later)
- Xcode 15+ installed
- Ollama installed and running (`brew install ollama && ollama serve`)
- Llama 3.1 8B model pulled (`ollama pull llama3.1:8b`)
- Python 3.9+ with `ollama` package (`pip install ollama`)
- Full Disk Access granted to Terminal (System Settings > Privacy & Security > Full Disk Access)
- Messages client signed into an iMessage account

### Quick start

```bash
# Install dependencies
brew install ollama
ollama pull llama3.1:8b
pip install ollama

# Clone and prepare runtime directory
git clone git@github.com:cadenroberts/iMessageAI.git
cd iMessageAI
mkdir -p ~/iMessageAI
cp model.py config.json send_imessage.osa ~/iMessageAI/

# Build and run
open iMessageAI.xcodeproj
# In Xcode: Product > Run (Cmd+R)
```

### Running

**Option A — pre-built bundle:** from the repo root, run `./scripts/open-product-bundle.sh` (opens the shipped macOS GUI bundle next to the Xcode project when it exists).

**Option B — build from source:** open the Xcode project and run (Cmd+R).

The SwiftUI host starts `model.py` automatically. Configure your name, personality description, and moods in the UI. Incoming iMessages trigger reply generation.

### Expected behavior

1. **Host window opens** — configuration panel with Name, Personal Description, Moods, and Phone Numbers
2. **Model starts** — console shows `[INIT] Config loaded.` and `[INIT] Texts found.`
3. **Waiting state** — periodically prints `[WAITING] Fetching text with content ...`
4. **Message arrives** — `[RUN] New text from +1XXXXXXXXXX found.` and `[GENERATING] ...`
5. **Replies generated** (~6.5s) — `[FINISH] Done generating in ...` and `[WRITING] Writing to replies.json.`
6. **UI updates** — reply cards appear, one per mood
7. **User action** — select a card, then **Reply**, **Refresh**, or **Ignore**
8. **Send confirmation** — `[FINISH] Sending text.`

### Smoke test (no iMessage required)

```bash
cd ~/iMessageAI
python3 -c "
import json
with open('config.json') as f:
    c = json.load(f)
print(f'Name: {c[\"name\"]}')
print(f'Moods: {list(c[\"moods\"].keys())}')
print(f'Filter: {c[\"phoneListMode\"]}')
print('SMOKE_OK')
"
```

### Troubleshooting

| Problem | Fix |
|---|---|
| `model.py` crashes on startup | Verify Ollama: `curl http://localhost:11434/api/tags` |
| No messages detected | Grant Full Disk Access to Terminal/Xcode |
| Empty reply cards | `ollama pull llama3.1:8b` |
| AppleScript send fails | Open Messages and sign into iMessage |
| Python not found | `brew install python` or ensure conda on PATH |
| Build fails in Xcode | Check macOS deployment target |

A full end-to-end demo needs another person to send an iMessage while the system runs. The smoke test checks config parsing without an incoming message.

## Architecture

### Component diagram

```
┌──────────────┐     ┌──────────────────┐     ┌───────────────┐
│  chat.db     │────▶│   model.py       │────▶│  replies.json │
│  (SQLite)    │     │  (Python daemon)  │     │  (IPC buffer) │
│  iMessage DB │     │  - DB polling     │     └───────┬───────┘
└──────────────┘     │  - System prompt  │             │
                     │  - LLM inference  │             ▼
                     │  - JSON parsing   │     ┌───────────────┐
                     └──────────────────┘     │  SwiftUI host │
                                              │  - Reply list  │
                     ┌──────────────────┐     │  - Config UI   │
                     │  config.json     │     └───────┬───────┘
                     │  - Name          │             │
                     │  - Personality   │             ▼
                     │  - Mood system   │     ┌──────────────────┐
                     │  - Phone filter  │     │ AppleScript send │
                     └──────────────────┘     │ send_imessage.osa │
                                              └──────────────────┘
```

### Staged execution

1. SwiftUI host launches and starts `model.py` as a child process
2. `model.py` polls `chat.db` via `sqlite3` CLI for the most recent message
3. When a new message arrives from an allowed phone number, `model.py` reads `config.json` and constructs a personality prompt with all mood definitions
4. Ollama generates a JSON response with one reply per mood (retries up to 5 times on key mismatch)
5. `model.py` writes the reply map to `replies.json`
6. SwiftUI host polls `replies.json` every second and displays candidates
7. User selects, edits, refreshes, or ignores. Selection writes back to `replies.json`
8. `model.py` reads the selection and invokes `send_imessage.osa` via `osascript`

### Execution flow

**Startup:** `iMessageAIApp.swift` hosts `ContentView`. On appear: `loadConfigIfExists()`, `startRepliesPolling()` (1s timer on `~/iMessageAI/replies.json`), `startModelIfNeeded()` (launches `model.py` with stdout/stderr pipes).

**Message detection:** `model.py` loops; each iteration runs `sqlite3` for the latest message text and sender, checks the phone filter, and on new text proceeds to generation.

**Reply generation:** Reads `config.json`, builds the system prompt, calls `ollama.chat(model="llama3.1:8b", format="json", ...)`, validates mood keys, retries up to 5 times, writes `replies.json` with mood keys plus `Reply`, `sender`, `message`, `time`.

**User interaction:** Timer-driven reads of `replies.json`; user can select, edit, **Reply**, **Refresh** (`Reply` = `"Refresh"`), or **Ignore** (`Reply` = `"Ignore"`).

**Send:** When `Reply` is set to a mood name, `model.py` runs `osascript send_imessage.osa` with the number and text.

### Contracts

- **model.py ↔ config.json:** reads `name`, `personalDescription`, `moods`, `phoneListMode`, `phoneNumbers` (no schema validation; missing keys can raise `KeyError`).
- **model.py ↔ replies.json (write):** flat JSON; special keys `Reply`, `sender`, `message`, `time`.
- **SwiftUI ↔ replies.json:** reads mood keys by excluding metadata keys; writes `Reply` and `reply` (back-compat); atomic write via temp file + `replaceItemAt`.
- **SwiftUI ↔ model.py:** `Process` with working directory `~/iMessageAI/`, auto-restart after 1s on unexpected exit if enabled.

### Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| Ollama not running | Connection error in `model.py` | Start Ollama |
| `chat.db` inaccessible | Empty query; tight poll | Grant Full Disk Access |
| `model.py` missing | No replies | Ensure `~/iMessageAI/model.py` |
| Python missing | Process launch fails | Install Python |
| Malformed LLM JSON | Retries then empty strings | User sees empty cards |
| `replies.json` race | Possible corrupt read | Restart the host |
| Messages not running | AppleScript fails | Open Messages |
| Quotes in message text | Shell/`os.system` breakage | See improvement list |

### Data flow (audit)

```
chat.db (SQLite, ~/Library/Messages/chat.db)
    │
    ▼ [sqlite3 CLI subprocess, polled in tight loop]
model.py
    │
    ├── reads config.json (personality, moods, phone filter)
    ├── constructs system prompt with mood definitions
    ├── calls ollama.chat(model="llama3.1:8b", format="json")
    │     └── retries up to 5 times if mood keys mismatch
    ├── writes replies.json (mood→reply map + sender + message + time)
    └── polls replies.json for user selection (Reply key)
            │
            ├── "Refresh" → regenerate
            ├── "Ignore"  → skip
            └── <mood>    → osascript send_imessage.osa <number> "<text>"

SwiftUI ContentView
    │
    ├── onAppear: loadConfigIfExists(), startRepliesPolling(), startModelIfNeeded()
    ├── Timer(1s): polls ~/iMessageAI/replies.json
    ├── user taps Reply → writes selected mood to Reply key
    ├── user taps Refresh → writes "Refresh" to Reply key
    ├── user taps Ignore → writes "Ignore" to Reply key
    └── config edits → persistConfig() writes config.json + UserDefaults
```

## Design Decisions

### Summary tradeoffs

- **File-based IPC** over sockets: zero-dependency cross-language communication; tradeoff: no locking, potential races.
- **Local LLM** over cloud API: privacy and no API cost; tradeoff: Ollama + hardware.
- **Personality/moods in JSON** over hardcoded prompts: tunable without code; tradeoff: no schema validation.
- **AppleScript for send** over direct API: supported path to the Messages client; tradeoff: fragile quoting, weak errors.
- **`sqlite3` CLI** over Python `sqlite3`: fewer lock issues with Messages holding `chat.db`; tradeoff: subprocess overhead.

### ADR-001: File-based IPC over sockets

Python and Swift exchange data via shared JSON (`replies.json`). Consequences: no extra deps or socket lifecycle; races possible (Swift pauses polling ~0.3s on writes; Python has no lock).

### ADR-002: Local LLM over cloud API

Ollama + Llama 3.1 8B locally. Privacy; no API keys; ~8 GB RAM; inference ~6.5s on test hardware; output not bit-reproducible without temperature pinning.

### ADR-003: Personality and moods in config file

`config.json` edited in UI; `model.py` reads each generation. Dynamic mood count (UI limits 1–5); no JSON schema validation; Swift also uses `UserDefaults`.

### ADR-004: AppleScript for sending

`send_imessage.osa` via `osascript`. Official path for iMessage automation; `os.system` string interpolation is fragile; errors often silent.

### ADR-005: sqlite3 CLI over Python sqlite3 module

Subprocess to `sqlite3` avoids many lock/stale-read issues with WAL + Messages holding the DB; queries are fixed strings (no user SQL).

### ADR-006: SwiftUI process management for Python

`ContentView` starts `model.py` on appear, stops on disappear, auto-restarts after 1s. Python path is resolved heuristically (miniconda, system, homebrew).

### ADR-007: Retry logic for LLM JSON validation

Output keys must match mood keys exactly; up to 5 retries; worst case ~30s; on failure, empty strings per mood.

### ADR-008: Phone number Include/Exclude

Exact string match; no normalization; empty list + Exclude processes all; empty + Include processes none.

## Evaluation

### Correctness definition

The system is correct when:

1. `model.py` reads `config.json` and builds a system prompt containing all mood definitions
2. Ollama returns JSON whose keys exactly match mood keys in `config.json`
3. `replies.json` has the full mood map plus `sender`, `message`, `time`, and `Reply`
4. SwiftUI shows one card per mood with generated text
5. User selection writes the chosen mood name to `Reply`
6. `model.py` invokes `send_imessage.osa` with the correct number and text

### Verification commands

**Config parsing:**

```bash
cd ~/iMessageAI
python3 -c "
import json
with open('config.json') as f:
    c = json.load(f)
assert 'name' in c, 'missing name'
assert 'personalDescription' in c, 'missing personalDescription'
assert 'moods' in c and isinstance(c['moods'], dict), 'missing or invalid moods'
assert len(c['moods']) >= 1, 'need at least 1 mood'
assert 'phoneListMode' in c and c['phoneListMode'] in ('Include', 'Exclude'), 'invalid phoneListMode'
assert 'phoneNumbers' in c and isinstance(c['phoneNumbers'], list), 'invalid phoneNumbers'
print('CONFIG_OK')
"
```

**LLM reply structure (requires Ollama):**

```bash
cd ~/iMessageAI
python3 -c "
import json, ollama
with open('config.json') as f:
    c = json.load(f)
moods = c['moods']
prompt = 'You must return JSON with keys: ' + ', '.join(moods.keys())
out = ollama.chat(model='llama3.1:8b', format='json', messages=[
    {'role': 'system', 'content': prompt},
    {'role': 'user', 'content': 'Hello'}
])['message']['content']
parsed = json.loads(out)
assert sorted(parsed.keys()) == sorted(moods.keys()), f'key mismatch: {sorted(parsed.keys())} vs {sorted(moods.keys())}'
print('LLM_REPLY_OK')
"
```

**Replies JSON structure:**

```bash
cd ~/iMessageAI
python3 -c "
import json
with open('replies.json') as f:
    r = json.load(f)
assert 'Reply' in r, 'missing Reply key'
assert 'sender' in r, 'missing sender key'
assert 'message' in r, 'missing message key'
assert 'time' in r, 'missing time key'
with open('config.json') as f:
    c = json.load(f)
for mood in c['moods']:
    assert mood in r, f'missing mood key: {mood}'
print('REPLIES_OK')
"
```

**Swift build:**

```bash
cd iMessageAI
xcodebuild -project iMessageAI.xcodeproj -scheme iMessageAI -configuration Debug build 2>&1 | tail -5
```

Pass when each script prints its `*_OK` token and the build reports `BUILD SUCCEEDED`. Full E2E needs macOS, Full Disk Access, signed-in Messages, Ollama with `llama3.1:8b`, and a real message—not suitable for typical CI.

### Performance expectations

| Metric | Target | Measured |
|---|---|---|
| Reply generation | < 15s per cycle | ~6.5s per generation cycle (Apple Silicon, Llama 3.1 8B, local inference) |
| Config parse | < 10ms | Negligible |
| UI poll | 1s | 1s fixed |
| Retry worst case | 5 × ~6.5s | Rare; usually 0–1 retries |

## Repository Audit

### Purpose

Event-driven iMessage reply system: watches local `chat.db`, generates mood-labeled replies with a local LLM, presents them in SwiftUI, sends the choice via AppleScript.

### Entry points

| Entry Point | Language | Role |
|---|---|---|
| `iMessageAI/iMessageAIApp.swift` | Swift | `@main`; `WindowGroup` → `ContentView` |
| `iMessageAI/ContentView.swift` | Swift | UI + process orchestration, config, `replies.json` polling, AppleScript send |
| `model.py` | Python | Daemon: DB poll, prompts, Ollama, `replies.json` |
| `send_imessage.osa` | AppleScript | Send via Messages (`osascript` from Python) |

### Dependencies

**Runtime:** Ollama + `llama3.1:8b`, `ollama` Python package, `sqlite3` CLI, Messages (macOS client), SwiftUI/AppKit, UserNotifications.

**Dev:** Xcode, Python 3.x.

### Configuration

| Source | Role |
|---|---|
| `config.json` / `~/iMessageAI/config.json` | Name, description, moods, phone filter |
| `~/iMessageAI/replies.json` | IPC buffer between Python and Swift |
| `.env.example` | Template; no required env vars beyond PATH |

Swift resolves paths under `/Users/<user>/iMessageAI/` (hardcoded base). Python cwd is set to that directory by the launcher.

### Determinism risks

| Risk | Severity | Detail |
|---|---|---|
| LLM nondeterminism | High | Default temperature |
| Tight DB poll loop | Medium | `while True` without sleep; high CPU |
| `replies.json` races | Medium | No file locking |
| Phone formats | Low | No normalization |
| `osascript` / shell quoting | Medium | Quotes in body break send |

### Observability

- Python: bracketed logs `[INIT]`, `[WAITING]`, `[RUN]`, `[GENERATING]`, `[FINISH]`, `[WRITING]`
- Swift: pipes Python stdout/stderr to console; `#if DEBUG` on some file errors
- No structured logging, metrics, or crash reporting

### Test state

No unit, integration, UI, or Python tests; no Xcode test targets.

### Reproducibility

Python deps not pinned (no `requirements.txt`); Ollama model tag only, not weight hash; LLM output stochastic.

### Security surface

| Surface | Risk | Detail |
|---|---|---|
| `chat.db` | High | Full history; needs Full Disk Access |
| Shell invocation | Medium | `os.system`-style quoting for AppleScript |
| Local LLM | Low | Data stays on device |
| Auth | N/A | Physical machine scope |
| `config.json` | Low | Plaintext PII/numbers |

### Improvement list

**P0:** Fix shell injection for AppleScript (`subprocess` with argv); add `requirements.txt` with pinned `ollama`; add sleep/backoff in DB poll loop.

**P1:** File locking or atomic protocol for `replies.json`; optional `--temperature`; phone normalization; clean tracked junk (e.g. `.DS_Store`, user state files if any).

**P2:** Unit tests for `gen_replies`; Swift previews/snapshots; structured logging in Python; pin model digest if needed.

## Repository Layout

```
iMessageAI/
├── model.py                          Python daemon: DB polling + LLM + IPC
├── send_imessage.osa         AppleScript: send via Messages
├── config.json                       Personality and mood template
├── iMessageAI/
│   ├── iMessageAIApp.swift           SwiftUI @main
│   ├── ContentView.swift             UI + process orchestration
│   └── Assets.xcassets/
├── iMessageAI.xcodeproj/
├── scripts/
│   ├── demo.sh
│   └── open-product-bundle.sh        Opens pre-built GUI bundle (see Option A in Demo)
└── .github/workflows/ci.yml
```

## Limitations

- Requires macOS with Full Disk Access for `chat.db` reads
- Requires Ollama locally with enough RAM for Llama 3.1 8B (~8 GB)
- No file locking on `replies.json` — races possible
- AppleScript send uses fragile string interpolation — quotes in messages can fail
- `model.py` poll loop can use high CPU when idle if no sleep is configured
- No phone number normalization — must match `chat.db` format exactly
- No automated test suite in-repo
