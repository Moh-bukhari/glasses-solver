# Glasses Solver 1.3.1 — scan a packet, receive one PDF

Version 1.3.1 fixes unsafe Swift 6 audio/Speech callbacks that could close the app when scanning starts. Voice permissions and listening are prepared before camera capture. A microphone interruption stops commands with an on-screen fallback while scanning continues. If testing the earlier 1.3, turn off **Hands-free voice commands** in Settings as a temporary diagnostic; spoken guidance is a separate switch. Install the update over the existing app to retain drafts and settings.

## Install from Windows

1. Open [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Choose the latest `solver-app` run where **both** the verify and build jobs passed.
2. Download **GlassesSolver-IPA** under Artifacts and extract the ZIP.
3. Use your working iloader installation to install `GlassesSolver-unsigned.ipa` over the existing app, with the same Apple account/signing identity. Do not delete the existing app first. Its files and OpenAI key should remain when signing/Keychain access is unchanged.
4. Open **Glasses Solver → Auto Scan → Settings**. Choose **OpenAI + Claude** and enter both API keys. Existing OpenAI credentials are preserved. Claude uses a separate Keychain entry. Single-provider modes are available if you have only one key.
5. Save settings. Allow Microphone and Speech Recognition when prompted for hands-free commands. Meta registration/camera permission may also need a one-time approval.

No Mac is needed. GitHub builds an unsigned IPA; iloader signs it on installation. Account provisioning and real-glasses compatibility still require the device test.

## Hands-free batch workflow

1. Open **Auto Scan** and tap **Start scanning pages**.
2. Hold the first paper close enough that small writing is readable. Follow head/camera directions: left/right, tilt up/down, closer/back, then hold still. Capture starts on the first stable usable view, without demanding a clean background or sheet corners.
3. Wait for **“Page 1 saved”**, then turn to the next page. A changed writing region rearms capture. For similar-looking pages, say **“next page”** after turning the page. This also prevents a stationary page from being repeatedly captured.
4. Repeat for the whole packet. Say **“retake last page”** if a capture was wrong. The previous photo stays saved until a clear replacement arrives.
5. Say **“finish scanning”**. Only now are the photos uploaded. The app announces the checklist, solving, comparison and PDF stages. The combined PDF opens automatically.

**“Cancel scanning”** pauses and keeps the draft. On-screen Next/Finish/Pause buttons are available. If English on-device speech is unavailable or permission is denied, the app reports that and provides the Finish button; it does not secretly send microphone audio to a cloud recognizer.

Keep the app visible and iPhone unlocked throughout capture and solving. Auto-lock is temporarily disabled. Backgrounding cancels active work while preserving saved photos. Initial Meta permission handoff is an exception. This version does not promise locked-phone operation. Speech uses iOS's selected route; real glasses microphone/audio routing needs a physical test.

Cues and progress speech default to **5%**, the lowest available nonzero app setting. Settings contains a volume slider and quiet reset. System volume still applies. App speech is excluded from recognition so it cannot finish its own batch.

## Saved pages and imported photos

The ordered queue shows page numbers and thumbnails. Pause before using **Retake**, **Replace photo**, or **Remove** on an individual page. **Add a paper photo** adds an existing Meta AI/photo-library image to the same batch. Imports are collected before solving, just like glasses photos.

Draft originals are saved immediately in the app's `ScanDraft` directory. Errors, pauses and app restarts retain them. If the AI flags unreadable content, its message names the source page; replace that photo and finish again. Retrying the batch repeats its AI work and can incur additional API usage. **New batch** clears the draft after confirmation; finished PDFs remain.

## What the two models do

1. OpenAI inventories every source page and every numbered/lettered subpart, including shared definitions and continuations.
2. Claude audits that checklist against all photos and adds missed subparts.
3. OpenAI and Claude solve each group of up to six subparts independently, with the full packet as context.
4. OpenAI compares both drafts against the photos, recomputes disputed results, and returns one worked solution per required ID.
5. The app rejects missing/duplicate IDs, empty answers, missing work/checks and truncated output. It creates the PDF only after all groups pass. Unresolved mathematical/data uncertainty is visibly marked **NEEDS REVIEW**.

Single-provider mode uses that API for inventory, solving and a separate review. A checklist improves coverage but cannot prove that the models read every symbol correctly or that a numerical answer is correct. Check the transcriptions and flagged items in the PDF.

## Quality, size and usage limits

- Up to **12 source photos and 60 question subparts** per batch. Larger packets need separate batches.
- No OCR transcription, perspective correction or enhancement. Vision locates writing for guidance. Actual stills are checked for gross blur/darkness/detail. Tiny detected writing requests a closer view instead of timing out into a distant capture. Missing text outlines can still use a stable detail fallback for handwriting/diagrams.
- About 1.5 seconds of steady, readable framing triggers capture; imperfect positioning/no text outline allows a longer 3-second hold. Cues are debounced, with prompt “hold” and periodic reminders. A page has up to three local capture attempts; failed local checks incur no AI requests.
- Full/high standalone Meta photos are requested where supported, with the existing stream-photo fallback for unsupported setup. Stop/receive/resume transitions remain SDK-state driven.
- Full orientation-normalized JPEG originals are retained. API transport copies preserve the whole composition, use at most 2576 pixels on the long edge, and up to 1.5 MB JPEG each. These limits keep the complete batch under request-size limits. There is no automatic crop. The PDF embeds readable source previews; full originals remain alongside it.
- Both mode normally uses **2 + 3 × ceil(subparts / 6)** requests (at most 32). Single-provider mode uses **1 + 2 × ceil(subparts / 6)** (at most 21). Each malformed/truncated/missing-item response can get **one** repair, so worst-case limits double. Authentication, network, refusal, rate-limit and service errors are not blindly retried.
- Every request has a time limit. Long packets and two-model review can take substantially more than a couple of minutes. API credit is billed by each selected provider.
- Only one batch runs at a time. Cancellation invalidates late callbacks and prevents subsequent stages/PDF saves.

## PDFs and credentials

Each finished packet saves `Solution.pdf`, `Solution.json`, `Paper.jpg`, and subsequent `Paper-2.jpg` etc. in **Files → On My iPhone → Glasses Solver → Solutions**. The **PDFs** tab lists results. Each PDF contains a coverage checklist, original labels, source-page references, worked calculations, answers, checks, review flags and all source photographs. Math uses Unicode/plain text rather than a LaTeX typesetting engine. Older solutions remain readable.

Keys are stored in separate, device-only Keychain accounts and are sent only in authentication headers to their corresponding API. Never put keys in GitHub or chat. Both mode sends the packet and draft answers to both services; neither key is shared with the other provider. Preview analysis and speech recognition stay on device. OpenAI requests set `store: false`; that is not a guarantee about all provider retention.

Default Claude model: `claude-sonnet-5-5`, with an Opus 5.5 preset and editable model IDs. OpenAI retains the existing `solverModel` preference, defaulting to `gpt-5.4`. Availability depends on your provider account.

## Verification

GitHub Actions compiles a Release iPhone IPA and runs `AutoScanTests` on the iOS simulator, including the real Meta mock-device camera transition. Fixtures cover clarity/stability, close-up gating, page-turn latching, voice parsing/default volume, actual production callbacks invoked on a background thread, cancelled/stale permission prompts and ordered camera/voice startup, batch finish behavior, ordered draft persistence, cancellation, both API envelopes, credential separation, bounded recovery, complete-answer validation and multi-source PDF pagination.

No paid live API keys or physical glasses/microphone are available in CI. Passing tests are evidence for software behavior, not a claim of hardware/voice recognition accuracy or correct answers to arbitrary papers.

References: [Claude vision and limits](https://platform.claude.com/docs/en/build-with-claude/vision), [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [Claude model IDs](https://platform.claude.com/docs/en/models/overview), [OpenAI vision](https://developers.openai.com/api/docs/guides/images-vision), [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [Apple speech volume](https://developer.apple.com/documentation/avfaudio/avspeechutterance/volume), [Meta camera capture](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/camera-capture/SKILL.md).
