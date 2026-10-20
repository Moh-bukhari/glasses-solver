# Glasses Solver

A personal iPhone app that turns photos of homework or exam-style question pages into complete worked solutions: a PDF, plus pictures sized for a **Casio fx-CG50** calculator screen. It started as a hands-free scanner for **Ray-Ban Meta Gen 2** glasses, built on Meta's Wearables Device Access Toolkit (this repository is a fork of Meta's SDK samples).

> **AI agents: read this page, then [AI-HANDOFF.md](AI-HANDOFF.md) (full operating guide), [SOLVER-SETUP.md](SOLVER-SETUP.md) (what the user does) and [tasks/lessons.md](tasks/lessons.md) (mistakes not to repeat).** Everything needed to continue is in the repository; no chat history is required.

## Where the code is

| What | Where |
| --- | --- |
| Active branch | [`claude/pensive-allen-ggkllj`](https://github.com/Moh-bukhari/glasses-solver/tree/claude/pensive-allen-ggkllj) (all 2.x work). `solver-app` holds 1.x; `main` is Meta's upstream sample plus pointers. |
| The app | [`samples/CameraAccess`](samples/CameraAccess) (Xcode project `CameraAccess.xcodeproj`, app name "Glasses Solver"). Everything else under `samples/` is Meta's untouched sample code. |
| App logic | [`samples/CameraAccess/CameraAccess/Solver/`](samples/CameraAccess/CameraAccess/Solver) |
| Tests | [`samples/CameraAccess/CameraAccessTests/`](samples/CameraAccess/CameraAccessTests) |
| Build and IPA | [`.github/workflows/build-solver.yml`](.github/workflows/build-solver.yml): run it manually on the active branch; it runs the simulator tests and produces an unsigned `GlassesSolver-IPA` artifact |

## What the app does now (2.7)

1. **Import.** The user picks the clearest photo of each question page from Photos, in order (`AutoScanModel.importPhotos`). Each photo becomes a page in a draft that survives restarts (`ScanDraftStore`).
2. **Solve with both AIs.** Each page is sent with its previous and next page as context. Claude Opus 5.5 and GPT-6 Astra each solve it, then Claude reconciles both drafts against the photo (`PageSolver`, `SolverConfiguration` mode `.both`; one provider if only one key is saved). Answers are strict JSON with a checklist of every visible question label, validated before they are accepted. Unresolved items are marked NEEDS REVIEW.
3. **Output: one folder per packet**, in Files › On My iPhone › Glasses Solver › Solutions › `<date time title>`:
   - `Solutions.pdf`: every worked solution with typeset math, plus the source photos.
   - Calculator pictures: every solution rendered as fx-CG50 `.g3p` pictures (384x216), split across as many screens as needed so nothing needs zooming, plus an answers summary. Copy them to the calculator over USB.
4. **Optional glasses scanning** (2.0 to 2.6, still in the app): hands-free capture with Ray-Ban Meta glasses, either the live video stream or capture-button photos imported by Meta AI, with an AI check that each page is readable before moving on. The user found the video too blurry and Meta AI's auto-import unreliable, so manual import is now the main path.

## Architecture in one picture

```
Photos picker / glasses ──> AutoScanModel (pages, draft, state machine)
                              │
                              ├─ PageChecker      (glasses modes only: "is this page readable?")
                              ├─ PageSolver       (per page: Claude + OpenAI drafts -> Claude reconciles; retries, repair, speed lanes)
                              │     └─ SolverClient (HTTP + streaming for both providers, strict JSON schemas, prompts)
                              ├─ PagePlan.combine (merge pages, drop repeats, coverage summary)
                              └─ SolutionStore    (folder per packet: PDF via SolutionPDF/MathText, calculator pictures)
```

Key files (all under `samples/CameraAccess/CameraAccess/`):

| File | Role |
| --- | --- |
| `Solver/AutoScanModel.swift` | The coordinator: import, glasses scanning, page checks, solve jobs, finishing, saving |
| `Solver/AutoScanView.swift` | Main screen (photo picker, Solve, page queue), PDF list |
| `Solver/PageSolver.swift` | Page jobs, cross-check solving, page checks, result validation, combining pages |
| `Solver/BatchSolver.swift` | Provider configuration and models, request bodies, prompts and schemas, streaming parser, speed lanes |
| `Solver/SolverService.swift` | Packet folder, PDF rendering |
| `Solver/MathText.swift` | LaTeX in answers: typeset for the PDF (SwiftMath), plain Unicode fallback |
| `Solver/ScanDraft.swift` | The page draft on disk |
| `Solver/ButtonPhotos.swift`, `PhotoLibraryInbox.swift` | Capture-button photos from the photo library (2.6) |
| `Solver/AutoScanCamera.swift`, `FrameCapture.swift`, `ScanQuality.swift`, `HandGestures.swift`, `ScanVoice.swift` | Glasses camera stream, frame selection, on-device image checks, hand gestures, spoken cues |
| `Views/SolverView.swift` | Settings, API keys (Keychain), settings migrations |

## Build, test, install

- There is no Mac in the loop. CI (`build-solver.yml`, macOS 26, Xcode 26.4, Swift 6) builds the app, runs the simulator tests (`AutoScanTests`, `PageSolvingTests`, `HandGestureTests`, `GlassesInputTests`, `FrameCaptureTests`, `MathTextTests` and newer suites listed in the workflow), and uploads `GlassesSolver-IPA`.
- The user installs the unsigned IPA from Windows with **iloader**, over the existing app so keys and drafts are kept.
- API keys (Anthropic and OpenAI) are entered in the app's Settings and stored in the iPhone Keychain. Never put keys, Apple credentials or personal photos in the repository, docs or logs.
- Live API calls, the physical glasses and the calculator are only tested by the user on their devices. CI uses fake AI answers.

## Status and what is unverified

See the snapshot at the top of [AI-HANDOFF.md](AI-HANDOFF.md) for the exact commit, CI run and artifact of the latest build, and its "Next priorities" for open device checks (live API accuracy and latency, calculator pictures on a real fx-CG50, glasses features).

## Version history (short)

| Version | Change |
| --- | --- |
| 1.x | Phone photos of pages, one combined OpenAI + Claude review, one PDF |
| 2.0-2.1 | Hands-free glasses scanning with hand gestures, per-page streaming solving, start shortcut |
| 2.2-2.3 | Live multi-frame capture from the glasses video, typeset math in the PDF |
| 2.4-2.5 | AI check of each page before the next; best models (Claude Opus 5.5, GPT-6 Astra) with paid speed lanes |
| 2.6 | Capture-button photos imported by Meta AI; one folder per packet |
| 2.7 | Manual photo import, both AIs on every page, fx-CG50 calculator pictures |

---

## Upstream Meta SDK documentation

# Meta Wearables Device Access Toolkit for iOS

[![Swift Package](https://img.shields.io/badge/Swift_Package-1.0.1-brightgreen?logo=swift&logoColor=white)](https://github.com/facebook/meta-wearables-dat-ios/tags)
[![Docs](https://img.shields.io/badge/API_Reference-latest-blue?logo=meta)](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/latest)

The Meta Wearables Device Access Toolkit enables developers to utilize Meta's AI glasses to build hands-free wearable experiences into their mobile applications.
By integrating this SDK, developers can reliably connect to Meta's AI glasses and leverage capabilities like video and audio streaming and photo capture.

The Wearables Device Access Toolkit is in developer preview.
Developers can access our SDK and documentation, test on supported AI glasses, and create organizations and release channels to share with test users.

## Documentation & Community

Find our full [developer documentation](https://wearables.developer.meta.com/docs/develop/) on the Wearables Developer Center.

You can find an overview of the Wearables Developer Center [here](https://wearables.developer.meta.com/).
Create an account to stay informed of all updates, report bugs and register your organization.
Set up a project and release channel to share your integration with test users.

For help, discussion about best practices or to suggest feature ideas visit our [discussions forum](https://github.com/facebook/meta-wearables-dat-ios/discussions).

See the [changelog](CHANGELOG.md) for the latest updates.

## Including the SDK in your project

The Wearables Device Access Toolkit is distributed as a [Swift Package](https://developer.apple.com/documentation/xcode/swift-packages).

1. In Xcode, select **File** > **Add Package Dependencies...**
1. Search for `https://github.com/facebook/meta-wearables-dat-ios` in the top right corner
1. Select `meta-wearables-dat-ios`
1. Set the version to one of the [available versions](https://github.com/facebook/meta-wearables-dat-ios/tags)
1. Click **Add Package**
1. Select the target to which you want to add the packages
1. Click **Add Package**

## Developer Terms

- By using the Wearables Device Access Toolkit, you agree to our [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms),
  including our [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy).
- By enabling Meta integrations, including through this SDK, Meta may collect information about how users' Meta devices communicate with your app.
  Meta will use this information collected in accordance with our [Privacy Policy](https://www.meta.com/legal/privacy-policy/).
- You may limit Meta's access to data from users' devices by following the instructions below.

### Opting out of data collection

To configure analytics settings in your Meta Wearables DAT iOS app, you can modify your app's `Info.plist` file using either of these two methods:

**Method 1:** Using Xcode (Recommended)

1. In Xcode, select your app target in the **Project** navigator
1. Go to the **Info** tab
1. Navigate to **Custom iOS Target Properties**  and find the `MWDAT` key
1. Add a new key under `MWDAT` called `Analytics` of type `Dictionary`
1. Add a new key to the `Analytics` dictionary called `OptOut` of type `Boolean` and set the value to `YES`

**Method 2:** Direct XML editing

Add or modify the following in your `Info.plist` file.

```XML
<key>MWDAT</key>
<dict>
    <key>Analytics</key>
    <dict>
        <key>OptOut</key>
        <true/>
    </dict>
</dict>
```

**Default behavior:** If the `OptOut` key is missing or set to `NO`/`<false/>`, analytics are enabled
(i.e., you are **not** opting out). Set to `YES`/`<true/>` to disable data collection.

**Note:** In other words, this setting controls whether or not you're opting out of analytics:

- `YES`/`<true/>` = Opt out (analytics **disabled**)
- `NO`/`<false/>` = Opt in (analytics **enabled**)

### Crash reporting

The Wearables Device Access Toolkit can capture crashes originating from SDK code, store them locally,
and chain with any existing crash handler your app installs. Crash reporting is **enabled by default**.

To opt out, add a `CrashReporting` dictionary with an `OptOut` boolean set to `true` under the `MWDAT`
key in your app's `Info.plist`:

```XML
<key>MWDAT</key>
<dict>
    <key>CrashReporting</key>
    <dict>
        <key>OptOut</key>
        <true/>
    </dict>
</dict>
```

**Default behavior:** If the `OptOut` key is missing or set to `NO`/`<false/>`, crash reporting is
**enabled**. Set it to `YES`/`<true/>` to disable SDK crash capture.

## AI-Assisted Development

This repository ships one public DAT knowledge base as a single plugin, plus file-based artifacts for the tools that do not use plugins:

| Tool | Public artifact | Recommended setup |
|------|-----------------|-------------------|
| [Muse Code](https://developer.meta.com/ai/products/muse-code/), [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex | `plugins/mwdat-ios/` | Add this GitHub repo as a marketplace, then install `mwdat-ios` |
| [GitHub Copilot](https://github.com/features/copilot) | `.github/copilot-instructions.md` | Auto-loaded by Copilot in VS Code |
| [Cursor](https://cursor.sh/) | `.cursor/rules/*.mdc` | Auto-loaded with glob-based triggers |
| AGENTS.md-compatible tools | `AGENTS.md` | Portable fallback for agents that read `AGENTS.md` |
| MCP-compatible editors | `https://mcp.developer.meta.com/wearables` | Connect as a remote HTTP MCP server; no authentication required |

Muse Code, Claude Code, and Codex install from the plugin payload under `plugins/`. Copilot, Cursor, and `AGENTS.md` readers use the native file-based artifacts at repo root.

### Muse Code

```bash
muse plugins marketplace add mwdat-ios-marketplace https://github.com/facebook/meta-wearables-dat-ios
muse plugins install mwdat-ios@mwdat-ios-marketplace
muse plugins approve mwdat-ios
```

Or use the helper script:

```bash
./install-skills.sh muse
```

Muse Code also reads `AGENTS.md` from your project root with no setup at all.

### Claude Code

```bash
claude plugin marketplace add facebook/meta-wearables-dat-ios
claude plugin install mwdat-ios@mwdat-ios-marketplace
```

Or use the helper script:

```bash
./install-skills.sh claude
```

### Codex

```bash
codex plugin marketplace add facebook/meta-wearables-dat-ios
codex plugin add mwdat-ios@mwdat-ios-marketplace
```

Or use the helper script:

```bash
./install-skills.sh codex
```

### Other tool installs

Use the installer when you want the repo-native file surfaces for other tools:

```bash
./install-skills.sh copilot   # .github/copilot-instructions.md
./install-skills.sh cursor    # .cursor/rules/*.mdc
./install-skills.sh agents    # AGENTS.md
./install-skills.sh all       # Muse/Claude/Codex when available, plus Copilot/Cursor/AGENTS.md
```

Or run the helper remotely:

```bash
curl -sL https://raw.githubusercontent.com/facebook/meta-wearables-dat-ios/main/install-skills.sh | bash
```

### What's included

- **Getting started** — SDK setup, SPM integration, Info.plist configuration
- **Camera streaming** — Stream video frames and capture photos while video is active
- **Audio streaming** — Receive synchronized PCM audio through Camera Stream (experimental; unavailable for production publishing)
- **Camera capture** — Capture standalone high-quality photos with progress and typed errors (experimental; unavailable for production publishing)
- **Display** — Use Display features on the Meta Ray-Ban Display glasses
- **Inputs** — Receive navigation, button, capture, and drag interactions from glasses
- **Motion** — Stream accelerometer, gyroscope, magnetometer, and orientation samples with explicit lifecycle control
- **Speech** — Recognize on-device speech, handle partial/final results, and test with MockDeviceKit
- **Voice Invocations** — Launch or activate an app from Hey Meta and acknowledge each action
- **MockDevice testing** — Test without physical glasses using MockDeviceKit
- **Session lifecycle** — Device session states, pause/resume, availability
- **Permissions & registration** — App registration, camera permission flows
- **Debugging** — Common issues, Developer Mode, version compatibility
- **Live debugging MCP** — Read-only runtime diagnosis from app-visible DAT events
- **DAT docs MCP** — Connect the hosted docs MCP server and search with `search_dat_docs`
- **Sample app guide** — Building a complete DAT app

For static reference context, point your AI tool at the [llms.txt endpoint](https://wearables.developer.meta.com/llms.txt?full=true). Installing the plugin registers `https://mcp.developer.meta.com/wearables` for live documentation search in Muse Code, Claude Code, and Codex. Other MCP-compatible editors can connect to that endpoint directly and use `search_dat_docs`. The public docs MCP server does not require authentication; do not configure tokens, OAuth, or custom authorization headers for it.

## License

See the [LICENSE](LICENSE) file.
