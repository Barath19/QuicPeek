# QuicPeek

> Your brand's AI-search visibility, one click away in the macOS menu bar.

QuicPeek is a SwiftUI menu-bar app that turns the Peec AI dashboard into three
live Apple Health-style rings — **Visibility**, **Share of Voice**, and
**Sentiment** — with chat over the Model Context Protocol and scheduled briefs
delivered as native macOS notifications.

Submission to the **Peec AI MCP Hackathon**.

🌐 [quicpeek.com](https://quicpeek.com)

---

## What it does

- **Live rings** — Visibility / Share of Voice / Sentiment for the selected
  Peec project, with week-over-week deltas (current 7-day window vs. prior).
- **Top action banner** — the highest-scored recommendation surfaced as a
  tappable pill that drops the rationale into chat.
- **Chat** — ask "what should we do this week?" and have the answer drafted
  in seconds. Choose Apple's on-device FoundationModels (private, free) or
  Claude (Opus 4.7 / Sonnet 4.6 / Haiku 4.5).
- **Routines** — scheduled daily/weekly jobs (Morning Brief, Postmortem,
  Top Movers, custom prompt) that arrive as Notification Center banners.

## How it uses Peec MCP

| Peec tool | Where it's used |
|---|---|
| `list_projects` | Project switcher in the popover, project picker in widget config |
| `get_brand_report` | Powers the rings; called twice per refresh (current + prior 7-day window) so we can compute deltas |
| `get_actions` | Top-action banner + the source for any "what should we do" question |

Two MCP integration paths:

1. **Anthropic native connector** (`AnthropicProvider.swift`). Sends a
   `mcp_servers` block on every Messages API request so Claude discovers Peec
   tools directly — **no hand-wired schemas, no client-side tool plumbing**.
   Authenticated via the user's Peec OAuth bearer.
2. **Apple FoundationModels** (`PeecTools.swift`). Three thin
   `@Generable Tool` wrappers around the same MCP calls so Apple Intelligence
   models can use them, gated by a per-tool `.allow / .ask / .block` policy
   (`ToolPolicy.swift`).

`PeecMCP.swift` is the typed MCP client (handles initialization, JSON-RPC
plumbing, SSE, OAuth refresh) used by both paths and the routine scheduler.

## Architecture

```
PopoverView ──── ChatStore ──── LLMProvider ─┬── AppleProvider (FoundationModels + tools)
     │                                       └── AnthropicProvider (native MCP connector)
     │
     ├── PeecMCP (typed brand report / actions / projects)
     │       └── PeecOAuth (PKCE + Keychain)
     │
     └── RoutineScheduler ── pre-fetch brand+actions → headless LLM → notification
                          ── Timer (60s) + NSBackgroundActivityScheduler (hourly)
                          ── SwiftData: Routine, RoutineRun
```

### Security choices worth calling out

- **Routines never expose live tools to the LLM.** The scheduler pre-fetches
  Peec data and inlines it as context; the Anthropic path is built with no
  `mcp_servers` and the Apple path with no FoundationModels tools. Closes the
  headless prompt-injection surface where attacker-controlled Peec data could
  otherwise drive arbitrary tool calls or notification spoofing.
- **Notification bodies are sanitized** — URLs, control chars, and
  newlines stripped — and prefixed with a fixed `Brief · ` marker the model
  can't replace.
- **Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`** so
  app secrets don't sync via iCloud Keychain.
- **OAuth/Anthropic error envelopes are distilled** to known fields so a
  misbehaving server can't leak echoed tokens via `errorDescription`, OSLog,
  or persisted run rows.

## Build

Requires Xcode 16+ and macOS 14+ (Sonoma).

```sh
git clone https://github.com/Barath19/QuicPeek.git
cd QuicPeek
open QuicPeek.xcodeproj
```

Hit ⌘R. The first launch prompts to connect Peec via OAuth.

To use Claude as the chat backend, add an Anthropic API key in
**Settings → General**.

## Branches

- `main` — current shipping menu-bar app.
- `widget` — work-in-progress desktop widget extension. Renders the same rings
  on the desktop via an App Group container; needs the widget target's
  Code-Signing Entitlements wired through the Xcode UI before App Groups will
  cross between processes.

## License

TBD.
