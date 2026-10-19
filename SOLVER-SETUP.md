# Glasses Solver 2.2: fast live capture, start from a shortcut, control everything with your thumb

You don't need to take out your phone during a scan. Start it with a shortcut (Action button, Back Tap, Control Center or Siri), scan by looking at each page, and use three thumb gestures. If the AI can't read a page, the glasses ask for that page again and then finish the PDF; you never have to tap Retake on the phone.

2.2 no longer takes one slow full-resolution photo per page. It keeps the clearest moments of the live camera, several per page, so there's no pause between photos. Each question number is read on the phone and announced as it's captured, and a skipped number is asked for. Each page is solved in its own streaming request while you keep scanning. When you finish, only the last page is left, so the PDF arrives about one page-solve later. Directions play quietly through the glasses only. Voice commands and glasses buttons are off by default.

## Install from Windows

1. Open [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Pick the latest run of the `claude/pensive-allen-ggkllj` branch where **both** the verify and build jobs passed.
2. Download **GlassesSolver-IPA** under Artifacts and extract the ZIP.
3. Use iloader to install `GlassesSolver-unsigned.ipa` over the existing app, with the same Apple account. Don't delete the old app first: saved pages, PDFs and API keys stay.
4. Open **Auto Scan → Settings (gear)**.
   - Choose **OpenAI** or **Claude** and check the API key. Defaults: **GPT-6.1 Sol** (`gpt-6.1-sol`) and **Claude Opus 5.5** (`claude-opus-5-5`).
   - Save.
5. Make sure the glasses are connected in Meta AI and Developer Mode is on. Run one scan from the app first, so you can allow camera access on the phone.

## Set up the start shortcut (once)

The app installs a shortcut called **Start Glasses Scan**. It opens the app on Auto Scan and starts the glasses camera; if a packet is already solved, it starts a new one.

1. **Check it:** open the Shortcuts app → App Shortcuts → Glasses Solver → **Start Glasses Scan**, and run it once.
2. **Action button** (iPhone 15 Pro and later): Settings → Action Button → swipe to **Shortcut** → Choose a Shortcut → **Start Glasses Scan**. Press and hold the button to start.
3. **Back Tap** (any recent iPhone): first add it to your shortcuts (Shortcuts → + → search "Start Glasses Scan" → add → name it "Glasses Scan"). Then Settings → Accessibility → Touch → Back Tap → Double Tap → **Glasses Scan**. Double-tap the back of the phone to start.
4. **Control Center or Lock Screen** (iOS 18+): + → Add a Control → **Shortcut** → choose "Glasses Scan".
5. **Siri:** "Start a scan in Glasses Solver".

If the shortcut isn't listed, make a personal shortcut with the **Open URLs** action and the address `glassessolver://scan`; it does the same thing.

The phone must be unlocked, because the app has to be on screen for the glasses camera. Put the phone face up on the desk, start with the shortcut, and leave it there. The screen stays on while you scan.

## Scan a packet

1. Start with the shortcut (or tap **Start scanning**). You hear "Ready".
2. Look closely at the top of the first page: about a hand's width of text at a time, close enough that the small writing is sharp. Hold still for about half a second. Quiet directions (left / right / tilt / closer / hold still) guide you.
3. You hear each question number as it is captured ("Questions 1 and 2."). Move down the page to the next questions. If a number is skipped, you hear "Question 3 isn't captured yet. Look at it again."
4. When nothing new has appeared for about 3 seconds, the page is saved: "Page 1 saved: 3 photos, questions 1 to 4." Or give 👉 to save it right away.
5. Turn to the next page; new writing starts the next page automatically. Pages are solved in the background as you go.
6. When you're done, give a **thumbs-up**. The page in front of you is saved first. You hear "Done scanning. Solving." The PDF opens on the phone as soon as the last page is solved.

Prefer one big photo per page? Settings → Capture → **Full-resolution photo**. It is sharper for a whole page at arm's length, but each photo pauses the camera and takes several seconds.

## Hand gestures

Make a fist with your thumb straight out. Hold it in front of you, in the middle of your view, about a forearm's length away, for about one second. Lower your hand before the next gesture; gestures are about 2 seconds apart.

| Gesture | Meaning |
| --- | --- |
| 👍 Thumb **up** | **Start solution.** Finish scanning and make the PDF. |
| 👉 Thumb to **your right** | **Next page.** Save the page you're scanning now, or start the next page when a look-alike page wasn't noticed. |
| 👈 Thumb to **your left** (👎 thumb down also works) | **Previous page.** Retakes the page you just scanned. Do it again to go one more page back. Turn back to that page and it's captured when steady; the old photo stays until the new one is clear. |

- Thumb right is easiest with your right hand, and thumb left with your left hand, palm turned up or toward you. Keep the thumb level for left and right, and straight up or down for the others. Diagonal thumbs are ignored on purpose.
- Hands holding, pinching or resting on the paper are ignored, and the app never photographs a raised hand.
- After you retake an earlier page, the camera stays on but doesn't add pages by itself, because the sheets in front of you were already scanned. Turn to the first new page and give 👉, or give 👍 to solve.

## When the AI can't read a page

- **During the scan** you hear, for example, "Page 3: the bottom line is cut off. I'll ask for it again when you finish." Keep scanning.
- **After 👍** the glasses ask: "Show page 3 again, or thumbs-up to solve without it." Turn to page 3 and hold it steady. It's captured once the view changes to it (or after a few seconds if you were already showing it), and solving continues by itself.
- **👍 instead** makes the PDF without that page. The PDF lists it as **NEEDS REVIEW** with its photo, so you can see what's missing.
- **Network or provider failure** after retries: you hear the reason and "Give a thumbs-up to try again". The camera stays on for that thumbs-up; already solved pages aren't sent again.

## Spoken directions

- Directions and progress are spoken at **5%** volume through the glasses only (**Only through glasses or headphones** is on by default). The same text is always on screen.
- You can change the volume in Settings or turn speech off. The microphone isn't used unless you turn on **Voice commands** in Settings.

## Speed options (Settings)

- **Solve pages while scanning** (on): each page is uploaded and solved once the next page is saved. Turn it off to upload nothing until you finish.
- **Provider:** one provider is fastest. **Both · cross-check** solves every page with both providers and then reconciles the answers; it's slower and costs twice as much.

## If something goes wrong

- **Leaving the app or locking the phone** pauses the camera ("Scanning paused"). Solving continues as long as iOS allows. Run the shortcut again (or tap Continue) to keep scanning.
- **Forgotten scan:** after 5 minutes with no new page and no gesture, the camera stops by itself. Your pages are kept.
- **Key, billing, or model errors:** shown right away with no retries. Fix them in Settings and finish again (this one needs the phone).
- **No API key:** scanning still saves pages but tells you a key is missing.
- **Gesture not recognized:** hold the hand closer and more centered, fingers curled tight, thumb straight. Check that **Hand gestures** is on in Settings.
- **Fixing a page after the PDF:** the solved pages stay until you start a new packet. Tap **Retake** under a page; when it's saved, give 👍 to rebuild the PDF. Only that page and its neighbors are solved again. Every PDF's original photos stay in **Files → On My iPhone → Glasses Solver → Solutions**.
- **Glasses buttons:** Meta's experimental Inputs didn't reach the app on your glasses, so 2.1 turns them off. You can turn them on again in Settings to try. A single tap on the touchpad still pauses or resumes the glasses, and touch-and-hold stops the glasses session.

## Limits and privacy

- Up to **30 pages** per packet.
- Each page request includes that page plus its previous and next pages, labeled, so questions that continue across pages are solved once.
- Answers include worked steps, a final answer, and a check. Uncertain items are marked **NEEDS REVIEW**. Compare the transcriptions with your photos.
- Keys stay in separate iPhone Keychain entries and go only to their own provider.
- Gesture detection and speech stay on the phone.

## What was tested

GitHub's macOS build compiles the iPhone app and runs simulator tests for:

- **Capture and solving:** the coordinator, including the gesture-only flows: next, previous, retaking an earlier page, asking again for an unreadable page, solving without it, retrying after a failure, and the start shortcut.
- **Gestures:** the classifier for all four thumb directions, diagonal and paper-grip rejection, and the timing gate.
- **AI responses:** streaming parsing for both providers, retries and repairs, request formats, and the PDF.
- **Meta mock glasses:** preview frames and full-photo capture.
- **Shortcut:** the build checks that the Start Glasses Scan shortcut is in the app.

Still to check on your device: real glasses, real hand gestures (especially thumb left and right), the shortcut on your phone, audio routing, and paid API answers.
