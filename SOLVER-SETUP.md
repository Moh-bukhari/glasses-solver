# Glasses Solver — first device test

This fork adds direct photo analysis and a paginated PDF to Meta's CameraAccess sample. No OCR, crop, or image enhancement. Photos are encoded as JPEG at 95% quality without resizing. PDF uses readable plain-text math (not LaTeX typesetting).

## Windows installation

1. Open this repository's **Actions → Build Glasses Solver IPA**. If GitHub disables workflows for this fork, enable them first. The `solver-app` branch builds on push; subsequent pushes retry it.
2. Open a successful run and download **GlassesSolver-IPA** under Artifacts. Extract the downloaded ZIP to get `GlassesSolver-unsigned.ipa`.
3. Connect your iPhone by USB. In the working iloader installation, import this IPA and sign/install with your Apple account.
4. Trust the developer app and enable iPhone Developer Mode if prompted. Open **Glasses Solver**.

No Apple password or API key belongs in GitHub. The build is unsigned; iloader must sign it. Meta's Wi-Fi entitlements may require an eligible provisioning profile; if signing fails, capture the exact error rather than stripping entitlements blindly. Free signing normally needs periodic refresh. A build passing is not proof that glasses registration works on your account.

## First test: your existing Meta photo

1. Open **Solve photo → Settings**. Enter your own OpenAI API key (API billing is separate from ChatGPT). Default model is `gpt-4.1`; you can enter another image-capable Responses API model available to your account.
2. Choose a clear paper photo already saved from Meta AI.
3. Tap **Solve and create PDF**. Keep the app open while it works.
4. Read the solution and tap **Share / Save PDF**. PDFs are also saved under Files → On My iPhone → Glasses Solver → Solutions.

The key is stored in device-only Keychain, never in the IPA, logs, or repository. Clearing the key field and saving removes it. Only the selected photo is sent, when Solve is tapped, to api.openai.com. `store: false` disables Responses storage; this is not a promise of zero provider retention. This personal-device prototype should use a backend before being distributed to other users.

## Glasses test

Enable Developer Mode in Meta AI for your glasses. In the **Glasses** tab, connect/register through Meta AI, start a session, start Preview, point at a well-lit page and tap the photo shutter. On the captured photo, choose **Solve and create PDF**, then Solve. Meta's sample manages permissions and session errors. You can retake a blurry capture before sending it.

This first version is explicit capture and solve, not continuous or hands-free monitoring. The existing stream-photo API is used; full-resolution standalone capture can be added after the baseline device test. Small math may require holding the page closer. Backgrounding stops the sample's glasses session; keep the app foregrounded during the first test. Network/model speed determines duration; two minutes is not guaranteed.

## Build and verification

GitHub Actions uses macOS 26 / Xcode 26.4 with the sample's pinned Meta SDK 1.0.1. No signing secrets are needed to compile. Local Linux cannot compile UIKit or the binary iOS SDK. Check the actual Actions result before treating an IPA as ready.

Device acceptance: import an equation photo → readable complete PDF; invalid API key → actionable error; cancel → no PDF; long solution → multiple PDF pages; glasses register → preview → photo → solve. AI answers still need checking, especially if a symbol is ambiguous.
