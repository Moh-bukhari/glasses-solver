# Glasses Solver 1.4 — photo packet to CG50 pictures

This update changes the solver to **Claude only** and adds a calculator picture pack. It combines wide shots, close-ups and repeated views of the same questions. A poor photo no longer blocks the other questions. Project version is 1.4 build 6. [The iOS verification and Release build passed](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336) for app commit `806db51`. [Download the IPA ZIP](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336/artifacts/12238381045); the older 1.3.1 installer does not include these changes.

## Install with iloader

1. Open [the verified build for this update](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336). Both its verify and build jobs passed. For later builds, select the run matching the intended app commit.
2. Download **GlassesSolver-IPA** under Artifacts and extract the ZIP.
3. Use your existing iloader installation to install `GlassesSolver-unsigned.ipa` over the existing app, with the same Apple account/signing identity. Keeping the app installed preserves its drafts and credentials when the signing/Keychain access remains unchanged.
4. Open **Glasses Solver → Auto Scan → Settings**, enter your **Anthropic API key**, and save. The default is **Claude Sonnet 5.5** (`claude-sonnet-5-5`); the model field is editable if your account needs a different compatible vision model. Existing OpenAI credentials remain stored but this workflow does not use them.
5. Allow Microphone and Speech Recognition if you want hands-free commands. Complete Meta registration/camera permission when requested.

GitHub's macOS runner builds the unsigned iPhone app; iloader signs it for your phone. You do not need to build with a Mac yourself. The calculator picture pack described below is a separate output from the iPhone installer.

## Collect all the views, then solve

1. Choose **Add paper photos** to select several existing photos, or **Start scanning pages** to capture from the glasses.
2. Mix wide views showing question numbers and shared diagrams with close-ups of small writing. Capture order does not have to match question order. Blurry, distant and clipped views stay in the packet so Claude can use the useful details from other views.
3. Automatic capture waits for a steady view. Framing/lighting cues are advice; **Capture this view** takes a photo immediately while collecting. Use **Next page** or say **“next page”** to rearm capture when similar views are not detected automatically.
4. Add up to **24 photos**. Use Retake, Replace photo or Remove after pausing when needed. The old photo stays saved until its replacement is stored.
5. Tap **Finish scanning** or say **“finish scanning”**. Only then are the saved photos uploaded to Claude. The app organizes questions, solves them and opens the calculator picture results.

Claude combines overlapping evidence and produces one result for each identified question or subquestion, preserving its label. It uses the clearest available details instead of requiring a single perfect photo. If a particular symbol, diagram value or question is still impossible to recover, that item gets a labeled **NEEDS REVIEW** picture; the readable questions still finish. If no question can be identified, the output says which source photos are unreadable rather than inventing questions or answers.

**“Cancel scanning”** pauses collection and keeps the draft. Keep the app open and the phone unlocked while capturing or solving. Backgrounding pauses active work and retains saved photos; initial Meta permission handoff is an exception. Touch controls work when on-device English speech recognition is unavailable. Cues default to **5%** app speech volume; hardware volume still applies.

## Use the calculator pictures

The exported `.g3p` pictures use the CG50's **384 × 192** picture area within its 384 × 216 display. Each picture repeats the original question/subquestion label and **Page n/m** for that item. Separate subquestions start on separate pictures. Long answers wrap onto more pictures instead of shrinking the text.

The pictures contain short student calculation lines and final answers with units. They omit teaching explanations, full question transcriptions and verification prose. A review note is included when essential information is missing or a result is uncertain.

Share `Calculator-G3P.zip` from the result viewer, save it to your computer, and extract it. Copy the `.g3p` files to your calculator's storage using its USB storage connection, then open them through its picture-compatible app. `INDEX.TXT` maps short filenames such as `Q001P001.g3p` to original question labels and page numbers. PNG previews on the phone show the actual exported picture layout. Physical display/import compatibility still needs confirmation on the user's calculator.

Files are also saved in **Files → On My iPhone → Glasses Solver → Solutions**, with the ZIP in the result folder and individual G3P/PNG pictures in its `Calculator` subfolder. The **Solutions** tab retains completed results. A supplementary PDF includes the source photos, transcriptions, calculations, checks and review notes. Older PDF-only results remain readable.

## Saved work, limits and credentials

- Draft photos are saved locally in `Documents/ScanDraft` and survive errors, pauses and app restarts. **New batch** clears that draft after confirmation; finished solutions remain.
- Up to **24 source photos and 60 identified question subparts** per packet. Corrupt image files, storage failures, API authentication and service failures can still need action; these are distinct from photo quality. Multi-photo import continues past a file that cannot be loaded or saved and identifies it in the import summary.
- Original orientation-normalized JPEGs are kept. Upload copies preserve the whole composition, start at a maximum 2000-pixel long edge, and adapt size/quality to stay at or below 750 KB each. There is no automatic perspective correction or crop. The local decoder allows photos up to 60 megapixels and prepared JPEGs below 20 MB.
- Claude makes one organization request, then one solve request per group of up to six recoverable subparts, with at most two groups in flight. A normal packet uses `1 + ceil(recoverable subparts / 6)` requests, at most 11. Unrecoverable items get local review cards after inventory.
- Each malformed/incomplete response has at most one structural repair. Transient transport/HTTP failures have at most two retries per request with bounded delays. Authentication failures/refusals are not blindly retried. Larger packets can take longer; no fixed completion time is promised. Retrying a complete batch repeats paid API work.
- The Anthropic key remains in the device-only iPhone Keychain and is sent only to Anthropic in an authentication header. Do not put keys in chat or GitHub. Local preview analysis and voice recognition stay on device. The Meta SDK has separate device communications; the Finish boundary applies to solver photo uploads.

## Verification status

The macOS workflow runs `AutoScanTests`, `ClaudePipelineTests` and `CalculatorExportTests`, then builds a Release IPA only after verification succeeds. These fixtures exercise photo retention, explicit Finish, cancellation, overlapping-source inventory, incomplete-question output, Claude request handling and calculator format/layout. Current local Swift 6.3 checks verified G3P headers/pixels/checksums and ZIP CRCs through an independent decoder, including a byte-for-byte reference white picture. The production Claude pipeline also passed 12 portable Swift runtime checks with prepared photo fixtures. The selected iOS suites and Release build passed in [run #41](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336), tied to app commit `806db51`. Exact current test counts were not inspected from the result archive.

The historical **41 AutoScanTests passed** result belongs to **1.3.1**, before this calculator update. Current checks and release artifacts must be tied to the current commit. Paid Claude calls, physical glasses/microphone behavior and actual CG50 picture import/display are separate acceptance checks and must not be described as verified from fixtures alone.

References: [Claude vision](https://platform.claude.com/docs/en/build-with-claude/vision), [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [official SDK model IDs](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/model.py), [Meta camera capture](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/camera-capture/SKILL.md).
