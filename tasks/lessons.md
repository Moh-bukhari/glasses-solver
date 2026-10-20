# Project lessons

- A proposed feature is not an implemented feature. Verify the current acceptance flow through its real output before describing it as available. Preserve the explicit Finish boundary for uploads; current output is a labeled calculator picture pack with a supplementary PDF.
- A successful unsigned build proves compilation, not hardware behavior. Report simulator tests separately from glasses tests.
- Read the user's screenshot before prescribing UI steps. If Meta exposes no update action, check the actual Developer Mode state instead of repeating the same menu path.

- Simulator runtime patch versions matter: use a destination actually listed by xcodebuild, not the SDK marketing version.
# Simulator SDK signing

Meta's SDK resolves a keychain access group during initialization. Simulator tests must use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), not `CODE_SIGNING_ALLOWED=NO`. The unsigned device IPA remains appropriate for later signing by iloader. See Meta's diagnosis in facebook/meta-wearables-dat-ios#197.


- A readable problem photo does not need a detected paper rectangle. Never make clean background, all four page corners or a straight-on sheet prerequisites for this workflow. Use preview hints to obtain a still; let AI assess the actual problem.
- Positioning cues must specify the wearer’s camera direction. Debounce changes, say “hold” promptly, and allow reminders; an announcement cooldown must not suppress the first useful direction.
- A nonempty AI response is not evidence that every subpart was solved. Build an inventory of all photographed questions, validate exact coverage, and visibly flag unresolved items in their own results while allowing other readable questions to finish.
- The earlier single-photo design gated distant/poor writing. The current user intentionally supplies wide shots, close-ups and poor overlaps: keep decodable photos, make quality advice nonblocking, and combine evidence across the packet. Never treat an unclear individual photo as proof that its question is unrecoverable.
- Batch capture must wait for explicit completion before uploading, retain ordered pages on failure, and avoid repeatedly photographing the same stationary sheet. Quiet spoken guidance needs its own low default volume and must not trigger its own voice commands.
- A cold simulator's mock video feed may not deliver its first frame within the five-second coordinator-test window. Give the SDK integration check a separate bounded 20-second startup allowance while retaining the actual-frame and full-photo assertions; do not remove the actual-frame/full-photo assertions to fix simulator timing.

- Swift 6 legacy AVAudio/Speech callbacks created inside a MainActor class must be explicitly Sendable even when their bodies only touch a locked helper. Test the actual callback on a background executor; a fake voice service and a successful IPA build cannot catch an executor assertion on the first microphone buffer.
- Permission prompts can outlive cancellation. Guard each asynchronous startup with a unique run identity, not only an active Boolean, and prepare voice permissions before starting capture.
- The default GitHub branch can still be an upstream sample baseline. Keep a canonical app handoff with clear entry links from both branches, and check the active branch before assuming the latest solver code is present. Update the handoff when behavior or verification status changes instead of relying on earlier chat history.

- A calculator export must target the native picture area, not scale an A4 PDF down. CG50 pictures use 384 × 192 pixels within the 384 × 216 screen. Repeat each question/subquestion label and Page n/m, wrap/paginate at a readable size, and preserve final lines without clipping.
- Photo numbers are source references, not question identities. Combine complementary/duplicate views, retain all supporting sources and preserve original question labels. If essential data is still unknown, mark that question clearly; neither guess missing data nor stop the rest of the packet.
- A claimed model identifier can be checked against the current official SDK; local knowledge of older model names is not evidence that a newer repository default is invalid. Account access and paid API behavior still need separate verification.
- Keep iloader as the user's working iPhone install route. The unsigned IPA installs the app; the ZIP of G3P pictures is transferred separately to the calculator. Format fixtures, iOS builds, paid API checks and physical-calculator display checks establish different things.
