# Plan BU — Offline Live Session

**Status: 📋 Planned (2026-07-16).** A fully on-device live session mode: continuous voice
Q&A grounded on the *latest camera frame* — on-device speech-to-text in, a local vision
model answering, streamed on-device TTS out. The private tier of the live-mode family:
Direct mode needs a turn per exchange, Gemini Live and OpenAI Realtime need cloud and a
key; this mode needs **no signal and no account**, at zero marginal cost. Flying, roaming,
in a basement plant room, or simply privacy-preferring — the glasses keep working.

Every primitive already exists: SmolVLM2 vision models ship in `LocalLLMService` (2.2B and
the 500M video variant), the camera frame pipeline + `FrameGate`, on-device STT via the
wake-word/speech stack, sentence-boundary `speakStreaming` TTS (Kokoro or system voice),
and the Plan W presence gate. The plan is the session loop that stitches them — same
"mode, not app" posture as Plan BT.

**Hard constraint carried from the local-model work: foreground only.** On-device MLX
inference cannot run backgrounded; the session must pause cleanly on background and
resume on foreground, never half-run.

## P1 / PR1 — Session core (pure, headless)

- `LiveSessionTurnLoop` (pure state machine): `idle → listening → transcribing → inferring
  → speaking → listening`, with barge-in (speech during `speaking` cancels TTS and starts
  a new turn) and a cancellation path from every state. Injected clock; no `Date()`.
- **Freshness policy**: the model answers on the newest frame *at ask-time* — the loop
  never streams frames to the model (that's the cloud modes' shape; a 2B VLM gets one
  image per turn). A frame older than a threshold at inference start is re-grabbed.
- `LiveTurnAssembler` (pure): prompt = compact persona + grounding rule ("answer from the
  image and the conversation; say when you can't see it") + short rolling transcript
  window (reuse the history-compression shape), budget-capped for the small model.
- Tests: state machine transitions incl. barge-in and cancel-from-every-state, freshness
  policy boundaries, assembler budget + rolling window.

## P2 / PR2 — Wiring + mode surface

- `OfflineLiveSessionService`: owns the loop; mic via the existing speech stack, frames
  via `CameraService.framePublisher` (+ capture-then-restore camera bookkeeping, per the
  Plan BT P2.1 precedent), inference via `LocalLLMService` VLM, voice via
  `speakStreaming`. Foreground guard + clean pause/resume on scene phase.
- Presence: `.away` suspends (caption-gate semantics); power posture defers to Plan BV
  when it lands (frame-grab downscale, model-tier preference under thermal load).
- Surface: start/stop via voice tool + a mode entry alongside the other live modes;
  transcript recorded to the conversation store like other sessions.

## Explicitly out of scope
- Mid-session cloud fallback — the point of the mode is that it never leaves the device;
  the cascade exists in Direct mode for users who want best-effort.
- Continuous frame *streaming* to the model — one fresh frame per turn, by design.

## Risks / escape hatches
- Per-turn VLM latency on phone hardware is THE risk; mitigations: the 500M video-tuned
  model as default for this mode, frame downscale before encode, and the streamed TTS
  masking tail latency. If turn latency is still conversationally dead, the fallback
  posture is push-to-talk framing ("ask, wait, answer") rather than open-mic flow.
- Memory pressure with a resident VLM + session audio: measure; the 500M default and
  model unload-on-end are the levers.

## Verification
Headless: loop state machine, freshness, assembler tests + full suite + Release green.
Device: a 10-minute offline session (airplane mode) — turn latency, barge-in, memory
headroom, thermals.
