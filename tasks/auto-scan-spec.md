# Automatic paper-to-PDF acceptance contract

One-time setup: API key, Meta registration/camera permission. Each scan: user presses Start Auto Scan, then uses no phone controls until the PDF opens.

1. A raw high-resolution preview is sampled at most 3 times/second, with only one analysis in flight. Vision detects page corners. Local grayscale statistics measure interior blur/contrast/exposure. No OCR or cleanup changes the submitted image.
2. Reject clipped/small/skewed pages and motion. Require at least 1.5 seconds of continuous good samples, bounded sample gaps, and both incremental and cumulative stability.
3. Stop streaming before starting the standalone Photo capability. Wait for state acknowledgements; capture full/high, receive data/progress, and stop Photo before resuming preview. Use stream-photo fallback only for unsupported standalone setup, then apply the same still checks.
4. Validate the actual still. Locally rejected photos are not uploaded. Up to three capture attempts per session; explain positioning by speech. AI also returns an explicit readable flag; allow at most one AI-requested retake. Never blindly retry an uncertain network request.
5. Send the entire clear JPEG to OpenAI. Structured solution includes problem as read, steps, final answer and verification. Generate a paginated PDF and automatically present PDFKit; persist PDF/source/solution locally.
6. Exactly one successful page per scan session. Stop camera and keep results visible. New scan requires a new explicit start. One job at a time; stale callbacks cannot submit or present after cancellation.
7. Keep iPhone awake while active. Pause/end on background, disconnect or errors, and restore idle timer. Initial OS/Meta permission dialogs still require interaction. Spoken cues follow the phone's selected audio route.

Verification: pure quality/stability tests, mocked HTTP success/incomplete/refusal/error tests, pipeline cancellation and retry tests, PDF multiple-page/content tests, and device/simulator builds in CI. Hardware capture and real page threshold calibration remain on-device acceptance gates.
