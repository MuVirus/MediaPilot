---
name: gateway-protocol
description: Add or change a MediaPilot client-facing WS event, capability, handshake, or error code
---

# Gateway protocol change

Use this when the task touches `docs/contract.md`, `protocol/`, the client
handshake, or any client-facing event.

## 1. Decide the change class

- **Additive**: new event, new optional field, new capability. Bump minor.
- **Breaking**: rename/remove field, change semantics, change required
  handshake. Bump major and write the migration in `docs/contract.md`.
- **Internal**: no client-visible change. Do not touch the contract.

If unsure, it is breaking. Never ship a breaking change silently.

## 2. Update, in one change

1. `protocol/` types and JSON codec.
2. Capability constant and the capability table in `docs/contract.md`.
3. Any client types or reference client code.
4. The contract text: current behavior only, no roadmap language.
5. Tests.

Do not update the doc in a later commit. Drift is the failure mode this
workflow exists to prevent.

## 3. Test requirements

At minimum:

- Round-trip encode/decode for every new event.
- Golden JSON for the event, so field renames are visible in review.
- Unknown event type is ignored, not fatal.
- Unknown capability degrades, not crashes.
- Handshake rejection for an unsupported major version.

Put the test path in the contract's `Locked by` column. If the test cannot be
written yet, write `pending: <phase>` and do not claim the behavior is stable.

## 4. Checklist

- [ ] Every server event has `type`; all non-error events have `sessionId`.
- [ ] `requestId` is echoed, never interpreted.
- [ ] Audio events state `format`, `sampleRate`, `channels`.
- [ ] New error code added to the contract table with `retryable`.
- [ ] Capability added to `GET /api/health`.
- [ ] `moon check --target native` and `moon test --target native` pass.
- [ ] `moon info && moon fmt` produces no unexpected `.mbti` diff.

## 5. Do not

- Leak provider field names or raw provider JSON.
- Add a field "for later" without a consumer.
- Compare product versions on the client; compare capabilities.
- Make unknown input fatal.
