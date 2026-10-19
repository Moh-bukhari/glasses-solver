# One-button, gesture-controlled fast packet solving (2.0)

## User request (2026-10-19)

Solving showed "solving" and never produced a PDF. The user wants one start button. The app should find each page, capture it once it has a good view, save it, and move on. A thumbs-up in front of the glasses stops scanning and solves; solving each page while scanning and combining at the end is acceptable if it is better. Control must come from hand gestures or clicks on the glasses, not voice, as a silent experience that still gives every needed instruction. It must be fast, with fast PDF generation and fast, reliable multi-page scanning. Use GPT-6.1 Sol (`gpt-6.1-sol`) for OpenAI and Claude Opus 5.5 (`claude-opus-5-5`) for Claude.

## Root cause of "solving forever"

There is no deadlock. The 1.3.x pipeline ran a strictly sequential chain of 4–18 non-streaming reasoning requests: inventory, audit, then a solve and a reconcile per group of six subparts. Every request re-sent every photo, and the default mode used both providers. Reasoning tokens counted against 16k caps, so truncation triggered 24k repairs that could outlast the 300 s idle / 360 s total URLSession limits. There were no retries for transient errors, and progress was not kept between stages. Switching tabs or backgrounding also cancelled the run. A 3–6 page packet took roughly 10–45 minutes, often ending in a timeout.

## Acceptance criteria

### Controls and instructions

- One **Start scanning** button starts the glasses camera and automatic capture. After a finished PDF, Start begins a new packet.
- **Thumbs-up** held about one second in view of the glasses finishes scanning and solves. **Thumbs-down** retakes the last page.
- Gestures come from on-device Vision hand-pose analysis of preview frames. A gesture needs four consecutive matching analyses spanning at least 0.9 s, followed by a cooldown and a release. Small or distant hands, hands at the frame edge, hands gripping paper, and pinch grips must not trigger anything. A visible command hand blocks capture.
- **Glasses buttons** use the experimental Meta Inputs capability:
  - Touchpad double-tap or capture-button double-press: finish and solve.
  - Capture-button press: next page now, or take the current view.
  - Capture-button hold: retake the last page.
- A single touchpad tap is reserved by the glasses for pause/resume. A pause must not fail the scan; scanning continues after resume.
- Inputs re-attach after each full-resolution photo. Unavailability is reported once; gestures and on-screen controls keep working.
- Voice commands are off by default and the microphone is not used.
- Instructions are short, quiet speech (5% default) through the glasses/Bluetooth audio route using the `.playback` category, so the Silent switch does not mute them. By default the phone loudspeaker never speaks. The screen shows the same instructions.
  - The controls are spoken once per run, and gesture holds and button commands are acknowledged.
  - A missing API key is announced at Start. Look-alike pages get a capture-button hint.
  - If glasses audio is not the route, the screen says so.
- The shutter moment is announced ("Got it") so the wearer can turn the page while the photo transfers. A rejected still asks for that page again.

### Fast, reliable capture

- Analyze every delivered preview frame (no fixed 0.33 s throttle; one analysis in flight).
- Overlap the still check and save with the preview restart. Remove the fixed two-second retake sleep. A hands-free run never ends just because stills were unclear; it keeps guiding.
- Check full stills on a half-resolution decode when text is clearly large enough. Otherwise fall back to the exact full-resolution check. Keep the original JPEG bytes instead of re-encoding.
- Shorten the hold to 1.0 s only when the view is clearly sharp, contrasty and close. Otherwise keep the existing 1.5 s / 3 s holds. The close-up, darkness, contrast and blur gates are not weakened.
- Cache page thumbnails instead of decoding every saved JPEG on every preview frame.
- Treat Meta `dwaOutOfStuRange` as a non-fatal notice. Ignore photos the wearer takes with the shutter that the app did not request.
- Up to 30 pages per packet.

### Solving

- One streaming request per page, solved while scanning by default. Page *N* is solved once page *N+1* is saved (or at Finish), with the previous and next pages as labeled context.
  - Ownership rule: every item (a question, or each lettered or numbered subpart) belongs to the page where its own label first appears.
  - A page uses the previous page for shared stems and data, and the next page only to finish an item that is cut off at its bottom.
  - A page skips an item only if that item's own label already appears on the previous page, as a continuation or an overlapping photo.
  - Before the PDF is built, any skipped item that no earlier page solved triggers one re-solve of that page, which must then solve it.
  - The last page is solved at Finish.
- Retaking, replacing or removing a page re-solves only the pages whose context changed. Results are cached by page/context/provider, so a retry re-solves only failed pages.
- After Finish, only the last page (plus any still in flight) remains, so the PDF should be ready about one page-request after the thumbs-up.
- Provider modes:
  - OpenAI (`gpt-6.1-sol`, medium reasoning).
  - Claude (`claude-opus-5-5`, adaptive thinking, medium effort).
  - Both / cross-check: both providers solve each page in parallel, then the lead reconciles against the photos. This takes one extra round per page.
- One-time migration of old defaults:
  - `gpt-5.4` becomes `gpt-6.1-sol`.
  - `claude-sonnet-5-5` becomes `claude-opus-5-5`.
  - The old default "both" becomes a single provider: OpenAI when its key exists, otherwise Claude.
  - Explicit non-default model IDs are kept.
- Streaming SSE parsing for Claude Messages and OpenAI Responses, with idle timeouts. Transient HTTP 408/429/5xx/529, stream errors, and network losses are retried at most twice with backoff, honoring a bounded `retry-after`. Authentication, billing, model, request-size and refusal errors are never retried.
- Malformed, truncated or self-inconsistent output gets one repair.
- Per-page output: readable / retake, title, checklist of every label on the page, solutions (label, problem, steps, answer, check, status, review note, source pages), and skipped labels with reasons.
  - The checklist must be covered by solutions or skips; a parent number counts as covered by its answered subparts.
  - Unresolved items need a review note and may leave the answer empty.
  - Unreadable pages are announced during scanning and stop at Finish with page-specific retake advice; nothing is fabricated.
- Each page's progress is visible on its thumbnail. Solving is not cancelled by switching tabs or by Pause. Backgrounding stops the camera, says so, and lets in-flight solving continue for as long as iOS allows.
- Draft files use until-first-unlock protection, so a locked phone does not block the PDF. Failed pages can be retried; only those are re-solved.
- No partial PDF. One combined PDF in page order: coverage summary, every solution, review flags, and all source photos.
  - Rendering runs off the main actor and embeds downscaled JPEG source previews.
  - After the PDF, the packet stays and is marked solved. Retaking or replacing a page and tapping Done rebuilds the PDF, re-solving only the affected pages. Start, or a new photo, begins a new packet.

## Verification

- **Unit tests:** gesture classifier and gate fixtures; glasses event mapping; job planning and invalidation; page-result validation; Claude and OpenAI SSE parsing (complete, truncated, refusal, error event); retry and repair bounds and credential separation; request bodies (model IDs, stream, effort/thinking, schema).
- **Coordinator tests:** eager solve after the next page, solve of the last page at Finish, thumbs-up gesture finishing, single PDF, failed-page retry, cancellation, and pause tolerance.
- **Existing tests:** capture, quality, PDF, voice-callback and Meta mock-camera tests still pass.
- **CI:** the macOS workflow builds the unsigned IPA and runs the test classes.
- **Device-only checks:** real gesture thresholds, Inputs availability and event mapping on Gen 2 glasses, audio routing, and live paid API latency and accuracy.
