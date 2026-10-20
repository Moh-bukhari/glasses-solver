# Glasses Solver: AI handoff and operating guide

Start here when continuing this project. The latest user request supersedes earlier PDF-only, strict-quality and two-provider requirements.

**Snapshot updated:** 2026-10-19 America/Los_Angeles. **Current work:** Claude photo organization and CG50 G3P export on `codex/claude-calculator-export`, based on `solver-app`. **Project version:** 1.4 build 6. **Verified app commit:** `806db51ff28ffcb02deb1b72c0be636fcf6725a9`. [The iOS verification and Release build passed](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336); [the unsigned IPA ZIP is available](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336/artifacts/12238381045) for the existing iloader route. Live Claude calls, physical glasses and actual CG50 display/import remain unverified. Later documentation commits do not imply a new app build.

## 1. Find the active app

| Item | Location / purpose |
| --- | --- |
| Active app base | [`solver-app`](https://github.com/Moh-bukhari/glasses-solver/tree/solver-app), `samples/CameraAccess` |
| Current calculator work | `codex/claude-calculator-export`; inspect local/remote state rather than assuming it was merged |
| Default branch | `main` contains the upstream sample baseline and routing pointers |
| User instructions | [SOLVER-SETUP.md](SOLVER-SETUP.md) |
| Agent/SDK instructions | [AGENTS.md](AGENTS.md) |
| Current acceptance contract | [tasks/calculator-packet-spec.md](tasks/calculator-packet-spec.md) |
| Lessons | [tasks/lessons.md](tasks/lessons.md) |
| Prior scan/voice contracts | [tasks/batch-solver-spec.md](tasks/batch-solver-spec.md), [tasks/scan-start-crash-spec.md](tasks/scan-start-crash-spec.md); calculator requirements supersede conflicting quality/provider/output rules |
| Existing draft PR | [PR #1](https://github.com/Moh-bukhari/glasses-solver/pull/1); check its state, do not merge incidentally |

Inspect `git status --short`, `git branch --show-current` and recent commits before changes. Use the existing isolated cloud checkout; create no worktree unless the user requests one. Preserve unrelated local work. The upstream `BirdSpotter` and `DisplayAccess` samples are not the solver target.

## 2. Current product goal

The user uses an iPhone, a Windows laptop, Ray-Ban Meta glasses and **iloader** to install unsigned IPA builds. The new output target is the user's **Casio CG50-series calculator**. There is no separate Windows/Pi server or hosted solver backend: the phone coordinates capture, calls Claude and renders calculator images locally.

The user deliberately collects a mixture of good and poor photos, close-ups, wider views and overlaps. They want the app to organize that evidence and produce short student calculations/results, with no teaching explanations, on calculator-sized pictures. Keep these requirements:

- A photo is evidence, not necessarily a distinct paper page. Merge overlapping views of the same question; use wide views for labels/context and close-ups for details.
- Quality checks provide guidance. A decodable blurred, distant or clipped photo does not abort import, capture or the entire solve. A missing detail in one view may be visible elsewhere.
- Never invent unreadable symbols or data. An unrecoverable question gets a labeled review result while the others finish. If no question can be identified, label the source photo honestly instead of fabricating a question number.
- Use **Claude only** for this workflow, including for users whose old saved provider mode was OpenAI or both. Preserve existing stored credentials, but do not require or send an OpenAI key.
- Each question/subquestion starts on a separate calculator picture. Every picture repeats its question label and `Page n/m`; long content gets more pictures at the same readable text size.
- Show essential calculation lines and final answers with units. Omit teaching prose, full question transcription and verification prose from calculator images. Keep checks/transcriptions available in the supplementary PDF/JSON.
- Wait for explicit Finish before solver uploads. Preserve ordered originals, atomic replacements, cancellation/run IDs, quiet cues and retained drafts.
- Keep the user's iloader installation route. A G3P ZIP is calculator content, separate from the iPhone IPA.

## 3. Evidence and release status

The implementation includes tolerant collection, Claude-only organization/solving and calculator export changes. [Workflow run #41](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336) completed successfully for `806db51ff28ffcb02deb1b72c0be636fcf6725a9`: the selected iOS verification job passed, followed by the Release IPA build. The selected suites are `AutoScanTests`, `ClaudePipelineTests` and `CalculatorExportTests`. Both job conclusions and artifact metadata were read from GitHub. Exact test counts and the downloaded xcresult/IPA internals were not inspected because GitHub API access was blocked; do not invent those details. The IPA artifact is **GlassesSolver-IPA**, 12.1 MB, ID `12238381045`, with GitHub-reported SHA-256 `dbda4c82cc6b93d00edc780de12ed7eb555f6a8f44adebffb04e228e9bafa722`.

Historical evidence for **1.3.1 only**: [successful build/test run](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39185371000), **41 AutoScanTests passed, 0 failures**, and [IPA ZIP artifact](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39185371000/artifacts/12157971958). Artifact access can require login and artifacts can expire. This release patched unsafe Swift 6 audio/Speech callbacks and stale startup races after the user reported a scan-start exit; the exact physical-device cause remained unconfirmed without a crash report.

Current local evidence: the production portable G3P codec compiled with Swift 6.3. Three pixel fixtures passed independent decoding with header/dimension, Adler-32 and ZIP CRC checks; the white-image output matched a known reference G3P byte-for-byte. These checks cover format/transport, not UIKit text layout. The production Claude pipeline and shared result models also passed **12 portable Swift 6.3 runtime checks**, compiled with warnings as errors. Those fixtures inject prepared photo bytes and do not exercise ImageIO preprocessing. The matching macOS verification and Release build also passed as recorded above. Paid Claude behavior, physical glasses/microphone use and actual CG50 import/display require their own evidence. A reference-decoder check does not replace a calculator test.

## 4. User workflow

### Install and configure

For this update, use [the verified IPA artifact](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336/artifacts/12238381045) from [run #41](https://github.com/Moh-bukhari/glasses-solver/actions/runs/39362935336). For later changes, select the matching commit in [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Both verify and build jobs must pass. Extract **GlassesSolver-IPA**, then install `GlassesSolver-unsigned.ipa` through the user's existing iloader setup over the old app with the same signing identity. Preserve bundle ID **`com.mohbukhari.glassessolver`** and Keychain accounts to retain user data.

Enter the Anthropic key in Auto Scan settings. Default model `claude-sonnet-5-5` is listed in the current official Anthropic Python SDK; that verifies the model identifier, not account access. The model field stays editable. OpenAI keys/preferences are retained for compatibility but the current solver always chooses Claude.

### Collect, organize and export

1. Select several images with **Add paper photos**, or use **Start scanning pages** for glasses capture.
2. Add wide views, close-ups and overlaps in any order, up to 24 photos. Automatic capture waits for stability. **Capture this view** bypasses framing advice; Next page rearms similar-looking views.
3. Pause to replace/remove individual photos. Replacement writes the new file/manifest before deleting the old image. Imported files load sequentially to limit memory; an unreadable file/storage failure is reported and the remaining selection continues.
4. Tap/say Finish. Claude organizes the entire packet into original question order, combines supporting views and marks only genuinely missing question data.
5. Recoverable subparts are solved in groups. Each identified subpart produces concise answer pictures or an explicit review picture. Results open on the phone; share the G3P ZIP, extract it on a computer and copy `.g3p` files to calculator storage. Consult the included filename index for question/page mapping.

The Solutions tab retains results and supplementary PDFs. New batch clears the current draft after confirmation; it does not delete finished solutions. Retry can repeat paid Claude work, so retain the draft rather than forcing recapture of every view.

### Foreground and voice behavior

Keep the app visible and iPhone unlocked during capture and solving. Auto-lock is temporarily disabled and restored afterward. Backgrounding pauses work and retains photos, except initial connecting/permission handoff. This is not a background/locked-phone service.

Voice uses on-device `en-US` recognition. Permission denial or unavailable recognition leaves touch controls; there is no cloud transcription fallback. Microphone interruption/route change can stop commands while collection remains available. Pause/resume attempts to prepare commands again. Spoken cues and command listening have separate toggles. App speech is excluded from recognition, and utterance volume defaults to 5%; system volume still applies.

## 5. Capture and local photo handling

`AutoScanModel` is the MainActor coordinator with a per-run identity. Old callbacks cannot modify newer work. Phases remain `idle`, `connecting`, `seeking`, `capturing`, `checking`, `awaitingNext`, `solving`, `saving`, `finished`, `failed`. The checking phase now prepares/stores valid images without rejecting them for measured quality. A failure to decode/save a file is separate from a photo whose writing is poor.

`AutoScanCamera` retains Meta SDK session/stream/photo sequencing. Preview is raw/high at 7 fps. Full-photo capture stops Stream, starts Photo, requests full/high capture, waits for transfer and stops Photo. Only unsupported photo setup (`serviceUnavailable` or `sessionSetupFailed`) falls back to stream capture. Keep SDK state waits instead of arbitrary sleeps.

`PageAnalyzer` uses Vision text rectangles/character boxes for positioning advice, not OCR transcription. Temporary crops calculate metrics; submitted originals preserve the full composition. Darkness, blur and text-size estimates are advisory. A failed still framing analysis does not invalidate a successfully decoded photo.

| Setting | Behavior |
| --- | --- |
| Preview analysis | At most once per 0.33 seconds, one analysis task in flight |
| Automatic capture | Stable image fingerprint; around 1.5 seconds for hold, otherwise 3 seconds, at least 5 samples; movement/long gaps reset |
| Distance/quality | May request closer framing or more light; no quality veto on storage/solve |
| Manual capture | Capture this view while seeking/awaiting next, independent of quality advice |
| Next-view gate | At least 2 seconds after saved preview, then 3 changed frames; explicit Next remains available |
| Guidance | Direction debounce, prompt hold, repeated reminders |
| Original preparation | Up to 60 megapixels; orientation-normalized JPEG at 0.95 quality, below 20 MB |

Page-turn detection is visual and limits duplicate automatic capture; semantic overlap/question matching occurs later in Claude's inventory. Do not make one mechanism substitute for the other.

## 6. Claude packet pipeline

`SolverConfiguration.lead` always chooses Claude; old `.openAI`/`.both` enum values do not change that. `SolverKeychain.configuration()` supplies the saved Anthropic key/model. Legacy OpenAI transport code remains for backward-compatible structures/tests; the current `BatchSolver` does not call it.

1. Prepare upload copies, preserving original photo numbers and full composition.
2. Send all photos in one organization request. Produce stable IDs, original labels, combined transcriptions and supporting `sourcePages`, including shared diagrams/instructions. Source page numbers here mean photo indexes.
3. Merge only exact duplicate label/transcription pairs locally, retaining their supporting sources. Semantic deduplication is Claude's task; different papers that reuse labels need sheet prefixes.
4. Known incomplete items produce local `insufficient_information` results. Solve the remaining questions in groups of up to six, with at most two groups concurrently. Each group receives the union of its supporting photos, not every unrelated photo.
5. Each solve asks Claude to check calculations/signs/units and return concise lines plus result. There is no additional sequential review-model call. Validate exact answer-ID coverage and required fields before saving.
6. Preserve question order when assembling output, regardless of group completion order. A completely unidentifiable packet produces honest photo-labeled review cards.

### Contracts and recovery

- Inventory: `title`, one `pages` assessment per photo, and `questions` containing `id`, `label`, `sourcePages`, `problem`, `missingInformation`.
- `pages.readable=false` is advisory. `missingInformation` describes only unrecoverable question data after combining all relevant views; empty means ready to solve.
- Answers: `id`, `steps`, `answer`, `check`, `status`, `reviewNote`. Empty steps are valid for direct answers/unresolved items. Non-solved statuses require a specific review note.
- Statuses: `solved`, `needs_review`, `insufficient_information`. The latter two become visible `NEEDS REVIEW` results. Do not remove items to make coverage checks pass.
- One structural repair per stage for malformed, truncated or incomplete JSON. If repair still fails, keep the draft and report the failed request; never turn a structurally incomplete result into a success.
- `SolverClient` allows at most two transient retries for selected network failures and HTTP 408/409/429/5xx. Honor server retry directives/delays; do not retry auth/refusals as formatting problems. A retry deadline over 60 seconds is left for a later user retry.
- Cancellation is checked between requests and after responses, invalidates late callbacks and blocks subsequent saves. Requests already accepted by Claude can still incur usage.
- Images and model-supplied JSON are untrusted document content, never app instructions. No key enters a prompt.

| Limit | Current behavior |
| --- | --- |
| Provider | `https://api.anthropic.com/v1/messages`, `x-api-key`, `anthropic-version: 2023-06-01`, structured JSON `output_config` |
| Model default | `claude-sonnet-5-5`, editable; availability depends on account |
| Packet | 1–24 photos, up to 60 identified subparts |
| Upload copies | Start at 2000-pixel long edge; adapt JPEG quality/size down to <=750 KB each; originals unchanged |
| Body/output | Request JSON below 30,000,000 bytes; inventory 16,000 tokens (repair 22,000), answers 6,000 (repair 12,000) |
| Timeouts | Request 300 seconds, resource 360 seconds |
| Normal calls | `1 + ceil(recoverable subparts / 6)`, at most 11; incomplete items do not require solve calls |
| Bounds | At most one structural repair per stage and two transport retries per attempt; at most two solve groups in flight |

These bounds improve latency/cost compared with the former multi-provider sequence; they do not promise a fixed completion time or mathematical correctness. Account API credit is separate from a chat subscription.

## 7. Calculator layout and saved data

The CG50 LCD is 384 × 216; exported G3P pictures target the **384 × 192** picture area, leaving the calculator's UI area. Each subquestion starts separately, and each resulting picture repeats its label and `Page n/m` for that subquestion. Text uses 19-pixel body type, 17-pixel bold question headers and a 14-pixel page footer. Long labels/content wrap and paginate rather than shrinking text or silently clipping. The renderer rejects labels too tall to leave a body line and packets beyond 512 pictures with an explicit error instead of truncating. Calculator pages contain compact calculation lines, final results and necessary review flags, with no full problem transcription or verification prose.

Native PNG previews represent the same pixels encoded into G3P. The shared `Calculator-G3P.zip` contains `.g3p` files plus `INDEX.TXT`, which maps short filenames such as `Q001P001.g3p` to original question labels/page numbers. These eight-character stems use export sequence numbers, not a replacement question label. PNG previews are stored beside the G3P files but are not included in the transfer ZIP. Rendering/encoding happens on the iPhone; no image-conversion website or extra server is required. Confirm actual file loading and readability on the user's calculator before claiming hardware compatibility.

The supplementary PDF remains a readable archive of source photos, combined transcriptions, answer/check fields, coverage and review notes. It uses UIKit/CoreText/PDFKit and Unicode/plain-text math, not a LaTeX engine. It retains pagination/heading checks and a 100-page solution-text limit. Old PDF-only history stays accessible.

| Data | Location / behavior |
| --- | --- |
| Ordered draft | `Documents/ScanDraft/pages.json`, UUID array, matching `<UUID>.jpg` |
| Draft writes | Atomic with complete file protection; swap manifest before removing replaced image |
| Finished packet | `Documents/Solutions/<UUID>/Calculator-G3P.zip`; `Calculator/Q001P001.g3p` and matching `.png` previews; plus `Solution.pdf`, `Solution.json`, `Paper.jpg`, `Paper-2.jpg`, etc. |
| Files app | On My iPhone → Glasses Solver → Solutions |
| Claude key | Keychain service `GlassesSolver`, account `Anthropic` |
| Legacy OpenAI key | Same service/account `OpenAI`; retained but unused by current workflow |
| Key accessibility | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Preferences | `claudeModel`, legacy provider/model fields, `voiceCommands`, `voiceGuidance`, `cueVolume` |

Photos go to Claude only after Finish. Local preview analysis and voice recognition do not use a cloud solver. Meta SDK device traffic/telemetry is separate; this app has not added a Meta analytics opt-out configuration. Never log keys or base64 photos.

## 8. Code map

All paths below are relative to `samples/CameraAccess` unless stated otherwise.

| File | Responsibility |
| --- | --- |
| `CameraAccess/CameraAccessApp.swift` | SDK startup/debug mock configuration |
| `CameraAccess/Views/MainAppView.swift` | Auto Scan / Glasses / Solutions tabs |
| `CameraAccess/Views/SolverView.swift` | Keychain, Claude-only settings, import wrapper |
| `CameraAccess/Solver/AutoScanView.swift` | Multi-photo import, queue, capture controls, previews/share/history |
| `CameraAccess/Solver/AutoScanModel.swift` | Coordinator, Finish/cancellation/run IDs, advisory quality, ordered import |
| `CameraAccess/Solver/AutoScanCamera.swift` | Meta session/stream/full-photo lifecycle |
| `CameraAccess/Solver/ScanQuality.swift` | Image metrics/advice, stability, page-turn and speech gates |
| `CameraAccess/Solver/ScanVoice.swift` | On-device speech, Sendable callback bridge, startup identities |
| `CameraAccess/Solver/ScanDraft.swift` | Atomic original-photo queue |
| `CameraAccess/Solver/BatchSolver.swift` | Claude orchestration, schemas, coverage, transport/retry limits |
| `CameraAccess/Solver/SolverModels.swift` | Portable result types and solver error model |
| `CameraAccess/Solver/SolverService.swift` | Persistence and supplementary PDF |
| `CameraAccess/Solver/G3PCodec.swift` | Portable G3P encoding and ZIP container |
| `CameraAccess/Solver/CalculatorExport.swift` | Native-size text layout/pagination, PNG/G3P rendering and filename index |
| `CameraAccess/Info.plist` | Permissions, Meta callback/config and file sharing |
| `CameraAccess.xcodeproj/project.pbxproj` | Version/package pin and explicit production source entries |
| `CameraAccessTests/` | Scanner, voice, Claude pipeline, calculator format/layout fixtures |
| `.github/workflows/build-solver.yml` (repository root) | Simulator verification, Release build, IPA artifacts |
| `tests/portable/run-claude-pipeline.sh` (repository root) | Linux/macOS Swift runtime checks against production pipeline and shared models |

Production Swift files require explicit Xcode source entries. The synchronized `CameraAccessTests` group includes new test files, but the workflow's selected test classes must include them. Preserve Swift 6/MainActor boundaries, listener retention and bounded SDK waits. Use injected seams for focused fixtures, retaining real integration checks where fakes hide failures.

## 9. Build, test and distribute

Project requirements: **Meta SDK exact 1.0.1**, Swift language mode **6.0**, minimum **iOS 17.2**. macOS CI selects **Xcode 26.4**, **iPhone 17 Pro / iOS 26.4.1**. Check `xcodebuild -showdestinations` rather than guessing simulator patch versions.

Use `.github/workflows/build-solver.yml` as the current command source. Run all selected solver/Claude/calculator test classes after changes, not only the historical AutoScan suite. Simulator tests require **ad-hoc signing** because Meta initializes a Keychain access group:

```bash
xcodebuild test \
  -project samples/CameraAccess/CameraAccess.xcodeproj \
  -scheme SolverTests -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4.1' \
  -only-testing:CameraAccessTests/AutoScanTests \
  -only-testing:CameraAccessTests/ClaudePipelineTests \
  -only-testing:CameraAccessTests/CalculatorExportTests \
  -parallel-testing-enabled NO -resultBundlePath TestResults.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 90 \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM=""
```

These selectors run the scanner, Claude-pipeline and calculator-export suites without expanding into unrelated upstream tests. Use a fresh result-bundle path when an old one exists.

```bash
xcodebuild \
  -project samples/CameraAccess/CameraAccess.xcodeproj \
  -scheme CameraAccess -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Pushes affecting app/workflow files on `solver-app` or `codex/**` trigger the workflow; manual dispatch remains available. The build job depends on verify, so an IPA is produced only after the selected tests succeed. The workflow puts `CameraAccess.app` in `Payload/` and zips `GlassesSolver-unsigned.ipa`; iloader handles installation signing. Do not use unsigned-device flags on simulator tests. Check the packaged bundle/version strings for each release.

Artifacts are `GlassesSolver-IPA`, `build-log` and `test-results` (logs, xcresult and attachments). Inspect both job conclusions and actual test counts against the matching commit. A docs-only commit is not a new app validation. Do not overwrite remote work or merge unrelated PRs as part of preparing an installer.

The current cloud machine runs Linux. Portable Swift/zlib checks run there; UIKit rendering and the iOS build need macOS. From the repository root, rerun the production pipeline fixtures with:

```bash
SWIFTC=/path/to/swiftc tests/portable/run-claude-pipeline.sh
```

The pipeline fixtures inject prepared photo bytes. The default Linux image uploader explicitly refuses unsupported preprocessing, so passing this suite is not ImageIO or UIKit evidence. GitHub API requests were blocked at the proxy for `api.github.com`; an allowlist addition was saved for environment review, but that alone does not prove runtime access. Existing GitHub authentication is present; retry access after the network setting changes instead of requesting a duplicate token.

## 10. Troubleshooting and remaining acceptance

| Symptom | Investigation |
| --- | --- |
| App exits on Start | Confirm installed version/build and obtain the crash report/timing. Preserve 1.3.1 Sendable audio callback fixes and stale permission protection. |
| Voice stops after interruption | Touch controls remain. Inspect route notifications and test actual hardware recovery; pause/resume prepares commands again. |
| Poor photo stops whole packet | Trace import preparation, inventory validation and per-question missingInformation. Individual quality must be advisory; corrupt files/auth/structural API failures are different. |
| Duplicate questions | Inspect all-photo inventory, original labels/sheet prefixes and source references. Merge complementary views without combining distinct reused labels. |
| Missing/guessed symbol | Compare retained originals, combined transcription and supporting photos. Preserve question-specific review output; do not fabricate certainty. |
| Long/slow packet | Inspect subpart count, relevant photo selection and bounded retry count; no extra sequential reviewer or unbounded debate. |
| HTTP 400/404 | Check editable model vision/structured-output support and account availability. |
| HTTP 401/403/429 | Check Anthropic key/access or credit/rate limits on device. Honor bounded retry policy; retain draft. |
| G3P rejected/unclear | Inspect binary header/format, actual 384 × 192 pixels, native-size typography, question labels/page totals and transfer method. Keep physical-device evidence separate from reference decoding. |
| Simulator Keychain failure | Match runtime and retain ad-hoc signing. |
| Capture transition failure | Preserve SDK session/stream/photo state sequencing and inspect typed error rather than adding arbitrary sleeps. |

Before a release claim: run current simulator suites plus Release build; inspect a mixed packet with overlapping/poor views and known answers through real Claude; load G3P files on the calculator; inspect native-size text, long labels, multiple pages and final calculations; verify iloader upgrade retains existing drafts/keys; exercise pause/restore and physical glasses/voice behavior. Record exact evidence and any unrun checks.

## 11. Maintaining this handoff

Read current requirements, code and acceptance contract first. Update this guide and SOLVER-SETUP whenever behavior, file layout, limits or operating commands change. Keep historical evidence clearly attributed to its old commit. Record lessons from incorrect assumptions without turning superseded preferences into permanent constraints. Preserve keys/personal images in their existing secure/local stores and keep them out of source, logs and chat. Leave a direct matching installer link only after a real successful build; never infer release readiness from static checks.

G3P format reference: [CasPCE](https://github.com/mdanishharoon/CasPCE), corroborated with [img2calc](https://github.com/TI-Planet/img2calc) and a reference picture from [utilities](https://github.com/gbl08ma/utilities). The codec writes a 384 × 192 RGB565 picture with the G3P header/obfuscation and raw-DEFLATE/Adler-32 payload. Preserve the upstream license notice bundled with the implementation.

Primary references: [Meta developer docs](https://wearables.developer.meta.com/docs/develop/), [bundled Meta skills](plugins/mwdat-ios/skills), [Apple callback-isolation diagnosis](https://developer.apple.com/forums/thread/793455), [Claude vision](https://platform.claude.com/docs/en/build-with-claude/vision), [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [official Claude model IDs](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/model.py).

Large packets use file-backed source Data where supported and decode reference PDF photos one at a time inside an autorelease pool. The selected photo-library items also load sequentially. UIKit memory behavior still requires device validation.
