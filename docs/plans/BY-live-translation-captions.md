# Plan BY — Live Translation Captions

**Status: 📋 Planned.**

Subtitle the world: real-time translated captions of surrounding speech, on the phone overlay
and the in-lens HUD — "they're speaking Spanish, you read English." Plus a **two-way
conversation mode** for a bilingual exchange, where each side's speech is rendered in the
other's language. This is a genuine capability gap: ambient captions (transcription) and
speaker diarization exist; translation does not.

## Architecture: a seam, two tiers, and hardened caption mechanics

### Provider seam
`TranslationCaptionProvider` protocol next to the existing `DiarizationProvider` seam in the
caption path: audio/transcript in → `TranslationSegment` out
(`text`, `originalText`, `sourceLanguage`, `targetLanguage`, `speakerId?`, `utteranceId`,
`isFinal`). Two implementations:

1. **Cloud tier — unified stream.** Prefer a provider whose single websocket does
   STT + language auto-detect + translation (+ diarization) in one stream — one connection,
   one latency budget, interim+final semantics for both transcript and translation. Soniox's
   realtime API is the lead candidate (evaluate against wiring translation on top of the
   existing Deepgram stream as the fallback shape). Key pool + health/fallback per the
   provider-resilience house patterns.
2. **On-device tier — offline & HIPAA.** SenseVoice ASR (already vendored, multilingual with
   language ID) → Apple's Translation framework for on-device translation. Lower quality,
   zero cloud egress. **HIPAA mode hard-disables the cloud tier at start AND kills a running
   cloud stream on mid-session toggle** (the AQ lesson — start-time-only gating is a hole).

### Caption mechanics (pure, provider-agnostic — the quality layer)
These harden *existing* ambient captions too, and are fully headless-testable:

- **`EndpointDebouncer`** — when the provider signals an utterance endpoint, hold ~500 ms; if
  more tokens arrive, the endpoint was premature — discard it. Kills the mid-sentence caption
  splits that make live captions feel broken.
- **`CaptionCompactor`** — rolling compaction for long utterances: finalized tokens collapse
  into a stable prefix string, only the unstable tail stays token-granular. Interim render =
  prefix + tail; the final always equals the last interim (no jarring rewrite), and memory
  stays bounded on a monologue.
- **`TranslationCaptionFormatter`** — speaker-change labels (`[2]:` only when the diarized
  speaker *changes*, stable across interim→final), original-text ribbon (optional smaller
  line), HUD line shaping via the existing condense/width rules.

### Two-way mode
One session, two language legs (A→B and B→A). The provider seam takes a
`TranslationDirectionPolicy`: `oneWay(target)` or `twoWay(a, b)` — in two-way, each final
segment renders in the *counterpart* language, labeled per speaker. Phone UI splits top/bottom;
HUD shows the line addressed to the wearer.

## Surfaces

- **Phone:** the ambient-caption overlay grows a translation mode (target-language picker,
  show-original toggle) — settings live with the existing caption/diarization settings.
- **HUD:** translated line via `GlassesDisplayService.showText` path, throttled to final
  segments + slow interims (BLE budget); respects interactive-screen suppression as captions
  do today.
- **Meeting summaries / BrainStore:** translated finals feed the same caption history, so
  `MeetingSummaryTool` summarizes a foreign-language meeting for free; ingest tagged with
  source language.

## Phases

### P1 / PR1 — Deterministic core 🟢
- `TranslationSegment`, `TranslationDirectionPolicy`, `TranslationCaptionProvider` protocol.
- `EndpointDebouncer`, `CaptionCompactor`, `TranslationCaptionFormatter` (pure).
- Wire compactor + debouncer under the existing ambient-caption path behind a flag
  (`captionCompactionEnabled`, default on — behavior-preserving for short utterances by
  construction, tests prove it).
- Stream-message parser for the chosen cloud provider's wire shape (pure decode of recorded
  fixtures — no network in tests).
- Tests: debounce discard/commit timing, compaction invariants (final == last interim; bounded
  memory), speaker-label transitions, two-way routing table, parser fixtures incl. malformed
  frames.

### P2 / PR2 — Cloud provider live + settings
- Websocket client on the parser (connection lifecycle per the realtime-hardening patterns:
  bounded in-flight sends, drop-don't-queue under backpressure, stall detector).
- Settings UI: enable, target language, auto-detect source, show-original, provider key.
- HIPAA gate (start + runtime), Medical-Compliance copy.
- Device-pending: live latency/quality validation.

### P3 / PR3 — On-device tier + two-way + HUD
- SenseVoice → Translation-framework pipeline as the offline provider; automatic tier
  selection (offline/HIPAA → on-device; else cloud) surfaced honestly in the UI.
- Two-way conversation mode UI (phone split view; HUD wearer-leg rendering).
- Device-pending: mic distance/diarization quality in two-way mode.

## Open decisions
- Provider bake-off (Soniox-class unified stream vs. Deepgram+LLM-translate) — pick after P1
  fixtures make swapping cheap; the seam means it's not a blocker.
- Whether translated captions join the diarized speaker-chip UI once AQ's chips land
  (leaning yes — same rail).
- Language-pair scope for v1 UI (free-pick vs. curated top-10; Translation framework's
  download-per-pair management applies on the offline tier).
