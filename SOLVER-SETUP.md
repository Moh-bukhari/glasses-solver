# Glasses Solver 2.0: one button, silent controls, fast PDF

Version 2.0 replaces the slow solving pipeline. Before, a packet ran through 4–18 back-to-back AI requests, each waiting silently for the full answer, which could take 10–45 minutes or time out. Now each page is solved in its own streaming request while you keep scanning. When you finish, only the last page is left, so the PDF arrives about one page-solve later.

You control everything with a thumbs-up or clicks on the glasses. Voice commands are off by default, and directions play quietly through the glasses only.

## Install from Windows

1. Open [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Pick the latest run of the 2.0 branch where **both** the verify and build jobs passed.
2. Download **GlassesSolver-IPA** under Artifacts and extract the ZIP.
3. Use iloader to install `GlassesSolver-unsigned.ipa` over the existing app, with the same Apple account. Don't delete the old app first: saved pages, PDFs and API keys stay.
4. Open **Auto Scan → Settings (gear)**.
   - Choose **OpenAI** or **Claude** and check the API key.
   - 2.0 switches the old defaults to **GPT-6.1 Sol** (`gpt-6.1-sol`) and **Claude Opus 5.5** (`claude-opus-5-5`).
   - If you used the old "OpenAI + Claude" default, it becomes a single provider, because that is fastest: OpenAI if its key is saved, otherwise Claude. **Both · cross-check (slower)** is still available.
   - Save.
5. Make sure the glasses are connected in Meta AI and Developer Mode is on. Allow camera access when asked.

## Scan a packet

1. Tap **Start scanning**.
2. Look at the first page, close enough that the small writing is readable. Quiet directions in the glasses (left / right / tilt / closer / hold still) guide you.
3. When the view is clear and steady, it takes the photo. You hear **"Got it"**, and you can turn the page right away while the photo transfers. Then **"Page 1 saved"**.
4. Turn to the next page. Changed writing re-arms the camera automatically. Pages are solved in the background as you go: each page's thumbnail shows a clock, a spinner, or a green check.
5. When you're done, **give a thumbs-up**. Make a fist about 30 cm (one foot) in front of the glasses, curled fingers toward you, thumb straight up, and hold it for about a second. You can also double-tap the glasses touchpad, double-press the capture button, or tap **Done · Solve** on the phone.
6. You hear "Done scanning. Solving." The PDF opens on the phone as soon as the last page is solved.

## Silent controls

| Do this | What happens |
| --- | --- |
| 👍 Thumbs-up, held ~1 second | Finish scanning and solve |
| 👎 Thumbs-down, held ~1 second | Retake the last page; the old photo stays until the new one is clear |
| Double-tap the touchpad, or double-press the capture button | Finish scanning and solve |
| Press the capture button once | Next page now (for look-alike pages), or take the current view as soon as the writing is clear |
| Hold the capture button | Retake the last page |
| Single tap on the touchpad | Reserved by the glasses: pauses or resumes. Scanning waits while paused and continues when you tap again |
| Touch-and-hold on the touchpad | Reserved by the glasses: **stops** the glasses session. Avoid it; to retake, hold the capture button instead |

- **Gestures** are recognized on the iPhone from the glasses camera. A hand holding or resting on the paper is ignored, and the app never photographs a raised command hand.
- **Glasses buttons** use Meta's experimental Inputs feature. After each photo they take a moment to reconnect, so wait for "Page N saved" before pressing. If your glasses or Meta AI version doesn't allow it, the app says so once and the thumbs-up still works.
- **Look-alike pages:** if a new page looks too much like the last one, the turn isn't detected and you'll hear "If this is a new page, press the capture button". Press it once, or tap **Next page now**.
- **Voice commands:** if you had turned them on in 1.x, 2.0 turns them off once so the microphone isn't used.

## Spoken directions

- Directions and progress are spoken at **5%** volume through the glasses only: **Only through glasses or headphones** is on by default, so the phone speaker stays silent. The phone's Silent switch no longer mutes them. The same text is always on screen.
- You can change the volume in Settings or turn speech off. The microphone isn't used unless you turn on **Voice commands** in Settings.

## Speed options (Settings)

- **Solve pages while scanning** (on): each page is uploaded and solved once the next page is saved. Turn it off to upload nothing until you finish; all pages are then solved at once, in parallel.
- **Provider:** one provider is fastest. **Both · cross-check** solves every page with both providers and then reconciles the answers, which adds one round per page and doubles the cost.

## If something goes wrong

- **A page can't be read:** you'll hear about it during scanning, and the message names the page. Tap **Retake** under that page (or **Replace photo**), then tap **Done**. Finishing again without a new photo just resends the same photo. Pages already solved are kept and aren't sent again.
- **Network or a busy provider:** requests are retried automatically, at most twice. If a page still fails, finish again: only the failed pages are solved again.
- **Key, billing, or model errors:** shown right away, with no retries. Fix them in Settings and finish again.
- **No API key:** Start still saves pages but tells you a key is missing. Finishing opens Settings.
- **Leaving the app:** switching tabs or tapping Pause doesn't cancel solving. Leaving the app pauses the camera, and you'll hear "Scanning paused". Solving keeps going for as long as iOS allows, and the PDF can still be made if the phone locks. Keep the app open while scanning.
- **Fixing a page after the PDF:** the solved pages stay until you start a new packet. Tap **Retake** or **Replace photo** under a page, then **Done** to rebuild the PDF; only that page and its neighbors are solved again. **Start a new packet** clears them. Every PDF's original photos stay in **Files → On My iPhone → Glasses Solver → Solutions**.

## Limits and privacy

- Up to **30 pages** per packet.
- Each page request includes that page plus its previous and next pages, labeled, so questions that continue across pages are solved once.
- Answers include worked steps, a final answer, and a check. Uncertain items are marked **NEEDS REVIEW**. Compare the transcriptions with your photos.
- Keys stay in separate iPhone Keychain entries and go only to their own provider.
- With solving while scanning on, pages are uploaded during the scan. Turn it off if you want nothing sent until you finish.
- Gesture detection and speech stay on the phone.

## What was tested

GitHub's macOS build compiles the iPhone app and runs these simulator tests:

- **Capture and solving:** scanning and solving coordinator tests.
- **Gestures:** the gesture classifier and its timing gate.
- **Glasses buttons:** how each click maps to an action.
- **AI responses:** streaming parsing for both providers, retries and repairs, request formats, and the PDF.
- **Meta mock glasses:** full-photo capture, plus a glasses-button test.

Real glasses, real hand gestures, glasses-button availability on your account, audio routing, and paid API answers still need a test on your device.
