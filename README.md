# LLM Messaging System — Real-Time Local LLM Reply Generation

A macOS messaging system that monitors iMessage events (chat.db), generates mood-conditioned reply candidates using a local LLM (Ollama), and enables human-in-the-loop reply selection through AppleScript automation.

## System Overview

```text
iMessage (chat.db)
       ↓
Event Listener (Python daemon)
       ↓
Local LLM (Ollama)
       ↓
Response Generation (structured JSON)
       ↓
User Selection (SwiftUI)
       ↓
AppleScript Automation → Messages.app
```

## Key Challenges

- Real-time processing of incoming messages without blocking UI
- Ensuring consistent LLM output via structured JSON responses with retry logic
- Handling variability in local model latency and output quality
- Safely integrating automation with macOS messaging workflows

## Design Decisions

- **Local LLM (Ollama)** over cloud API: privacy and no API cost; tradeoff: hardware requirements
- **File-based IPC** over sockets: zero-dependency cross-language communication; tradeoff: no locking, potential races
- **Structured outputs (JSON)** enforced with retry loop for predictable response parsing
- **Human-in-the-loop selection** to ensure correctness before send
- **`sqlite3` CLI** over Python `sqlite3` module: fewer lock issues with Messages holding `chat.db`

## Tradeoffs

- Local models → better privacy but lower model quality vs cloud APIs
- Structured outputs → reliability but reduced generation flexibility
- Automation → convenience but requires careful system integration
- File-based IPC → simplicity but no concurrency guarantees

## Architecture

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
                     └──────────────────┘     └──────────────────┘
```

## Quick Start

```bash
brew install ollama
ollama pull llama3.1:8b
pip install ollama

git clone git@github.com:cadenroberts/llm-messaging-system.git
cd llm-messaging-system
open iMessageAI.xcodeproj
# Product > Run (Cmd+R)
```

Requires macOS 13+, Xcode 15+, Full Disk Access granted to Terminal, and Messages signed in.

## Performance

| Metric | Target | Measured |
|---|---|---|
| Reply generation | < 15s per cycle | ~6.5s (Apple Silicon, Llama 3.1 8B) |
| Config parse | < 10ms | Negligible |
| UI poll | 1s | 1s fixed |
| Retry worst case | 5 × ~6.5s | Rare; usually 0–1 retries |
