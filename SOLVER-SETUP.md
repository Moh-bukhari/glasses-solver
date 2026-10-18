# Glasses Solver 1.2 — automatic paper-to-PDF

## Install the update from Windows

1. Open [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Pick the latest successful run on `solver-app`.
2. Download **GlassesSolver-IPA** under Artifacts, then extract the ZIP.
3. Connect your iPhone and import `GlassesSolver-unsigned.ipa` in the working iloader installation. Install over the existing app with the same Apple account so its settings and files can remain available.
4. Open **Glasses Solver → Auto Scan**. Your existing API key/model should remain if the signing identity and Keychain access remain the same. Otherwise enter them again in Settings.

No Mac or Apple credentials in GitHub are needed. The IPA is unsigned until iloader signs it. A passing build is not a test of your provisioning profile, glasses firmware, or account capabilities.

## Use it

One-time setup: connect/register glasses through Meta AI, grant camera permission, and enter an OpenAI API key in Settings. API usage is billed separately from ChatGPT.

1. Put on the glasses, open **Auto Scan**, and tap **Start Auto Scan**.
2. Look at the problem you want to solve. Paper corners, a clean background, and a perfectly straight angle are not required. Follow the spoken directions: look left/right, tilt your head up/down, move closer/back, then hold still. Directions refer to your head/camera. An optional outline follows the writing, not the paper.
3. When you hear “Hold still,” stay steady through “Capturing.” The app captures, checks the actual still, sends it to AI, creates the PDF, and opens it automatically. No import, shutter, Solve, or PDF-open tap is needed.
4. Scanning stops after one successful photo. Read/share the PDF or find it later in the **PDFs** tab. Start another scan for a new page.

Keep the app on screen and the phone unlocked during scanning/solving. Auto Scan temporarily prevents auto-lock and restores the previous setting afterward. Spoken cues use the current iPhone audio route; Bluetooth routing to glasses depends on iOS/audio settings. Backgrounding stops active scanning; initial Meta permission dialogs are an exception. This version does not promise locked-phone or voice-launch operation.

**Import a paper photo** also checks and solves automatically. It is useful for testing your existing Meta AI photos before trying a live scan. If Settings opens because the key is missing, save the key and select the photo again.

## Image quality and request limits

- The preview only helps aim and hold steady. Apple Vision locates text regions without transcribing characters. It does not search for paper corners. The main text group nearest the center guides positioning; unrelated background labels are ignored when separable.
- Framing advice is deliberately forgiving. A good position needs about 1.5 seconds of steadiness. A steady view with imperfect framing, handwriting or no detected text region can still capture after about 3 seconds, then let the AI check the actual photo. Directions settle before being spoken; “hold still” can interrupt them promptly, and useful reminders can repeat.
- Local checks only block obvious darkness, missing detail or heavy blur. There is no full-sheet, clean-background, perspective or minimum-800-pixel requirement. The phone still checks motion, sample gaps and drift; one preview analysis runs at a time.
- After detection, the preview stops and Meta's standalone Photo capability requests `.full` resolution and `.high` quality. This capability is experimental and must be supported by the glasses/account. Unsupported setup can fall back to stream-photo capture; the final photo still has to pass the same quality checks.
- The whole photo is sent at its original dimensions as an orientation-normalized 95%-quality JPEG. There is no OCR, crop, perspective correction, or enhancement in the uploaded photo. A temporary writing-region crop (or the center when no text region is found) is used only to measure detail. Fixed full-frame pixels measure steadiness.
- A failed local quality check retakes without an API request, up to three captures per scan. The AI checks that the targeted problem’s essential instructions, symbols and diagrams are readable, while ignoring irrelevant background text and partial neighboring problems; at most one AI-requested retake is allowed (maximum two AI requests per scan). Uncertain network failures are not retried automatically, to avoid unexpected duplicate charges. A captured photo remains in memory for an explicit retry while the app stays alive.
- Exactly one job runs at a time. Success stops scanning; the same page cannot repeatedly trigger requests. Stop/cancel invalidates late callbacks and late responses.

A normal photo of one complete problem is enough; the whole sheet is optional. These local heuristics cannot prove that every symbol is readable or identify your intended problem perfectly. The AI makes the final content check and may request a clearer view. Capture timing, voice routing and thresholds still need real-glasses trials. Check the problem transcription in the PDF.

## PDFs and privacy

Each successful job saves `Solution.pdf`, `Paper.jpg`, and `Solution.json` in **Files → On My iPhone → Glasses Solver → Solutions**. The in-app **PDFs** tab lists new saved solutions. PDFs include problem statements, numbered steps, answers, verification, page numbers and the source photograph. Math uses readable Unicode/plain-text expressions, not a LaTeX typesetting engine. Older version-1.0 PDFs remain available in Files.

The API key stays in device-only Keychain. Clear it in Settings and save to remove it. Only accepted captures or explicitly imported photos are sent to `api.openai.com`; preview analysis stays local. `store: false` disables Responses storage, not all provider retention. This personal-device app would need a backend/credential design before public distribution. No live key is embedded in source, build logs, or the IPA.

## Verification

The workflow runs `AutoScanTests` on an iOS 26.4.1 simulator alongside a separate Release IPA build; use a run only when both jobs pass. Tests cover directional coordinates, voice debounce/repetition, forgiving framing and missing-text fallback, borderless/cluttered/tilted/720-pixel photos, stable capture, movement/gaps/drift, local clarity/blur fixtures, automatic capture-to-solve-to-PDF transitions, local retakes without uploads, cancellation, missing keys, response decoding and PDF pagination. Synthetic fixtures and mocked AI responses prove software behavior; they do not prove live glasses quality or AI answer accuracy. Physical full-resolution capture, cue routing and natural page calibration still require the installed-device test.

References: [Meta camera capture](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/camera-capture/SKILL.md), [Apple text-region detection](https://developer.apple.com/documentation/vision/vndetecttextrectanglesrequest), [OpenAI vision](https://developers.openai.com/api/docs/guides/images-vision), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs).
