# Project lessons

- A proposed feature is not an implemented feature. Verify that Auto Scan actually starts capture, submits the still, and presents the PDF without intermediate taps before describing it as available.
- A successful unsigned build proves compilation, not hardware behavior. Report simulator tests separately from glasses tests.
- Read the user's screenshot before prescribing UI steps. If Meta exposes no update action, check the actual Developer Mode state instead of repeating the same menu path.

- Simulator runtime patch versions matter: use a destination actually listed by xcodebuild, not the SDK marketing version.
# Simulator SDK signing

Meta's SDK resolves a keychain access group during initialization. Simulator tests must use ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), not `CODE_SIGNING_ALLOWED=NO`. The unsigned device IPA remains appropriate for later signing by iloader. See Meta's diagnosis in facebook/meta-wearables-dat-ios#197.

