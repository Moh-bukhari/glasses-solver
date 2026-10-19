# Gesture-only, hands-free scanning (2.1)

Builds on [one-button-gesture-spec.md](one-button-gesture-spec.md) (2.0). Solving, capture quality, audio and PDF rules there still apply; this file replaces its control rules.

## User request (2026-10-19)

> "lets make it that we communicate with hand gestures. no buttons because that doesnt work. There was an issue where page 3 needed to be retaken so it waited until i pressed in the app to start taking again then had to do thumbs down to go to retake page 3. Let's make it that i dont have to pull out my phone at all. If you can figure out how i can have a short cut to trigger this workflow either in my phone like the side button or even better in my camera that would be awesome. but during the workflow let's keep the communication simple like next page pervious page, start solution. everything that i need in hand gestures"

What failed in 2.0: glasses buttons (Meta's experimental Inputs) did not reach the app. An unreadable page after Finish stopped the camera with "Retake that page with the Retake button", so the wearer had to tap Continue on the phone and then thumbs-down.

## Acceptance criteria

### Gestures (one family: fist with a straight thumb, held about 1 s)

- **Thumb up: start solution.** Finish and solve. While the app is asking for an unreadable page again, thumb up means solve without that page.
- **Thumb right (wearer's right): next page.**
  - Waiting for a page turn: arm capture for the next new page now.
  - Seeking: take the page in view as soon as it is readable, including a retake waiting for its page.
- **Thumb left, or thumb down: previous page.**
  - Retakes the page just saved; it is still in view, so it is captured as soon as it is steady.
  - Repeating steps one more page back. At page 1 it says so.
  - A page not in view is captured only after the view changes. The comparison is a page-turn check against the clear view from at least 1.5 s before the gesture, so the raised hand isn't mistaken for a turn. Failing that, it is captured 6 s after a reference view exists, for when the wearer was already showing that page.
  - The old photo stays until the new one is clear.
- Thumbs down and thumbs left reach the gesture gate as one gesture, so turning a held thumb from one to the other never fires twice.
- **Classifier rules:**
  - Up and down: within 40° of vertical. Right and left: within 35° of horizontal. Diagonals match nothing, and a thumb inside two cones yields nothing.
  - Every direction uses the same fist, thumb-length, straightness, clearance and lead rules.
  - Paper grips, pinches, L-shapes and small or edge hands are rejected.
  - A raised command hand blocks capture and page-turn detection.
- **Glasses buttons are off by default**, and existing installs are migrated off (settings version 3). They remain an opt-in in Settings. Voice commands stay off by default.

### No phone between start and PDF

- **Middle-page retake.** After replacing an earlier page, by gesture or by the phone's Retake button, the camera stays on. Page turns do not add pages, because the sheets in front of the wearer were already scanned. Thumb right at the first new page continues; thumb up solves.
- **Unreadable page.**
  - When the AI reports one during scanning, the wearer hears the reason and "I'll ask for it again when you finish". Its photo is never sent again as it is.
  - After thumb up the glasses camera restarts and asks for each unreadable page in turn, while the other pages keep solving: "<reason> Show page N again, or thumbs-up to solve without it."
  - After the retake, solving resumes automatically.
  - Thumb up (or Done on the phone) instead leaves those pages out. The PDF then contains a NEEDS REVIEW placeholder with the page's photo, and the guide names the left-out pages. If every page is left out, no PDF is made.
- **Solve failure** (network or provider, after retries). The reason is spoken, plus "Give a thumbs-up to try again". The camera stays on, waiting for a gesture only; thumb up retries only the failed pages. If the camera can't restart, the phone message appears.
- **Inactivity.** After 5 minutes with no new page, gesture or command, the camera stops and the pages are kept.
- **Imported photos** (phone flow) keep the 2.0 behavior: an unreadable page stops Finish with Retake advice.

### Start shortcut

- **App Intent.** "Start Glasses Scan" (`StartScanIntent`, `openAppWhenRun`) plus an `AppShortcutsProvider`. It appears in Shortcuts, Spotlight, Siri ("Start a scan in Glasses Solver") and the Action button picker without setup. A personal shortcut can be put on Back Tap or a Control Center or Lock Screen control.
- **URL.** `glassessolver://scan` does the same, as a fallback for a personal "Open URLs" shortcut.
- **Behavior.** The request switches to the Auto Scan tab and starts once the scene is active: it continues an unsolved packet, or starts a new one after a PDF. A second request while scanning or solving only announces it.
- **Phone side button.** Not assignable by apps. Camera Control needs a LockedCameraCapture extension and is out of scope.
- **Glasses.** DAT 1.0.1 cannot start an app silently from the glasses; every silent signal needs a session the phone app already started. The only glasses-side launch is the experimental "Hey Meta, start Glasses Solver" voice invocation, which needs a Wearables Developer Center app with the Voice Invocation permission approved. It is documented in the handoff as an option, not implemented.

## Verification

- **Gesture tests:** all four directions for both hands, tilts, diagonals rejected, paper grips rejected, gate behavior (`HandGestureTests`).
- **Coordinator tests** (`AutoScanTests`):
  - thumb right and left navigation;
  - stepping back two pages and refusing the in-view sheet until the view changes;
  - a middle-page retake waiting for thumb right;
  - an unreadable page asked for again after Finish and solved without the phone;
  - thumb up solving without the unreadable page (placeholder, no resend);
  - solve failure standby with thumb-up retry;
  - shortcut start once and ignored while scanning.
- **CI:** the build checks that the App Intents metadata containing `StartScanIntent` is in the app.
- **Device-only checks:**
  - sideways thumbs on real glasses frames, including the unmirrored-camera assumption;
  - shortcut registration for a sideloaded app;
  - the Action button and Back Tap;
  - camera restart time for the unreadable-page request.
