---
name: audio-spike
description: Run a MediaPilot microphone, playback, resampling, or codec experiment on Windows without polluting the main packages
---

# Audio spike

Use this for a time-boxed audio experiment: device capture, playback,
resampling, chunk timing, or codec behavior. Spikes produce evidence, not
production code.

## Rules

1. Work in a throwaway directory or a `spike/` package. Do not add experimental
   dependencies to the root module.
2. Pin every dependency version in the spike's own `moon.mod`.
3. Record the environment: OS, device name, MoonBit version, package versions.
4. Measure, do not estimate. Report sample counts, chunk sizes, latency in ms.
5. Delete or archive the spike when done. If it changes a decision, write an
   ADR in `docs/decisions/`.

## Known-good baseline (Windows, 2026-10)

- `moonbitlang/core/async`（核心库内置，无需单独安装）—— native WebSocket server/client 可用。
- `moonbit-community/moon_cpal@0.11.8` — enumerates input/output devices.
- `moon` 0.1.20261029.

These are probes, not guarantees. Re-verify before relying on them.

## Capture experiment

- Open the default input device, request mono 16 kHz PCM16.
- Log: actual sample rate, buffer size, first-sample latency, dropped frames.
- Send 20/40/60/100 ms chunks over a local WS echo and measure round trip.
- Check behavior when the device is unplugged mid-stream.

## Playback experiment

- Open the default output device at 24 kHz mono PCM16.
- Feed silence, a sine sweep, and a speech sample.
- Log underruns and the audible gap when a chunk arrives late.
- Verify that stopping playback immediately is possible (needed for interrupt).

## Resampling

- Do not hand-roll a resampler for production without tests.
- Compare browser WebAudio resampling with a native candidate on the same
  input; record passband and latency.
- If native capture is unavoidable, add AEC/NS/AGC to the evaluation before
  proposing it; raw capture is not shippable for a voice product.

## Exit

Write a short result block:

```text
Question:
Setup:
Measurement:
Result:
Decision / ADR:
Artifacts:
```

If the result is "not viable", say so plainly and name the fallback. A failed
spike that saves a month is a success.
