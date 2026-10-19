# Project lessons

- A proposed feature is not an implemented feature. Verify that Auto Scan actually starts capture, submits the still, and presents the PDF without intermediate taps before describing it as available.
- A successful unsigned build proves compilation, not hardware behavior. Report simulator tests separately from glasses tests.
- Read the user's screenshot before prescribing UI steps. If Meta exposes no update action, check the actual Developer Mode state instead of repeating the same menu path.

- Simulator runtime patch versions matter: use a destination actually listed by xcodebuild, not the SDK marketing version.
# Simulator SDK signing

Meta's SDK resolves a keychain access group during initialization. Simulator tests must use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), not `CODE_SIGNING_ALLOWED=NO`. The unsigned device IPA remains appropriate for later signing by iloader. See Meta's diagnosis in facebook/meta-wearables-dat-ios#197.


- A readable problem photo does not need a detected paper rectangle. Never make clean background, all four page corners or a straight-on sheet prerequisites for this workflow. Use preview hints to obtain a still; let AI assess the actual problem.
- Positioning cues must specify the wearer’s camera direction. Debounce changes, say “hold” promptly, and allow reminders; an announcement cooldown must not suppress the first useful direction.
- A nonempty AI response is not evidence that every subpart was solved. Build an inventory of all photographed questions, validate exact coverage, and visibly flag unresolved items before generating a PDF.
- Forgiving framing must not mean accepting tiny distant writing after a timeout. Gate on useful text detail, not paper/background geometry, and keep the original photo.
- Batch capture must wait for explicit completion before uploading, retain ordered pages on failure, and avoid repeatedly photographing the same stationary sheet. Quiet spoken guidance needs its own low default volume and must not trigger its own voice commands.
- A cold simulator's mock video feed may not deliver its first frame within the five-second coordinator-test window. Give the SDK integration check a separate bounded 20-second startup allowance while retaining the actual-frame and full-photo assertions; do not relax app quality checks to fix simulator timing.

- Swift 6 legacy AVAudio/Speech callbacks created inside a MainActor class must be explicitly Sendable even when their bodies only touch a locked helper. Test the actual callback on a background executor; a fake voice service and a successful IPA build cannot catch an executor assertion on the first microphone buffer.
- Permission prompts can outlive cancellation. Guard each asynchronous startup with a unique run identity, not only an active Boolean, and prepare voice permissions before starting capture.
- The default GitHub branch can still be an upstream sample baseline. Keep a canonical app handoff with clear entry links from both branches, and check the active branch before assuming the latest solver code is present. Update the handoff when behavior or verification status changes instead of relying on earlier chat history.

- "Solving forever" was not a deadlock: a strictly sequential chain of non-streaming reasoning requests (inventory, audit, solve, reconcile per group), each re-sending every photo, can take tens of minutes and hit idle timeouts. Budget latency per request round before adding review stages; stream responses, parallelize independent work, and cache finished results so a retry resumes rather than restarts.
- Reasoning/thinking tokens count against output limits. A 16k cap can truncate before any visible output; size limits for reasoning models (OpenAI recommends ≥25k) instead of relying on a repair round.
- A view's `onDisappear` in a TabView fires on every tab switch. Never tie paid background work to view lifetime; stop only the camera there.
- The default `.soloAmbient` audio session is muted by the Silent switch. Cues that must reach the glasses need `.playback`; check the route to keep them off the phone loudspeaker.
- Complete file protection makes draft photos unreadable about ten seconds after the phone locks. Background solving and PDF creation need until-first-unlock protection, or they fail exactly when the user pockets the phone.
- A test that reads a fake's own counter or sends frames inside a timing guard passes vacuously. Assert the model's observable behavior and drive it past the gate it claims to test.
- Two Meta MockDeviceKit pairings in one test process: the second session never delivered preview frames. Keep one mock-glasses session per process and check several behaviors inside it.
- On Ray-Ban Meta, a single touchpad tap and tap-and-hold are reserved by the glasses (pause/resume, stop) and never reach the app. Use double-tap and capture-button presses via Inputs, and keep a non-button path (hand gesture, screen) because Inputs is experimental and may be gated.
- Experimental glasses Inputs did not reach the app on the user's Gen 2 glasses. Primary controls must not depend on an experimental input path; hand gestures are the control surface and buttons are an opt-in.
- Any recovery path that stops the camera forces the wearer to take out the phone. In a hands-free flow, an unreadable page, a solve failure and a middle-page retake must keep (or restart) the glasses camera and offer a gesture to continue, retry, or solve without the page.
- A retake of a page that is not in front of the wearer must wait for the view to change; otherwise the sheet still being held is saved in its place within a second. After fixing an earlier page, automatic page-turn detection would re-add pages that were already scanned, so continue only on an explicit gesture.
- Large handwriting can pass an image-based text-size gate while the printed question in the same frame is 8 px tall. Judge legibility on the small printed lines (a low quantile of OCR line heights), not on the median of everything that looks like text.
- Name things the way the wearer sees them. "Show page 30 again" was useless when every close-up started a new page; the sheet's printed question number is the only name the wearer can act on without the phone.
- When the AI gets several photos of one page, tell it that one blurry photo is not a reason to call the page unreadable: an item is unreadable only if no photo shows it.
- On-device text heuristics cannot tell whether a page is fully solvable, and guessing page boundaries from question numbers mixed up sheets twice. When the wearer can wait a few seconds per page, ask a fast vision model "is everything needed to solve this page readable?" while they are still at that page, and move on only on its answer.
- Put the evidence fields before the verdict in a structured-output schema. Strict JSON output follows key order, and the request sorts keys, so name the fields so they sort evidence-first ("found", "problems", then "readable").
- "Fastest model" is not the same as "fastest answer with images". In October 2026 Claude Haiku 5.5 and GPT-6 Luna were the labeled fast tiers, yet with images at low effort Claude Opus 5.5 answered sooner (Haiku still thinks) and read single values far better. Pick check and solve models from measured vision benchmarks, and use paid speed lanes with an automatic step-down when cost is not a concern.
- The glasses' video stream (720x1280, compressed) is too blurry for small print, while capture-button photos are sharp. When the wearer can press a button per photo, use the glasses' own photos (imported into Photos by Meta AI and picked up with PhotoKit) rather than better frame picking. Measure and show the import delay, since it decides how fast feedback can be.
- When the wearer takes discrete photos, a photo can arrive late or early relative to the spoken feedback. Check each photo against the page before (so a late photo of a finished sheet is not a new page) and hold photos of the next sheet until the open page is clear, instead of assuming photos arrive in page order.
