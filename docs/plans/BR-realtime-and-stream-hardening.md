# Plan BR — Realtime Session & Camera Stream Hardening

**Status: 📋 Planned (2026-07-15).** Three verified gaps, each with a deterministic core;
one PR. Sourced from a systematic review of community work on comparable glasses apps
(techniques adopted on their own merits) — everything below was checked against this
codebase first; the many techniques we already have (context-window compression,
background HEVC decode, audio-only mode, `voiceChat` AEC, gateway-gated tool advertising)
are *not* re-listed.

## P1 — Live-session tool-call circuit breaker

**Gap (code-verified):** neither `GeminiLive/` nor `OpenAIRealtime/` bounds tool calling.
A model looping the same failing tool — or ping-ponging between tools — burns battery and
quota mid-session with no exit. `SafetySupervisor` (Plan S) governs *planned agent runs*,
not the realtime paths.

- Pure `ToolCallBreaker`: per-session sliding window counting (a) consecutive calls with
  no intervening user turn, (b) repeated identical tool+args failures. Trip thresholds
  configurable; on trip → inject a synthetic tool result telling the model the tool is
  suspended this session, stop advertising it in the next setup message, surface one TTS
  notice (BK P2c narration pattern).
- Wire into both session managers at the single tool-dispatch choke point each already has.
- Tests: threshold trips, window reset on user turn, identical-failure detection,
  suspension list feeding setup-message tool filtering.

## P2 — Camera stream resilience + compatibility surfacing

**Gap:** a stream failure can silently wedge the session, and an outdated Meta AI app /
glasses firmware presents as a mystery connection failure.

- Retain the `DeviceSession` across stream failures — tear down and rebuild the `Stream`,
  not the session; explicit teardown ordering so a failed stream can't strand the session
  in a half-open state. Pure `StreamRecoveryPolicy` (failure class → rebuild stream /
  rebuild session / give up) + thin edge in `CameraService`.
- Surface DAT compatibility: detect the SDK's update-required signals and turn them into
  actionable copy ("Update the Meta AI app to keep streaming") instead of generic errors —
  settings row + one-time TTS notice. (Exact signal source verified at implementation
  against the 0.8 `.swiftinterface` — ground truth per house rule.)
- Tests: policy classification table; recovery sequencing on a fake session/stream seam
  (no `Wearables` in unit tests).

## P3 — Realtime WebSocket connection-generation guard

**Gap (code-verified):** `GeminiLiveService` overwrites its shared delegate's
`onClose`/`onError` closures on every `connect()`. A cancelled task's late terminal
callback therefore fires against the *new* connection — spurious failure/reconnect on
top of a healthy socket. Plan BD's `reconnectPending` coalescing narrows but does not
close this.

- Monotonic `connectionGeneration`; every delegate callback (incl. the connect-timeout
  task) captures its generation and no-ops if superseded. Same audit + fix for
  `OpenAIRealtime`'s socket handling.
- Tests: stale-close ignored, stale-error ignored, stale-timeout ignored, current-gen
  callbacks still flow; reconnect counter unaffected by superseded callbacks.

## Rider — Live-model migration checklist (documentation only)

Community migrations to the newer Gemini Live models (`3.1-flash-live-preview`) hit a
consistent minefield; recorded here for when we bump models:
- Empty `inputAudioTranscription` / `automaticActivityDetection.disabled` in setup →
  server closes 1011.
- `TEXT` response modality rejected on 3.x Live (AUDIO + `outputAudioTranscription`
  instead — we already use audio, but the classifier/quick paths should be checked).
- Oversized setup/turn payloads → close 1007; truncate context injected into setup.
- On connect failure, fetch and log the key's Live-capable model list — turns "1011, no
  reason" into "your key lacks access to X".
- Endpoint remains v1beta (we're already there).

## Explicitly evaluated and skipped
- Mic-mute-during-AI-speech speaker mode — incompatible with barge-in by design.
- Glasses long-press assistant activation — Android-only package-squat of another app's
  bundle id; unshippable, fragile. (Noted for Plan BA as a community signal that the
  long-press surface is in demand.)
- Indefinite unbounded WS reconnect — our BD policy (bounded, backoff, presence-aware) is
  strictly better.
- Face-recognition thumbnails, phone-camera tap-to-focus/pinch-zoom — real but cosmetic;
  candidates for a UX-polish pass, not this plan.

## Verification
Headless: breaker/policy/generation tests + full suite + Release green. Device: one
glasses session covering a forced stream failure (walk out of BT range mid-stream),
a live-session tool failure loop (misconfigured tool), and a reconnect under network flap.
