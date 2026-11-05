---
name: realtime-provider
description: Add or modify a MediaPilot realtime audio/video provider adapter such as DashScope, OpenAI, or Gemini
---

# Realtime provider adapter

Use this when adding a provider under `realtime/` or changing how provider
events map to normalized events.

## 1. Read the boundary first

- `docs/architecture.md` — why provider details stop at the adapter.
- `docs/contract.md` — normalized server events you may emit.
- The reference implementation for the target provider:
  `D:\File\Reference\project\qwen-audio-agent\server\src\voice\providers\`.

The adapter's job is translation. It does not own sessions, HTTP, static
files, or client sockets.

Audio is the only implemented media type. Video frames reuse this same boundary
in P4; do not add video code or codec dependencies before the roadmap reaches
it.

## 2. Define the adapter surface

Keep it small and explicit:

```text
connect(config) -> provider session
send_audio(session, bytes, format)
send_text(session, text)
interrupt(session)
close(session)
events(session) -> normalized event stream
```

If a provider needs an extra capability, add an optional method and a
capability ID; do not widen the common interface for one provider.

## 3. Write the mapping table before code

For each provider event, record:

| Provider event | Normalized event | Notes |
| --- | --- | --- |
| … | `transcript.partial` / `transcript.final` | … |
| … | `audio.delta` | sample rate, encoding |
| … | `error` | contract error code, retryable |

Then implement the table. Reviewers should be able to check coverage against
it.

## 4. Pin the wire facts

- Input audio: PCM16, mono, 16 kHz unless the provider requires otherwise.
- Output audio: record the actual rate; do not assume it matches input.
- Chunking: adapter accepts arbitrary chunk sizes and buffers if needed.
- Pacing: some providers run server-side VAD and only end a turn when audio
  arrives in real time. Sending a whole utterance in one burst can leave the
  turn open forever. Record the required pacing and test it.
- Interrupt: know whether the provider needs an explicit cancel and whether
  stale audio can still arrive after cancel.
- Keepalive: record ping/pong or heartbeat requirements and timeouts.
- Auth: read from config/env; never log the key or full URL with query token.

Write the verified facts to `docs/providers/<provider>.md` once a live
connection succeeds. That page is the reference for the next adapter.

## 5. Error mapping

Map provider failures to the contract's codes:

- network/timeout/5xx → `provider_unavailable`, `retryable = true`
- 401/403/bad key → `provider_auth_failed`, `retryable = false`
- malformed request → `invalid_event` or `audio_format_unsupported`
- unknown → `internal_error`, `retryable = true`, log with a correlation ID

Keep the raw provider message in logs only. The client sees the contract code
and a human-readable message without secrets.

## 6. Tests

- Unit tests replay recorded provider frames from a fixture. No network.
- Assert normalized event sequence, including interrupt and close.
- Assert error mapping for at least auth, timeout, and malformed frame.
- Live smoke test is separate, gated by an env var, and never runs in CI by
  default.
- Fixtures must be redacted: no tokens, no real user audio.

## 7. Checklist

- [ ] Provider JSON never escapes `realtime/`.
- [ ] New provider has a capability entry if it enables new behavior.
- [ ] `docs/contract.md` unchanged unless the normalized surface changed.
- [ ] `docs/providers/<provider>.md` records the verified wire facts.
- [ ] Adapter closes the upstream connection on client disconnect.
- [ ] `moon check --target native` and `moon test --target native` pass.
