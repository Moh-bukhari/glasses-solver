> Research notes from 2026-10-20 (2.7). Local paths refer to the research working folder, which is not in the repository; the sources are cited by URL. The app's writer is `samples/CameraAccess/CameraAccess/Solver/G3P.swift`, tested against Casio's `_Blank.g3p` in `CalculatorPictureTests`.

# Casio fx-CG50: limits for showing solution pictures without zoom

Research date: 2026-10-20. This file covers device limits only. It does not specify the g3p encoder.

Status labels used throughout:
- **VERIFIED**: seen in a Casio manual or guide, in a Casio screenshot, or in real Casio files I inspected.
- **VERIFIED-COMMUNITY**: documented by long-running community references (Cemetech WikiPrizm, Cemetech, Planete Casio). Reliable, but not from Casio.
- **DERIVED**: I calculated or inferred it from verified facts. The reasoning is shown.
- **UNVERIFIED**: a single anecdote, a search-result snippet I could not open, or a guess. Test it on a real calculator first.

Local evidence (all under ``):
- `cg50-manual-v360.txt`: full text of the fx-CG50 Software User's Guide (v3.60, 678 pp.).
- `hw.txt`: Hardware User's Guide text.
- `frguide.txt`: Casio France "Plot Image" guide text.
- `render/*.png`: high-resolution renders of the manual screenshots cited below.
- `tools/g3pdims.py`: read-only header scanner I ran on Casio's own sample g3p/g3b files.

---

## 0. Bottom line (design target)

| Item | Value | Status |
|---|---|---|
| Canvas to produce | **384 x 192 px**, 16-bit colour | VERIFIED: all 47 official Casio Picture Plot g3p files and all 8 g3b files I inspected are 384x192, 16-bit (section 2.6). Casio's Picture Plot screenshots show a 24 px status bar above the picture (section 1.2). |
| Visible area while viewing | 384 x 192 at screen rows 24-215. The status bar always covers rows 0-23. | VERIFIED (status bar always shown: manual p.1-5 and screenshots). 24 px height: VERIFIED-COMMUNITY plus a measurement from the manual screenshot. |
| Function-key bar | Hidden in Picture Plot until you press OPTN. Not shown in the Memory-app image preview. | VERIFIED (screenshots: manual pp.15-7, 15-8, 11-6; Casio France guide p.2-3). |
| Overlays to plan for | Picture Plot draws x/y axes and labels by default; turn them off in SET UP. The Memory-app preview draws small magenta navigation arrows at the left and right edges. | VERIFIED that both overlays exist (screenshots). Exact arrow positions are DERIVED by measurement (section 1.3). |
| Fastest way to page through many pictures | **Memory app image preview + up/down cursor keys** jumps to the previous or next file in the folder. | VERIFIED (manual p.11-6). |
| File names | **8.3 names** (8 characters max before `.g3p`). Longer names still open but appear as `Jumpin~1.g3b`. | VERIFIED (manual p.11-2; Casio France screenshot). |
| Folder | One top-level folder, for example `\SOLN\`, holding at most 200 files. | 200-file display limit is VERIFIED for the Memory app (p.11-2). For Picture Plot it is UNVERIFIED. |
| Storage | 16 MB max on the fx-CG50 (4.5 MB on the fx-CG50 AU). Official 16-bit 384x192 g3p files are 12-108 KB each. | VERIFIED (hardware guide spec; sizes of real files). |
| Body text size | Cap height at least about 11 px for comfortable reading, about 9 px as a dense minimum. Line pitch about 16-20 px, which gives 9-12 lines per picture. | DERIVED from legibility norms and the 0.183 mm pixel pitch (section 4). Not tested on a device. |

---

## 1. Opening and viewing a picture; what covers it; paging

### 1.1 Apps that can show a .g3p, and how to open it

1. **Picture Plot** (on the Graph 90+E it is called "Plot Image").
   - VERIFIED, manual pp.15-3 and 15-5: from the Main Menu, open Picture Plot. The file list appears. Use the up/down keys to highlight a file and press `F1 (OPEN)` or `EXE`.
   - `F1 (OPEN)` also opens a folder, so you can browse into subfolders. The Casio France screenshot shows the path `Pict \CASIO\g3b`.
   - The file list also has `F4 SEARCH` and `F5 DETAIL`.
   - When you return to Picture Plot later, the last opened file reopens automatically.
   - To open a different file from the picture screen: `OPTN` -> `F1 (FILE)` -> `F1 (OPEN)` -> pick the file -> `EXE`.
   - VERIFIED: on the fx-CG50 and fx-CG50 AU, Picture Plot is an add-in. Casio UK distributes it with the other add-ins (Geometry, 3D Graph and others) so it can be reinstalled ([Casio UK add-ins](https://education.casio.co.uk/support/os-files/os-files-cg50-add-ins/)). The manual tells AU users to install it.
   - VERIFIED-COMMUNITY: Planete Casio reports that Plot Image and other add-ins can disappear after a reset and must be reinstalled.
   - VERIFIED, manual p.15-1: the picture fills the screen below the status bar. The status bar reads "Press [OPTN]". Pressing `OPTN` shows the function menu (FILE / Plot / List / DefG / MODIFY / ▷) along the bottom, on top of the picture.

2. **Memory app (Memory Manager): image preview.** This one is built in, not an add-in.
   - VERIFIED, manual pp.11-1, 11-2 and 11-6, and the screenshot in `render/crop429.png`. Steps:
     1. MENU -> Memory -> `F2 (STRGMEM)`.
     2. Highlight a folder and press `EXE` to open it.
     3. Highlight a .g3p or .g3b file and press `F5 (DETAIL)` or the right arrow. This shows the DETAIL screen (name, "Picture Graph File", size, `Dimension: 384*216` for the manual's example).
     4. Press the right arrow again to show the image preview.
     5. **While the DETAIL screen or the image preview is displayed, the up/down arrows scroll to the DETAIL screen or image preview of the next file, in the order the files are listed on the storage memory information screen.**
     6. Left arrow or EXIT goes back.
   - VERIFIED-COMMUNITY: a Cemetech reply also says G3Ps can be viewed in the Memory app with the detail button ([cemetech p=302517](https://cemetech.net/forum/viewtopic.php?p=302517)).

3. **Geometry**: can open a g3p only as a drawing background (`F1 File` -> `2:Open` -> `F6 (STRGMEM)`). VERIFIED (manual p.14-8). Not useful for reading pages.

4. **Graph mode background**: SET UP -> `Background` -> `PICT n` (PICT folder) or `OPEN` (any folder). VERIFIED (manual pp.1-36, 5-10). The graph area is 384x192 and draws axes over the picture. Not recommended for viewing.

5. **eActivity**: can insert a 16-bit g3p (or a 3-bit screen capture) as a "picture line". VERIFIED (manual pp.10-14 and 10-15). Insertion lists g3p files in the **PICT** folder. Details are in section 5.

6. **Casio BASIC program**: `RclPict "folder\file"` draws a storage-memory g3p on the graph screen, and `BG-Pict "folder\file"` sets it as the background. VERIFIED that the commands exist (manual pp.8-32, 8-33, 8-58). Whether this makes a usable paging viewer is UNVERIFIED.

7. **g3b (flip-book) files open only in Picture Plot.** VERIFIED (manual p.15-8).

### 1.2 What covers the picture, and the exact visible area

- VERIFIED (manual p.1-5): the status bar "is always displayed at the top of the screen."
- VERIFIED-COMMUNITY (WikiPrizm): the status area is 24 px tall. PrintMini's y coordinate is "automatically incremented by 24 pixels (status area)", and PrintMiniMini draws "24 pixels below the coordinate specified, to take care of the status area" ([PrintMini](https://prizm.cemetech.net/Syscalls/PrintMini/), [PrintMiniMini](https://prizm.cemetech.net/Syscalls/PrintMiniMini/)). Add-ins can disable it ([EnableStatusArea](https://prizm.cemetech.net/Syscalls/EnableStatusArea/)); built-in apps cannot.
- DERIVED: measuring the Memory-preview screenshot in the manual gives a status bar of about 23-24 px out of 216.
- VERIFIED (manual p.1-5): the "graph screen uses an area that measures 384 (W) x 216 (H) dots". The text screen is 21 columns by 8 lines, and the bottom line is the function-key menu.
- DERIVED: 216 - 24 (status bar) = 192 = 8 x 24, so the function-key menu is the bottom 24 px.
- VERIFIED (manual p.10-14), eActivity table:
  - 384x216 is "the overall screen size … The graphic images stored in capture memory … are this size."
  - 384x192 is "the screen size when a graph screen is saved to picture memory."
  - Graph-screen pictures saved from Graph mode do not include the status bar or the function menu (manual p.5-20).
- **Picture Plot**: the visible picture is **384x192 below the status bar**. The function bar appears only after `OPTN`.
  - VERIFIED from screenshots: manual pp.15-7 and 15-8 (`render/crop529.png`), and Casio France guide pp.2-3 (`render/fr2crop2.png`, `render/fr-03.png`).
  - Corroborating (VERIFIED-COMMUNITY): Mynavi says "液晶画面に表示できる画像サイズは384×192ピクセルです", meaning the picture size the LCD can show is 384x192 ([Mynavi](https://news.mynavi.jp/techplus/article/calcpython-10/)).
- **Memory preview**: 384x192 below the status bar, with no function bar but with edge arrows (section 1.3). VERIFIED from the screenshot (manual p.11-6).
- **eActivity**: shows a 384x168 window. "The 48 vertical dots that are outside of the eActivity display range can be displayed by scrolling" for a 384x216 picture. VERIFIED (p.10-14). DERIVED: a 384x192 picture therefore needs 24 px of scrolling.
- **UNVERIFIED**: what Picture Plot or the Memory preview does with a **384x216** g3p (the manual's own example, `Picture1.g3p`, is 384x216). Either the top 24 rows sit under the status bar or the bottom 24 rows are cut off; I could not tell which from the screenshots. **Avoid the question by producing 384x192**, which is what every current Casio sample uses.

### 1.3 Overlays to avoid when laying out content

- **Picture Plot axes.** VERIFIED: the default screenshots show x/y axes, an "O" origin label and tick marks drawn over the photo (manual p.15-7, Casio France p.2).
  - VERIFIED (manual p.1-36, p.15-6): turn them off in Picture Plot with `SHIFT` + `MENU` (SET UP), then set `Axes: Off`, `Label: Off`, `Grid: Off` (optionally also `Coord: Off`).
  - VERIFIED (p.15-6): Grid, Axes and Label are saved into the image file when you SAVE in Picture Plot. Otherwise the setting of the file opened last time is recalled.
  - UNVERIFIED: whether "Off" carries over to a freshly opened g3p that has no stored Picture Plot data. Test this on the device.
  - VERIFIED: `FadeI/O` (lightness) must stay at 0% (p.15-3, p.5-12).
- **Memory preview edge arrows.** VERIFIED that they exist (manual p.11-6 screenshot). DERIVED positions, measured from the screenshot at about 1.75 px of print per screen pixel, ±2 px, in **screen** coordinates:
  - left "◀" arrow: x≈5-21, y≈97-114
  - right-edge "↑": x≈356-373, y≈46-62
  - right-edge "↓": x≈356-373, y≈177-188

  In 384x192 **image** coordinates, subtract 24 from y: left arrow y≈73-90; right arrows y≈22-38 and y≈153-164.

  Practical rule (DERIVED): keep **about 22 px left and right margins**, or at least keep text out of those three spots.

### 1.4 Paging speed

- **Memory app**: one key press (up or down) moves to the next or previous file's preview. VERIFIED (p.11-6).
  - DERIVED: files are listed alphabetically by their displayed 8.3 name, with folders first. Both Casio screenshots show this ordering: `FOLDER1, FOLDER2, LIST.csv, MAINMEM.g3m, Picture1.g3p, SAMPLE1.g3e` and `Chocol~1, Clock_~1, Coaste~1, Hearts, Jumpin~1, Pendulum`. So zero-padded names page in order: `Q01A.g3p, Q01B.g3p, Q02A.g3p …`.
  - UNVERIFIED: how fast a preview redraws. Mynavi says image display "is not as fast as you might hope", but that comment is about Python drawing.
- **Picture Plot**: it has **no next/previous-file key**. The function menus listed on p.15-3 have no such item, so every change of file goes back through `OPTN F1 F1`, select, `EXE`. VERIFIED by the menu listing.
- **g3b frame sequences** (VERIFIED, manual p.15-8):
  - A g3b holds **up to 30 images**.
  - To step through it in Picture Plot: `OPTN` -> `F6 (▷)` -> `F5 (PLAY)` -> `F2 (Manual)`, then left/right arrows to step frames. `F1 (Auto)` plays every frame three times. `EXIT` returns.
  - Plotting a point (`OPTN F2`, `EXE`) also advances to the next frame.
  - VERIFIED from real files (`tools/g3pdims.py`): Casio's 8 sample g3b files are 384x192, and a header field that I read as the frame count holds 9-20. The meaning of that field is my inference.
  - VERIFIED (p.11-6): the Memory app also previews a g3b. UNVERIFIED: whether it can step frames or shows only the first one.
- **Exam Mode** disables "eActivity mode; Memory mode; … Program mode; … storage memory access", plus add-ins in several exam modes. VERIFIED (manual p.β-1). **None of these viewing paths work while an Examination Mode is active.**

---

## 2. File-system rules

### 2.1 Where to put the files
- VERIFIED (p.13-3): over USB the computer sees the **storage memory** as a mass-storage drive.
- VERIFIED-COMMUNITY: the file system is FAT16 ([WikiPrizm File System](https://prizm.cemetech.net/OS_Information/File_System/)).
- **Any folder works**, root included. VERIFIED: Picture Plot "Save As" offers ROOT or any folder (p.15-7). The Picture Plot file list opens folders (p.15-3; the Casio France screenshot shows `\CASIO\g3b`). The Memory app opens folders (p.11-2).
- Folders the OS uses:
  - **`PICT`** holds Picture Memory `Pict01.g3p`…`Pict20.g3p` (p.5-21). Graph `PICT n` and **eActivity picture insertion** list only this folder (pp.5-10, 10-15). VERIFIED.
  - **`@MainMem`** mirrors main memory. Unsupported files placed there move to `SAVE-F`, and deleting the folder initialises main memory. VERIFIED (pp.13-5, 13-6, 13-7). **Never put pictures in `@MainMem`.**
  - **`CASIO`** holds Casio's sample images (`CASIO\g3p`, `CASIO\g3b`). VERIFIED (Casio France screenshot; [Cemetech CASIO-folder archive](https://www.cemetech.net/downloads/files/2356/x2777)).
- Recommendation (DERIVED): a top-level folder with an upper-case name of 8 characters or fewer, for example `SOLN`, holding the g3p files directly. Not deeper than level 3.
- UNVERIFIED (a single Cemetech report with no answer, [p=310255](https://www.cemetech.net/forum/viewtopic.php?p=310255)): a user's SourceCoder-made g3p in the PICT folder showed "no data" in Picture Plot. The cause is unknown: wrong folder, unsupported variant, or something else. **Test one generated file on the device before batch-producing.**

### 2.2 Subfolders
- VERIFIED (p.11-5): the calculator "supports nesting of folders up to three levels only". Deeper folders made on a PC are shown only to level 3 and cannot be opened.
- VERIFIED (p.13-6): after a USB session, anything past level 3 under `@MainMem` is moved to `SAVE-F`.
- VERIFIED (Casio France screenshot): Picture Plot browses subfolders, for example `\CASIO\g3b`.

### 2.3 File names
VERIFIED (manual p.11-2):

- A name longer than 8 characters is shown shortened: "AAAABBBBCC.txt > AAAABB~1.txt".
- Characters after the third in an extension are trimmed.
- Characters allowed in file and folder names: `A-Z, a-z, 0-9, !, #, $, %, ', , ( ) + – . ; = @ [ ] ^ _ ` ~ space`.
- Names typed on the calculator are limited to 8 characters (pp.5-21, 15-7). Folders created on the calculator allow only `A-Z { } ' ~ 0-9` (p.11-5).
- VERIFIED (Casio France guide p.2 screenshot): **the Picture Plot file list also shows the short form**: `Chocol~1.g3b`, `Clock_~1.g3b`, `Coaste~1.g3b`, `Jumpin~1.g3b`. Long names still open, but similar long names collapse to `Questi~1`, `Questi~2` and become unreadable.
- Recommendation (DERIVED): `[A-Z0-9_]{1,8}.g3p`, zero-padded, for example `Q01A.g3p`, `Q01B.g3p`, `Q12C.g3p`.
- Use a lower-case `.g3p` extension, which is what every Casio sample file uses. UNVERIFIED: whether `.G3P` is also accepted.

### 2.4 Number of files
- VERIFIED (p.11-2): "Up to 200 files per folder can be displayed on the storage memory information screen." Spread more than 200 across several folders.
- UNVERIFIED: the Picture Plot list limit (assume 200).
- UNVERIFIED (general FAT16 property, not checked on this device): the FAT16 root directory has a fixed number of entries (usually 512), and long names use extra entries. Another reason to put files in a subfolder and use 8.3 names.

### 2.5 Storage capacity
- VERIFIED (hardware guide spec): "Storage memory capacity: fx-CG50: 16MB (max.); fx-CG50 AU: 4.5MB (max.)". Program (main) memory is 61,000 bytes.
- VERIFIED: the manual's screenshot shows "16328 KBytes Free". The Casio France (Graph 90+E) screenshot shows about 6.58 MB free with Casio's content installed.
- VERIFIED: the Casio sample `CASIO` folder is about 6.7 MB. Deleting it frees that space; Cemetech offers a restore archive.
- Check free space with Memory -> `F2 (STRGMEM)`; the status bar shows it (p.11-2).
- VERIFIED (sizes of real files): official 16-bit 384x192 g3p files are 0.4-108 KB (`_Blank.g3p` is 374 B; photos are 12-108 KB; the compressed body is not decoded here).
- DERIVED: raw 384x192x2 bytes is 147,456 B. Even uncompressed, about 100 pictures fit in 15 MB. Mostly-white text pages should compress well (UNVERIFIED).
- VERIFIED (p.11-13; p.13-9): fragmentation is handled by Memory -> `F5 (OPT)` (optimize). The calculator may optimise automatically before a USB copy starts, which "may take several minutes".

### 2.6 Picture dimensions and colour depth
- VERIFIED (p.10-14): eActivity supports exactly two picture sizes, **384x216** (full screen, as in screen captures) and **384x192** (graph-screen pictures).
- VERIFIED (real files): every file in Casio's current sample set (`CASIO\g3p` x47 and `CASIO\g3b` x8 from the Cemetech archive) has the header triple `0x0180, 0x00C0, …`, which is **384, 192**, then 16 (bit depth) for g3p and 9-20 (frames) for g3b, at offset 0xC2 (g3p) or 0xC0 (g3b). That the field means width/height is my reading of the bytes, but the values match exactly.
  - Two sub-header variants occur among Casio's own files: `CP\0\1…` and `CP0100Ly755`. Both open on the device as shipped content.
- VERIFIED (manual p.11-6 screenshot): a 384x216 g3p (`Picture1.g3p`, "Dimension: 384*216") is also valid.
- VERIFIED-COMMUNITY: SourceCoder 3 describes g3p as "primarily used to store 384x192-pixel 3-bit and 16-bit color images" ([Cemetech news 682](https://www.cemetech.net/news.php?id=682)). KermMartian (Cemetech, 30 May 2026) says images should be no larger than 384x216 ([thread t=17803](https://www.cemetech.net/forum/viewtopic.php?t=17803&start=0)). Planete Casio reports that Casio's Picture Conversion Engine and SourceCoder output a fixed 384x192, while img2calc lets you choose the size ([Planete Casio](https://www.planet-casio.com/Fr/forums/topic16773-1-convertissez-vos-images-pour-graph-90e-en-ligne.html)).
- UNVERIFIED: how other sizes (smaller than 384x192, or odd sizes) render in Picture Plot or the Memory preview. Do not rely on them.
- Colour depth:
  - **16-bit** (RGB565, 65,536 colours) or **3-bit** (8 colours). VERIFIED: the manual says "You can insert a 16-bit g3p format file or a screen image (3-bit g3p format file)" (p.10-14). The pixel format RGB565 is VERIFIED-COMMUNITY ([WikiPrizm Display](https://prizm.cemetech.net/Technical_Documentation/Display/)).
  - Picture lightness (Fade I/O) works only with 16-bit images (VERIFIED, p.5-12).
  - Official samples are 16-bit (VERIFIED, header).

---

## 3. Transfer

### 3.1 Windows (and macOS) over USB
VERIFIED, manual pp.13-2 to 13-9:

1. Start the PC, then connect the calculator with its USB cable. The calculator turns on and shows **"Select Connection Mode"**.
2. Press **`F1` (USB Flash)**. "Preparing USB" appears; do not touch the calculator.
   - Other options: `F2` ScreenRecv, `F3` ScreenR(XP), `F4` Projector.
   - The dialog does not appear while the busy icon is shown or a figure is flashing.
3. On Windows, open the calculator drive in File Explorer (This PC). It represents the storage memory and also contains `@MainMem`.
4. Copy files with normal file operations.
5. Before unplugging, use **"Safely Remove Hardware"** and pick the "USB mass storage device" with the calculator's drive letter. On macOS, eject the drive.
6. The calculator shows **"Updating Main Memory"**, then **"Complete!"**. Press `EXIT`, then unplug.

Gotchas (VERIFIED, pp.13-7 and 13-9):
- "Copying a file to the storage memory can cause the connection … to be dropped." If that happens, run Memory -> `OPT`, then reconnect.
- Copying "may take several minutes before copying starts" because the calculator optimises storage first.
- **Never format the calculator drive from the computer.** Doing so causes "File System ERROR", which can only be fixed with Initialize All.
- PC sleep or standby can drop the connection.
- Every connection first copies main memory into storage. If storage is full, you get "Storage Memory Full" and nothing is copied.
- No "refresh" step is needed for pictures: storage-memory files are the files on the drive. The "Updating Main Memory" step applies only to `@MainMem` content. (DERIVED from pp.13-3 to 13-6.)

Other details:
- The OS-version systems listed in the v3.60 manual are Windows 8.1/10 and macOS 10.13-11. UNVERIFIED for Windows 11, but mass storage needs no driver.
- VERIFIED-COMMUNITY: WikiPrizm says file management works "without the use of additional software or drivers … registers as a Mass-Storage Device".
- VERIFIED: Casio UK recommends OS **3.80**, which "improves USB communication" ([Casio UK OS](https://education.casio.co.uk/support/os-files/os-files-cg50-os/)).
- UNVERIFIED (retailer and third-party listings, not Casio): the calculator port is mini-USB (Mini-B). The hardware guide says only "USB 2.0" and "USB connector that comes with the fx-CG50".

### 3.2 iPhone with USB-C (Files app)
UNVERIFIED. I found no first-hand report for iPhone or iPad.

- VERIFIED (Apple, from a search-result snippet; the page body did not load): iPhone Files accepts external drives with a single data partition formatted APFS, HFS+, exFAT, FAT32 or **FAT**. On USB-C models, Files can also **erase/reformat** a drive. Source: [Apple: Connect external storage devices to iPhone](https://support.apple.com/guide/iphone/external-storage-devices-iph95baac91f/ios).
- VERIFIED-COMMUNITY: the calculator presents a FAT16 USB mass-storage device. Together with Apple's list, this is a plausible match.
- UNVERIFIED (search snippet; the page returned 403): one HP Museum forum user says a USB-C adapter lets an **Android** phone "explore the filesystem" of a CG50 ([HP Museum thread-22505](https://www.hpmuseum.org/forum/thread-22505.html)).
- UNVERIFIED unknowns for iPhone: whether the iPhone supplies enough power or the right handshake to start the calculator's "Select Connection Mode", and whether the mount works at all. Casio's own page says "You will need a Windows or Mac PC" ([Casio UK transfer](https://education.casio.co.uk/support/os-files/os-files-cg50-transfer-files/)).
- iPhone-specific gotchas:
  - **Never tap Erase on the calculator drive** in Files. This is the "never format" rule above (VERIFIED for computers).
  - iOS Files has historically had **no eject command**. AppleVis users say to unplug once no copy is in progress (UNVERIFIED, [AppleVis](https://applevis.com/forum/ios-ipados/ejecting-usb-flash-drive-iphone)). The calculator may then skip its normal "Updating Main Memory" step. For storage-only picture copies this is probably harmless, but it is untested.
  - Apple systems may write hidden metadata files (`._*`, `.DS_Store`). The Casio sample archive itself contains a `.DS_Store` made on a Mac (VERIFIED). These show up on the calculator as unsupported files and use space. UNVERIFIED whether iOS writes them.
- Recommended test (DERIVED): copy one 384x192 g3p, wait, unplug, then check it in the Memory app and Picture Plot. If the drive is not detected, use a Windows or Mac PC.

---

## 4. Text readability on the 3.17-inch, 384x216 screen

### 4.1 Physical scale
- VERIFIED-COMMUNITY: retailers and a search snippet of Casio's comparison page give a **3.17-inch** diagonal (the Casio page itself returned 403). Example: [myworksupply listing](https://myworksupply.com/products/casio-prizm-fx-cg50-graphing-calculator-black-fx-cg50) ("3.17-inch … LCD … over 82,000 pixels", which is 384x216 = 82,944).
- VERIFIED-COMMUNITY: the LCD panel is 396x224 with a central 384x216 window ([WikiPrizm Display](https://prizm.cemetech.net/Technical_Documentation/Display/)).
- DERIVED: pixel pitch = 3.17 in x 25.4 / √(384²+216²) = **0.183 mm (≈139 ppi)**. The full 384x216 window is about 70 x 39.5 mm, and the 384x192 picture area is about **70 x 35 mm**.
- VERIFIED: Casio warns that "graphic images may not appear as they do on your computer display in terms of color" (hardware guide, Precautions). Brightness can be set from 1 to 5 in System.

### 4.2 Casio's own fonts
VERIFIED-COMMUNITY ([WikiPrizm Fonts](https://prizm.cemetech.net/OS_Information/Fonts/)), with cap heights DERIVED by measuring the manual screenshot in `render/crop429.png`:

| OS font | Cell or line pitch | Use | Lines per full 216 px screen | Measured cap/digit height |
|---|---|---|---|---|
| "24 px" fixed width, 18 px wide | 24 px | Home-screen text, System menu, DETAIL screen | 9 (so 7 text lines between status bar and F-key bar; 21 characters per line) | about 18-19 px |
| "18 px" proportional | 18 px | Status bar, eActivity line notes | 12 | about 13 px; digit advance about 11 px |
| "16 px" proportional | 16 px | Main-menu app names | (13.5) | not measured |
| "10 px" proportional | 10 px | Graph axis numbers (smallest OS text) | 21 | not measured; about 7 px (guess) |

DERIVED: Casio considers about 13 px caps (status bar) normal reading text, and uses the 10 px font only for axis numbers.

### 4.3 Legibility thresholds converted to pixels
- VERIFIED secondary source: "The minimum easily readable character height is 16 minutes of the visual arc and the optimal character height is 20 minutes", citing MIL-PRF-87268D ([Activu, Optimal Font Size](https://activu.com/uploads/Optimal-Font-Size.pdf)).
- DERIVED: cap heights at 0.183 mm/px:

| Viewing distance | 16′ (minimum) | 20′ (optimal) | 22′ |
|---|---|---|---|
| 30 cm | 7.6 px | 9.6 px | 10.5 px |
| 35 cm | 8.9 px | 11.1 px | 12.3 px |
| 40 cm | 10.2 px | 12.7 px | 14.0 px |

**Design guidance** (DERIVED; test on the device):
- Main text and equations: **cap height of 11 px or more** (font em about 15-16 px), line pitch about 18-20 px. That gives **9-10 lines** in 192 px and about 40-48 characters per 384 px line, assuming the usual 0.5-0.6 em average advance.
- Dense minimum: cap height of about **9 px** (em about 12-13 px), line pitch about 14-15 px. That gives **12-13 lines** and about 55-60 characters per line.
- Superscripts, subscripts and fraction parts should still have caps of about 7 px or more. Do not go below Casio's 10 px axis font for anything you must read.
- **Never shrink a whole PDF page to fit.**
  - A full A4/Letter page shrunk to 384 px wide is about 1.8 px/mm, so 10-11 pt body text (cap about 2.5 mm) becomes about 4-5 px tall. Unreadable.
  - Reaching an 11 px cap needs about 4.4 px/mm (about 112 dpi). At that scale 384 px covers only about 87 mm of the page, roughly 40% of the page width.
  - So the content must be **re-flowed or re-typeset into 384x192 screens**, or cropped into narrow regions. Do not scale it down.
- Contrast: pure black on white, with at most one dark accent colour (for example dark blue or dark red) for the final answer. Avoid yellow, cyan or light grey on white. (DERIVED, based on Casio's colour warning.)
- Anti-aliasing:
  - 16-bit g3p can hold greyscale anti-aliasing (RGB565, VERIFIED-COMMUNITY). Render text directly at the target pixel size rather than downscaling a large render, to avoid blur.
  - DERIVED: RGB565 has 5-bit R/B and 6-bit G, so some greys gain a faint green or magenta tint. Pure black and white are exact.
  - A 3-bit (8-colour) g3p cannot anti-alias, so text must be crisp, bitmap or thresholded.
- Margins: at least 2-4 px of white on every edge. About 22 px left and right if the Memory preview will be used (section 1.3).

### 4.4 Community advice and existing tools
- I found **no community guide** on font sizes for notes or cheat-sheet images on the CG50. Searches of Cemetech and Planete Casio returned only conversion how-tos. The thresholds above are therefore derived, not crowd-tested.
- Existing converters (all take an image as input; **none found that converts a PDF or document end to end**):
  - **SourceCoder 3** (Cemetech, web). Reads PNG/GIF/BMP, writes 3-bit or 16-bit g3p, and can also turn a g3p into PNG. VERIFIED-COMMUNITY ([news 682](https://www.cemetech.net/news.php?id=682), [sc](https://www.cemetech.net/sc/)). Its output is reported as 384x192.
  - **img2calc** (TI-Planet, web). Writes g3p in "CP" or "CP0100" colour formats with a selectable size. VERIFIED-COMMUNITY ([Planete Casio thread](https://www.planet-casio.com/Fr/forums/topic16773-1-convertissez-vos-images-pour-graph-90e-en-ligne.html)). Its code has no stated licence.
  - **Casio Picture Conversion Engine** (official). Converts pictures or video to g3p/g3b. v2.00 for Windows 10/11 needs QuickTime 7 and an access key; v1.01 exists for Windows and Mac.
    - VERIFIED-COMMUNITY ([Cemetech t=17803](https://www.cemetech.net/forum/viewtopic.php?t=17803&start=0)). The download page is from a search snippet: [edu.casio.com form](https://edu.casio.com/download_service/download/private/form.html).
    - Users report download and activation problems.
  - **Add-ins that skip g3p entirely**: gbl08ma's "JPEG and PNG image viewer" (fx-CG50 supported, zoom, long file names, can also be an eActivity strip; no progressive JPEG or interlaced PNG; one user notes images cannot be fitted to the screen). VERIFIED-COMMUNITY ([Cemetech 1153](https://www.cemetech.net/downloads/files/1153/x1153)). The same author's "Utilities" add-in has a JPEG viewer and a text reader (search snippet; [Cemetech 934](https://www.cemetech.net/downloads/files/934/x934)).

---

## 5. Alternatives (brief)

- **eActivity (.g3e)**. VERIFIED (manual ch.10):
  - Text lines hold up to 255 bytes each and wrap. The workspace scrolls with up/down; JUMP offers TOP, BOTTOM, PageUp and PageDown.
  - Picture lines take 384x216 or 384x192 g3p files from the PICT folder, one per line, viewed through a 384x168 window.
  - File names are 8 characters.
  - The first use of eActivity needs at least 128 KB of memory.
  - Building a .g3e on a PC needs the .g3e format, which I did not research. Disabled in Exam Mode.
- **Casio BASIC viewer**. VERIFIED that the commands exist:
  - A program can turn off axes and labels, then `RclPict "SOLN\Q01A.g3p"` on key presses (`Getkey`).
  - A program can be written on the PC as a .txt file in `@MainMem\PROGRAM`, which is converted to a program on disconnect (p.13-7).
  - UNVERIFIED: whether this beats the Memory preview for speed and screen area.
- **Add-ins** (`.g3a`, copied to the drive root, VERIFIED p.13-8): JPEG/PNG viewer, Utilities. Blocked in most Exam Modes.
- **Python (casioplot)**: drawing pictures pixel by pixel is slow, and scripts are limited to 255 characters per line and 300 lines (Mynavi). Not worth it.
- **Capture memory** (`SHIFT` + `7` (CAPTURE), 20 slots, 384x216 including the status bar; recalled with `RclCapt` or Run-Matrix). Lives in main memory and needs no transfer path. Not useful for importing pictures.

---

## Sources

Casio (official):
- fx-CG50 Software User's Guide v3.60 (PDF; pages cited are 1-5, 1-36, 1-39, 5-10, 5-12, 5-20/21/22, 8-32/33/58, 10-2, 10-4/5, 10-14/15, 11-1 to 11-6, 11-13, 13-2 to 13-9, 14-8, 15-1 to 15-8, β-1): https://education.casio.co.uk/app/uploads/2022/08/fx-CG50-Software-User-Guide.pdf (landing page: https://education.casio.co.uk/resources/manuals/fx-CG50-User-Guide/)
- fx-CG50 Hardware User's Guide (specifications, LCD precautions): https://education.casio.co.uk/app/uploads/2022/08/fx-CG50-Hardware-User-Guide.pdf
- Casio France "Plot Image" guide (screenshots of the file list with ~1 names, folders, OPTN menu, axes overlay): https://www.casio-education.fr/wp-content/uploads/2020/10/guide-plot-image.pdf
- Casio UK fx-CG50 OS 3.80 page: https://education.casio.co.uk/support/os-files/os-files-cg50-os/
- Casio UK fx-CG50 add-ins (Picture Plot is an add-in): https://education.casio.co.uk/support/os-files/os-files-cg50-add-ins/
- Casio UK transfer-files page ("Windows or Mac PC"): https://education.casio.co.uk/support/os-files/os-files-cg50-transfer-files/
- Casio comparison page (3.17", 384x216, 16 MB; seen only as a search snippet, the page returned 403): https://www.casio.com/ca-en/calculators/comparison
- Casio edu download form (Picture Conversion Engine; search snippet only): https://edu.casio.com/download_service/download/private/form.html

Real files inspected:
- Casio sample `CASIO` folder (47 g3p + 8 g3b), archived by Cemetech: https://www.cemetech.net/downloads/files/2356/x2777 (archive https://www.cemetech.net/downloads/files/x2777/download). Headers were read with `tools/g3pdims.py`; nothing was executed from the download.

Community references:
- WikiPrizm: Fonts https://prizm.cemetech.net/OS_Information/Fonts/ · Display https://prizm.cemetech.net/Technical_Documentation/Display/ · File System https://prizm.cemetech.net/OS_Information/File_System/ · PrintMini https://prizm.cemetech.net/Syscalls/PrintMini/ · PrintMiniMini https://prizm.cemetech.net/Syscalls/PrintMiniMini/ · PrintXY https://prizm.cemetech.net/Syscalls/PrintXY/ · EnableStatusArea https://prizm.cemetech.net/Syscalls/EnableStatusArea/ · Printing Text https://prizm.cemetech.net/Tutorials/Printing_Text/
- Cemetech: SourceCoder g3p news https://www.cemetech.net/news.php?id=682 · g3p reverse-engineering intro https://www.cemetech.net/news/2014/8/684/_/a-brief-reverse-engineering-tutorial-with-the-g3p-format · Picture Conversion Engine thread https://www.cemetech.net/forum/viewtopic.php?t=17803&start=0 · "no data" report https://www.cemetech.net/forum/viewtopic.php?p=310255 · Memory-app g3p view https://cemetech.net/forum/viewtopic.php?p=302517 · JPEG/PNG viewer https://www.cemetech.net/downloads/files/1153/x1153 · Utilities https://www.cemetech.net/downloads/files/934/x934 · SourceCoder https://www.cemetech.net/sc/
- Planete Casio img2calc thread: https://www.planet-casio.com/Fr/forums/topic16773-1-convertissez-vos-images-pour-graph-90e-en-ligne.html
- Mynavi (384x192 displayable image size): https://news.mynavi.jp/techplus/article/calcpython-10/
- HP Museum (Android OTG anecdote; search snippet only, 403): https://www.hpmuseum.org/forum/thread-22505.html
- Retail listing for the 3.17" figure: https://myworksupply.com/products/casio-prizm-fx-cg50-graphing-calculator-black-fx-cg50

Legibility and iOS:
- Activu "Optimal Font Size" (16′ minimum and 20′ optimal, citing MIL-PRF-87268D): https://activu.com/uploads/Optimal-Font-Size.pdf
- Apple: Connect external storage devices to iPhone (file systems, erase; search snippet): https://support.apple.com/guide/iphone/external-storage-devices-iph95baac91f/ios
- AppleVis: ejecting a USB drive on iPhone (search snippet): https://applevis.com/forum/ios-ipados/ejecting-usb-flash-drive-iphone
