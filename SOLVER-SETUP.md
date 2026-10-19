# Glasses Solver 2.6: take each page with the capture button, checked as you go, one folder per packet

The glasses' video is too blurry for small print, but the photos you take with the **capture button** are sharp. In 2.6 you photograph each page yourself. The Meta AI app imports every photo into your iPhone's Photos; Glasses Solver picks it up right away, checks that every question on the page can be read, and tells you through the glasses: "Page 1 is clear. Take page 2." or what to photograph again. Each page is solved as soon as the next one is saved, so the PDF is ready moments after you finish. Everything for one packet goes into one folder in the Files app.

2.6 starts fresh: your earlier PDFs moved to **Files › On My iPhone › Glasses Solver › Old solutions** (delete that folder if you don't need them), and the old unfinished pages were cleared.

## Install from Windows

1. Open [Build Glasses Solver IPA](https://github.com/Moh-bukhari/glasses-solver/actions/workflows/build-solver.yml). Pick the latest run of the `claude/pensive-allen-ggkllj` branch where **both** the verify and build jobs passed.
2. Download **GlassesSolver-IPA** under Artifacts and extract the ZIP.
3. Use iloader to install `GlassesSolver-unsigned.ipa` over the existing app, with the same Apple account. Don't delete the old app first: saved pages, PDFs and API keys stay.
4. Open **Auto Scan → Settings (gear)**.
   - Enter your **Anthropic (Claude)** key for the best results, and your OpenAI key if you have one. With a Claude key saved, Claude solves and checks pages. Defaults: **Claude Opus 5.5** (`claude-opus-5-5`) and **GPT-6 Astra** (`gpt-6-astra`).
   - **Fast processing** (on) uses Claude fast mode / OpenAI Ultrafast: the same answers sooner, at several times the price. If your account can't use them, the app falls back by itself.
   - Save.
5. In the **Meta AI** app, open your glasses' settings and turn on **Auto-import** for photos and videos (Media). If Meta AI offers **Wi-Fi Aware** or faster imports, turn it on. Turn off any automatic crop, straightening or enhancement of photos if you see one.
6. Start a scan once and allow **Full Access** to Photos when asked (Limited access hides new photos from the glasses). If you chose Limited: Settings › Privacy & Security › Photos › Glasses Solver › Full Access.
7. Live-frame scanning (Settings › Capture) still needs the glasses connected in Meta AI with Developer Mode on.

## Scan a packet with the capture button (default)

1. Tap **Start scanning** (or run the Start Glasses Scan shortcut). You hear "Ready. Take a photo of page 1 with the capture button."
2. Photograph page 1 with the capture button on the glasses: one photo of the whole page, close enough to fill the view with the sheet, plus a close-up of any small print, tables or graphs. Good light helps most.
3. Each photo reaches the phone through Meta AI, usually within seconds; the screen shows how long the last one took. You hear "Checking page 1." and then:
   - "**Page 1 is clear. Take page 2.**" The page is saved and you move on.
   - Or what to photograph, for example "**Page 1: Take a closer photo of question 4(c).**" Take that photo; the page is checked again with all its photos.
4. Photographed page 2 before hearing that page 1 is clear? That photo waits: you hear "Page 1 isn't clear yet… Go back to it", and once page 1 is clear, page 2 continues from the photo you already took. A late extra photo of page 1 is recognized and doesn't become a new page.
5. **Commands are photos of your hand.** Make a fist with the thumb out, hold it close in front of the glasses, and press the capture button:
   - 👍 **thumb up**: done, solve everything. If the last page isn't clear yet you hear why; a second thumbs-up photo solves anyway.
   - 👉 **thumb to your right**: keep this page as it is and go on.
   - 👈 **thumb to your left**: retake the page before.
   The phone has the same buttons (**Done · Solve**, **Keep this page as it is**), and there is a **Finish Glasses Scan** shortcut for Siri or the Action button.
6. The PDF opens on the phone. It is saved with every photo in **Files › On My iPhone › Glasses Solver › Solutions › <date, time and title>**: `Solutions.pdf`, `Page 1.jpg`, `Page 2 (1).jpg`, `Page 2 (2).jpg`, …

Keep the phone unlocked with Glasses Solver open while you scan (the screen stays on). If no photo arrives after a minute, open Meta AI's gallery once so it imports, then come back to Glasses Solver. After 10 minutes without a new photo, the pages you took are solved.

## Live frames (hands-free, blurrier)

Settings › Capture › **Live frames** keeps the clearest moments of the glasses' video instead, controlled with hand gestures in front of the glasses. It needs no button presses but the video is much blurrier than photos.


## Set up the start shortcut (once)

The app installs a shortcut called **Start Glasses Scan**. It opens the app on Auto Scan and starts the glasses camera; if a packet is already solved, it starts a new one.

1. **Check it:** open the Shortcuts app → App Shortcuts → Glasses Solver → **Start Glasses Scan**, and run it once.
2. **Action button** (iPhone 15 Pro and later): Settings → Action Button → swipe to **Shortcut** → Choose a Shortcut → **Start Glasses Scan**. Press and hold the button to start.
3. **Back Tap** (any recent iPhone): first add it to your shortcuts (Shortcuts → + → search "Start Glasses Scan" → add → name it "Glasses Scan"). Then Settings → Accessibility → Touch → Back Tap → Double Tap → **Glasses Scan**. Double-tap the back of the phone to start.
4. **Control Center or Lock Screen** (iOS 18+): + → Add a Control → **Shortcut** → choose "Glasses Scan".
5. **Siri:** "Start a scan in Glasses Solver".

If the shortcut isn't listed, make a personal shortcut with the **Open URLs** action and the address `glassessolver://scan`; it does the same thing.

The phone must be unlocked, because the app has to be on screen for the glasses camera. Put the phone face up on the desk, start with the shortcut, and leave it there. The screen stays on while you scan.

## Scan a packet with live frames

1. Choose Settings › Capture › Live frames, then start with the shortcut (or tap **Start scanning**). You hear "Ready. Look at page 1 closely, part by part, top to bottom."
2. Look closely at page 1: about a hand's width of text at a time, close enough that the small printed writing is sharp. Hold still for about half a second at each part, and go all the way to the bottom of the sheet. Quiet directions (left / right / tilt / closer / hold still) guide you. "Move a little closer: the printed text is too small to read" means that view wasn't kept.
3. When you pause, you hear "Checking page 1." A couple of seconds later:
   - "**Page 1 is clear. Turn the page.**" The page is saved.
   - Or what to fix, for example "**Page 1: the bottom line is cut off; show it.**" Look at that part again and hold still; the page is checked again. If it keeps asking and you're sure the page is fine, give 👉 to keep it as it is.
4. Turn to page 2. The new page starts by itself when the view changes to new writing (or give 👉). Repeat until the last page.
5. When you're done, give a **thumbs-up**. If the page in front of you wasn't confirmed clear yet, it is checked first; if it isn't clear you hear what's wrong, and a second thumbs-up solves anyway. Then you hear "Done scanning. Solving." All pages are solved at once, and the PDF opens on the phone.

If a page check can't run (no internet, or a key or billing problem), you hear it once and pages are saved without the check, like before. Turn the check off in Settings → **Check each page before the next**.

Prefer one big photo per page? Settings → Capture → **Full-resolution photo**. It is sharper for a whole page at arm's length, but each photo pauses the camera and takes several seconds.

## Hand gestures (live frames)

Make a fist with your thumb straight out. Hold it in front of you, in the middle of your view, about a forearm's length away, for about one second. Lower your hand before the next gesture; gestures are about 2 seconds apart.

| Gesture | Meaning |
| --- | --- |
| 👍 Thumb **up** | **Start solution.** Finish scanning and make the PDF. |
| 👉 Thumb to **your right** | **Next page.** Keep the page you're scanning as it is (without waiting for the check), or start the next page when a look-alike page wasn't noticed. |
| 👈 Thumb to **your left** (👎 thumb down also works) | **Previous page.** Retakes the page you just scanned. Do it again to go one more page back. Turn back to it and it's captured and checked when steady; the old photos stay until the new ones are clear. |

- Thumb right is easiest with your right hand, and thumb left with your left hand, palm turned up or toward you. Keep the thumb level for left and right, and straight up or down for the others. Diagonal thumbs are ignored on purpose.
- Hands holding, pinching or resting on the paper are ignored, and the app never photographs a raised hand.
- After you retake an earlier page, the camera stays on but doesn't add pages by itself, because the sheets in front of you were already scanned. Turn to the first new page and give 👉, or give 👍 to solve.

## When the AI can't read a page

- **During the scan** each page is checked before you move on (see above), so this should be rare.
- **After 👍**, if the solver still can't read a page, the glasses ask: "Show page 3 again, or thumbs-up to solve without it." Turn to page 3 and hold it steady. It's captured once the view changes to it (or after a few seconds if you were already showing it), and solving continues by itself.
- **👍 instead** makes the PDF without that page. The PDF lists it as **NEEDS REVIEW** with its photo, so you can see what's missing.
- **Network or provider failure** after retries: you hear the reason and "Give a thumbs-up to try again". The camera stays on for that thumbs-up; already solved pages aren't sent again.

## Spoken directions

- Directions and progress are spoken at **5%** volume through the glasses only (**Only through glasses or headphones** is on by default). The same text is always on screen.
- You can change the volume in Settings or turn speech off. The microphone isn't used unless you turn on **Voice commands** in Settings.

## Speed options (Settings)

- **Check each page before the next** (on): Claude Opus 5.5 (or GPT-6 Astra without a Claude key) checks each page while you look at it.
- **Fast processing** (on): paid speed lanes for checks and solving; turn off to pay standard prices.
- **Solve pages while scanning** (off, live frames only): turn it on to solve each page in the background once the next page is saved. Capture-button photos are always solved as you go.
- **Provider:** one provider is fastest. **Both · cross-check** solves every page with both providers and then reconciles the answers; it's slower and costs twice as much.

## If something goes wrong

- **No photo arrives (capture button):** check Meta AI's Auto-import setting and that Glasses Solver has Full Access to Photos (the app shows a button to its Settings page). Opening Meta AI's gallery imports waiting photos; then switch back. Photos imported while Glasses Solver was in the background are picked up when you return.
- **Leaving the app or locking the phone** with live frames pauses the camera ("Scanning paused"). A capture-button scan keeps going and catches up when you're back. Solving continues as long as iOS allows. Run the shortcut again (or tap Continue) to keep scanning.
- **Forgotten scan:** after 5 minutes with no new page and no gesture, the camera stops by itself. Your pages are kept.
- **Key, billing, or model errors:** shown right away with no retries. Fix them in Settings and finish again (this one needs the phone).
- **No API key:** scanning still saves pages but tells you a key is missing.
- **Gesture not recognized:** hold the hand closer and more centered, fingers curled tight, thumb straight. Check that **Hand gestures** is on in Settings.
- **Fixing a page after the PDF:** the solved pages stay until you start a new packet. Tap **Retake** under a page; when it's saved, give 👍 to rebuild the PDF. Only that page and its neighbors are solved again. Each finished packet is its own folder in **Files → On My iPhone → Glasses Solver → Solutions**, named by date, time and title.
- **Glasses buttons:** Meta's experimental Inputs didn't reach the app on your glasses, so 2.1 turns them off. You can turn them on again in Settings to try. A single tap on the touchpad still pauses or resumes the glasses, and touch-and-hold stops the glasses session.

## Limits and privacy

- Up to **30 pages** per packet.
- Each page request includes that page plus its previous and next pages, labeled, so questions that continue across pages are solved once.
- Answers are full worked solutions with typeset math (equations, fractions, units), a final answer, and a check. The AI finds the questions and their numbers on each page. Uncertain items are marked **NEEDS REVIEW**; when a number reads differently in different photos, both readings are shown. Compare the transcriptions with your photos.
- Keys stay in separate iPhone Keychain entries and go only to their own provider.
- Gesture detection and speech stay on the phone.

## What was tested

GitHub's macOS build compiles the iPhone app and runs simulator tests for:

- **Capture and solving:** the coordinator, including the gesture-only flows: next, previous, retaking an earlier page, asking again for an unreadable page, solving without it, retrying after a failure, and the start shortcut.
- **Gestures:** the classifier for all four thumb directions, diagonal and paper-grip rejection, and the timing gate.
- **Capture-button photos (2.6):** photos are paged by the check and solved as you go, a photo of the next sheet waits until the page is clear, a late photo of the page before never starts a page, thumbs-up and thumbs-right photos are commands, finishing on an unclear page warns once, no photo is used twice, Photos access is required, and folder names (with fake photos and AI answers).
- **Page check:** a page is saved only after the check says it is clear, unclear pages ask again, photos of another sheet are dropped, thumbs-up checks the open page first, and a check that can't run never blocks the scan (with fake AI answers).
- **AI responses:** streaming parsing for both providers, retries and repairs, request formats (including the fast check model and its fallback), and the PDF.
- **Meta mock glasses:** preview frames and full-photo capture.
- **Shortcut:** the build checks that the Start Glasses Scan shortcut is in the app.

Still to check on your device: how fast Meta AI imports capture-button photos while you wear the glasses, real glasses, real hand gestures (especially thumb left and right), the shortcut on your phone, audio routing, paid API answers, and how fast and how strict the page check is.
