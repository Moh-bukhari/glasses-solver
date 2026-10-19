# Scan-start crash patch (1.3.1)

## Evidence and scope

The user reports an immediate exit every time scanning starts after 1.3. No device crash report is available. The new voice listener creates AVAudioEngine and Speech callbacks inside a MainActor class without Sendable annotations. Apple documents this exact pattern causing a Swift 6 executor assertion on the first audio buffer: https://developer.apple.com/forums/thread/793455. Treat it as a concrete defect and likely cause, not a hardware-confirmed diagnosis.

The previous tests replaced ScanVoice entirely with a no-op fake. They could not detect this crash. Permission continuations also only checked a Boolean: stopping and restarting during a prompt could revive an old startup and install a second tap.

## Changes

- Make audio, recognition, and permission callbacks explicitly Sendable. Consume PCM buffers on the audio callback thread under the existing feed lock; transfer only text/Boolean values to MainActor.
- Give each listener startup a unique identity, invalidate it on stop, and check cancellation after both permission prompts. Ignore callbacks from earlier runs.
- Create a fresh engine after the audio session is active. Validate microphone input and let the tap use the node's native format instead of applying a potentially stale Bluetooth format.
- Stop the listener on engine reconfiguration, interruption, or media reset. Keep the scanner and spoken cues available and show a clear on-screen fallback. Do not repeatedly restart unstable audio hardware.
- Prepare the listener before starting the glasses camera and announcing readiness. Finish permissions while connecting; no capture is allowed while prompts are pending. Stop old speech on every new run.
- Preserve voice commands on by default, 5% spoken cue volume, saved pages, batch solving, API keys, and PDF behavior. Version 1.3.1, build 5, same bundle identifier.

## Verification

Execute the actual production audio/recognition callbacks from a background executor (not a FakeScanVoice). Test stop/restart and task cancellation while permission prompts are outstanding, and verify that camera startup waits for listener preparation and a late permission response cannot restart a stopped scan. Run all existing scanner, Meta mock-device, batch/API, and PDF tests. Build the unsigned device IPA.

Simulator tests cannot prove physical Bluetooth routing or establish the exact crash on this user's iPhone. A device test after installation is still required; if the crash persists, obtain the iPhone Analytics crash report before speculating further.
