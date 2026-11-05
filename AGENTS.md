# MediaPilot — Agent Operating Guide

MediaPilot is a MoonBit-native realtime audio/video gateway. The current focus
is realtime audio; video is a P4 target.

It is a clean-room reimplementation inspired by `qwen-audio-agent`
(`D:\File\Reference\project\qwen-audio-agent`, Apache-2.0). The reference
project is a design source, never a dependency.

This file is the project's operating contract for humans and agents. Read it
before changing code. Load a skill only when the task matches one of the
triggers in [Skills](#skills).

## Current phase

**P0 — protocol and provider spike.** The goal is a working DashScope Realtime
audio round trip behind a small MoonBit abstraction, plus a browser audio
client.

Not in scope until P2: desktop shell, mobile, native AEC/NS/AGC, multi-tenant
auth, plugin marketplace. Not in scope until P4: video capture, encoding,
transport, and rendering. Do not add these speculatively.

## Architecture boundaries

| Package | Owns | May depend on |
| --- | --- | --- |
| `protocol/` | Wire types, JSON codec, version and capability constants | core only |
| `gateway/` | HTTP/WS server, session lifecycle, event routing | `protocol/` |
| `realtime/` | Provider adapters (DashScope, OpenAI, Gemini, …) | `protocol/` |
| `backend/` | Agent backends behind `BackendPort` (LLM, ACP, MCP) | `protocol/` |
| `audio/` | Capture, playback, resampling | core only |
| `cmd/` | Executables and wiring | anything above |

Dependencies point downward. `protocol/` must not import a transport, a
provider, or a backend. `cmd/` contains wiring only; no business logic.

Audio and video share one session and event model. There is no `video/` package
until P4; do not add one or pull in a codec dependency early.

### Invariants

1. **The wire is provider-neutral.** Provider JSON stops at the adapter. Only
   normalized events cross into `gateway/` and out to clients.
2. **One session owns one upstream connection.** No sharing provider sockets
   between clients. Reconnect creates a new upstream session.
3. **Capabilities are negotiated, not assumed.** Clients branch on capability
   IDs, never on product version strings.
4. **Media formats are explicit.** Audio events name sample rate, channels,
   encoding, and chunk duration; video events will name codec, resolution, and
   frame rate. Never infer them.
5. **Secrets never reach logs, fixtures, or the wire.** Redact
   `Authorization`, API keys, and full audio payloads.
6. **Every public promise has a test.** A behavior that cannot be tested is
   either not contract or not done.

## Build and verify

Run from the repository root.

```sh
moon check --target native     # type check the primary target
moon test --target native      # unit and contract tests
moon fmt                       # format
moon info                      # refresh .mbti interfaces
moon run cmd/main              # run the gateway
```

Use `--target wasm` only for packages that are intentionally portable
(`protocol/`, browser-side code). Audio and sockets are native-first.

### Definition of done

A change is done only when all of these hold:

- `moon check --target native` and `moon test --target native` pass.
- `moon info && moon fmt` leaves no unexpected diff; review `.mbti` changes.
- New behavior has a test, or `docs/contract.md` marks the promise `pending`
  with a follow-up issue.
- Public protocol changes update `docs/contract.md` and bump the version.
- No new dependency without a pinned version and a one-line reason in the PR
  or an ADR under `docs/decisions/`.
- No secrets, tokens, or real user audio in the diff.

## Documentation rules

- `docs/contract.md` is the single index of northbound promises. Everything
  else is implementation detail.
- Every promise names its locking test in a `Locked by` column. `pending` is
  allowed only during P0 and must name the phase that will lock it.
- Docs describe current behavior. Intentions belong in `docs/roadmap.md`.
- One page answers one question. Prefer editing an existing page over adding a
  new one.
- Chinese is the primary language while the project has no external users.
  Add an English mirror only when a real audience needs it; do not maintain
  bilingual parity for its own sake.
- Do not add a docs site (VitePress, etc.) until `docs/` exceeds roughly 20
  pages or versioned/i18n publishing becomes a real requirement. Markdown plus
  contract tests is enough before that.

## Protocol change rules

1. Read `docs/contract.md` and decide: additive or breaking.
2. Additive change → bump minor, add a capability ID, keep old clients working.
3. Breaking change → bump major and state the migration in the contract.
4. Update the MoonBit types, the client SDK/types, and the contract in the same
   change. They must never drift.
5. Add a round-trip or golden-schema test and fill in `Locked by`.
6. Unknown event types must be ignored, not fatal. Unknown capabilities must
   degrade, not crash.

## Skills

Project skills live in `.agents/skills/<id>/SKILL.md`. Load one with the
`skill` tool by ID. Do not load all of them. `SKILL.md` is English;
`SKILL_ZH.md` is an optional strict Chinese translation kept in sync.

| Skill | Load when |
| --- | --- |
| `gateway-protocol` | Adding or changing a WS event, capability, error code, or handshake |
| `realtime-provider` | Adding a realtime audio/video provider or changing provider event mapping |
| `docs-contract` | Writing or updating `docs/`, or changing promised behavior |
| `audio-spike` | Running a microphone, playback, or codec experiment |

## Reference project

`D:\File\Reference\project\qwen-audio-agent` is read-only reference material.
When porting a design, record the source path in the commit or ADR. Preserve
the Apache-2.0 `NOTICE` and attribution when code is derived rather than
reimplemented.
