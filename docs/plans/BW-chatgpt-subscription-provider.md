# Plan BW — ChatGPT Subscription Sign-In (Codex OAuth provider)

**Status: 📋 Planned (2026-07-18).** "Sign in with ChatGPT" as a no-API-key way to run OpenAI
models, mirroring the shipped Claude account sign-in (`ClaudeOAuth` / `ClaudeOAuthService` +
the onboarding surface from the build-320 PR). OpenAI explicitly supports subscription OAuth
in external tools now — but the token it grants authenticates against the **ChatGPT Codex
backend**, a **Responses-API** surface with its own model catalog, *not* `api.openai.com`
chat completions. So this is a **new provider path** (new auth + new wire format), not a
toggle on the existing OpenAI provider — which is exactly why it gets a plan instead of an
afternoon.

Structural facts the design hangs on:

- **Auth**: authorization-code + PKCE in the browser, with a **device-code** variant that is
  the better fit for iOS (no localhost-redirect contortions). Yields access + refresh tokens
  and an `id_token` whose **account-id claim must ride every API request** as a header.
- **Wire**: the backend speaks the Responses API (input/output *items*, SSE streaming), and
  serves the **Codex model catalog** (`gpt-5.x-codex` family) — not the general API models.
- **Hard exclusions**: subscription credentials are not valid where platform keys are
  required — our OpenAI **Realtime voice mode stays API-key-only**, documented, not worked
  around.

## P1 / PR1 — OAuth core (pure, headless)

- `ChatGPTOAuth` mirroring `ClaudeOAuth`'s shape: PKCE (extract the existing
  verifier/challenge/base64url helpers into a shared `PKCE` enum rather than duplicating),
  authorize-URL builder, **device-code request + poll** request shapes (pending / slow-down /
  expired handled as values), token-response parse (access / refresh / `id_token`), and
  account-id extraction from the `id_token` (pure base64url JWT-payload decode — we consume a
  claim, we don't validate signatures client-side).
- `Credentials` with `needsRefresh` leeway, refresh-request builder — same contract as the
  Claude pair so `ChatGPTOAuthService` (P3) can be a structural copy.
- All protocol constants (client id, authorize/token/device endpoints, backend base URL,
  required headers) in one place, explicitly marked *captured-at-implementation against the
  shipping auth service* — this backend is newer and driftier than Anthropic's; one constants
  block is the blast radius.
- Tests: PKCE vectors, authorize-URL shape, device-code poll state machine, token/claim
  parsing fixtures, refresh leeway boundaries.

## P2 / PR2 — Responses wire core (pure, headless)

- `ResponsesTranslator`: shared conversation history → Responses **input items** (text,
  image, tool results), `ToolDeclarations` → Responses tool declarations, and response
  **output items** → `(text, [ToolInvocation])`. Pure functions over `[[String: Any]]`, like
  `GeminiSchemaTranslator` / `HistoryHygiene`.
- SSE streaming: reuse `SSEEventParser` for framing; a small `ResponsesStreamAccumulator`
  folds item/delta events into the same reconstructed-message shape the tool loop consumes.
- `ProviderLoopAdapter` glue for `runToolLoop` — performTurn / appendAssistantToolCall /
  appendToolResults / finalize, with the leniency lessons already learned baked in from day
  one: tolerate missing ids/arguments on tool calls, tolerate missing text on tool-call
  turns, one parsed-vs-sent log line per turn.
- Tests: fixture transcripts for a text turn, an image turn, a tool-call turn (including a
  no-argument tool), a streamed turn reassembly, and history round-trips through
  `HistoryHygiene.pruneImages` (the item shape must be recognised — add it to the
  image-block matcher alongside the Anthropic/OpenAI/Gemini shapes).

## P3 / PR3 — Service edge + UI

- `ChatGPTOAuthService`: keychain persistence, refresh-ahead, `@Published isConnected`,
  `validAccessToken()` — structural copy of `ClaudeOAuthService`.
- New `LLMProvider.chatgpt` case ("ChatGPT (subscription)"): `requiresAPIKey == false`,
  its own base URL + model catalog (codex family, sensible default), request auth = bearer
  token + account-id header applied in one `ChatGPTAuth.apply` (parallel to
  `AnthropicAuth`).
- `sendChatGPT` built on the P2 translator + adapter; cascade integration classifies
  subscription-quota exhaustion like a 429 so `ModelCascade` hops correctly.
- UI: generalize the onboarding `claudeSignInSection` and the model editor's
  `claudeSignInRows` into one account-sign-in component parameterized by service (Claude /
  ChatGPT), rather than a third hand-rolled copy. Model editor gets the sign-in first;
  onboarding shows the ChatGPT tile **only after P4's quality pass** — the codex catalog is
  coding-tuned, and we don't put a provider in front of first-run users before hearing how
  it answers voice-assistant questions.

## P4 — Live verification (device)

Real login (device-code on phone), then: a streamed text turn, a tool turn (native + MCP),
an image turn, token refresh across an expiry, quota-exhaustion error taxonomy captured into
the cascade classifier. Decide the onboarding-tile question with real transcripts. Document
the Realtime exclusion in Settings copy.

## Explicitly out of scope

- OpenAI Realtime voice over subscription auth (platform-key-only; unchanged).
- Importing credentials from other tools' auth stores — we always run our own sign-in.
- Any use of the token against `api.openai.com` — different product, different key.

## Risks / escape hatches

- **Backend drift**: this surface moves faster than a public API. One constants block, P4
  as the gate before any onboarding exposure, and the provider degrades to "sign in again"
  rather than corrupting saved models.
- **Catalog fit**: codex models may answer voice queries in a coding register. P4 evaluates;
  the escape hatch is keeping the provider model-editor-only (power users) without the
  onboarding tile.
- **Device-code availability**: if the device-code variant is gated, fall back to the
  browser + paste-the-code pattern already proven by the Claude flow (the callback page
  displays a code; no localhost listener needed).

## Verification

Headless: P1/P2 test suites + full suite + Release green per PR. Device: the P4 checklist
above, on the phone, with the results written back into this doc before the onboarding tile
ships.
