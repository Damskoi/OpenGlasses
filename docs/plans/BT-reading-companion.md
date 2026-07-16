# Plan BT — Reading Companion

**Status: 🚧 P1 shipped (2026-07-16) — pure session core, 35 headless tests, Release green;
P2/P3 planned.** A continuous *reading session* vertical: the glasses
read along with a physical book or e-reader, answer questions grounded in **what the
reader has actually seen**, and turn each session into retention artifacts (recap, study
deck) and reading stats. Every primitive already exists in this codebase — OCR (Plan A),
`FrameGate` keyframes (AT), Study Mode (deck/flashcards/quiz), Brain ingestion, the live
voice loop; the plan is the session-state layer that stitches them. Market signal: this
exact vertical is appearing as standalone products and as community teleprompter hacks,
i.e. demand is validated; OpenGlasses ships it as a mode, not a separate app.

**Design principle — spoiler safety by construction:** the assistant's grounding corpus
is *only the pages captured this-and-prior sessions of this book*. Questions are answered
from the read-so-far store, never from model world-knowledge about the book (the prompt
says so explicitly, and the context builder physically cannot include unread text).

## P1 / PR1 — Session core (pure, headless) — ✅ shipped

**As-built notes:**
- `PageTurnDetector` reads one `FrameGate` signal two ways rather than adding a second
  comparison: a **send** is the change (candidate opens, clock restarts), a **drop** is the
  stillness. One threshold for both halves, so no frame can be neither. It runs its own gate
  (`hammingThreshold: 3`, no heartbeat, **adaptive off** — the adaptive path widens the drop
  window in static scenes, and a book on a table is the most static scene there is, so it would
  have swallowed the page turns). Heartbeat sends are ignored defensively in case a caller
  injects a gate that has one.
- `ReadingSessionStore` dedups on **two** signals, not just the planned dHash: the hash catches a
  re-look whose OCR came out differently, the normalised text catches a re-look from a new angle
  whose hash therefore drifted. Text matching needs ≥40 chars, else "OCR found nothing" would
  read as "same page". Hash distance is tight (2 of 64) on purpose — a missed duplicate just
  repeats a page, a false one silently drops a page the reader did read.
- `pageIndex` is **book-scoped**, so page numbers run across sessions (Tuesday continues Monday).
  It's capture order, not the printed page number, which we have no way to know.
- `ReadingContextBuilder` returns `nil` rather than a rule with no pages under it — a spoiler rule
  with no evidence invites exactly the world-knowledge answer it's there to prevent. Verbatim
  pages are capped at ⅔ of the budget so a long current page can't starve the condensed history;
  the current page always ships, truncated if that's the only way. Dropped pages are declared in
  the block, never silently omitted.
- Blank-OCR pages stay in the store (a page really was turned — the pace stats want it) but are
  skipped by the builder; the resulting gap in numbering is the honest record of the OCR miss.
- Thresholds are init parameters, not `Config` yet — P1 has no live caller to read `Config` from.
  P2 wires them; the P3 device pass stays data-only as planned.


- `PageTurnDetector` (pure): consumes the existing `FrameGate` signal (`SendReason
  .distinct` keyframes over dHash, `Vision/FrameGate.swift`) plus a stability window — a
  page turn is a large visual change followed by ~1s of stillness; motion blur and hand
  occlusion frames are rejected by the stability check, not sent to OCR. Fixture-image
  tests (page A → blur → page B).
- `ReadingSessionStore`: one session = book id (user-named or cover-shot), ordered page
  captures (`pageIndex, text, capturedAt, dHash`), dedup by hash (looking back at an
  already-read page must not duplicate), stats derived not stored (pages/session,
  minutes, pace, session count per book). JSON file persistence, injectable directory
  (house test pattern).
- `ReadingContextBuilder` (pure): builds the turn context from the store — recency-window
  of full page text + summaries of older pages (reuse the compression pattern from
  conversation history), hard-capped for the local-model budget; prompt block states the
  spoiler rule.
- Tests: detector state machine, store dedup/ordering/stats, context budget + windowing,
  spoiler rule presence.

## P2 / PR2 — Live session mode + Q&A wiring

- `ReadingCompanionService`: session lifecycle (start/pause/end via voice or UI), frames
  from the existing `CameraService.framePublisher` → detector → OCR (the Plan A
  `ReadingAccessibilityTool` Vision path) → store. Presence-aware (Plan W throttle) and
  battery-conscious: between page turns the camera idles at the gate's heartbeat rate.
- Voice Q&A: a `.reading` classifier section injects the `ReadingContextBuilder` block
  into the turn (same pattern as the BQ-era weather pre-fetch — hand the model data, don't
  ask it to act); works with local and cloud models.
- "Where was I?" — session-resume recap spoken on session start (last page summary +
  position).
- End-of-session: recap spoken + saved as a note; **study deck generated from session
  pages** via the existing `StudyStore.saveDeck` (flashcards/quiz over what was read —
  not the whole book).
- Session content feeds `BrainStore.ingest` (native-first, per house rule) and surfaces
  in the BQ Spotlight index as a new content type (default on; text is the reader's own
  captured pages).

## P3 / PR3 — Polish + HUD (device-gated)

- Reading stats surface: per-book progress view (sessions, pace, streaks) in the app.
- HUD: "where was I?" recap card + progress on the Display surface (rides Plan BP's
  web-mirror when it lands; native DAT display already supported for Now/Next cards).
- Kindle/e-reader specifics: screen glare/contrast OCR tuning — device-gated accuracy
  pass (the detector/OCR thresholds are Config-tunable so the pass is data-only).

## Explicitly out of scope
- EPUB/book-file import — this is camera-grounded reading, not an e-reader.
- Full-book knowledge (summaries of unread chapters, reviews) — violates the spoiler rule.
- Text-to-speech of the page (Plan A's reading tool already does read-aloud on demand).

## Risks / escape hatches
- OCR quality on curved book pages in ambient light is THE risk — P1/P2 ship regardless
  (they're store/wiring); if page OCR is too noisy on device, the fallback posture is
  explicit capture ("read this page") instead of passive page-turn detection, which
  reuses everything except the detector trigger.
- Long-session battery: gate heartbeat + presence throttle bound it; measure in the P3
  device pass.

## Verification
Headless: detector fixtures, store round-trips, context budget, deck generation from
fixture pages + full suite + Release green. Device: one 20-minute physical-book session
(page turns detected, Q&A grounded, recap + deck correct) and one e-reader session
(glare/contrast), battery + thermal noted.
