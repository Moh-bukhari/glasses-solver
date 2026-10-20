> Research notes from 2026-10-20 (2.7). Local paths refer to the research working folder, which is not in the repository; the sources are cited by URL. The app's writer is `samples/CameraAccess/CameraAccess/Solver/G3P.swift`, tested against Casio's `_Blank.g3p` in `CalculatorPictureTests`.

# Casio fx-CG10/20/50 (Prizm) picture formats: `.g3p` and `.g3b`, byte layout

Research date 2026-10-20. Every claim carries a tag:

- **[V-real]**: verified against all 55 real Casio-made files (47 `.g3p` + 8 `.g3b`, see §2). That includes a byte-exact rebuild of every file with the reference encoder in §11.
- **[V-doc]**: stated by a primary or community spec, or by a reference implementation, and consistent with the real files where they can be checked.
- **[UNVERIFIED]**: comes only from documents or code, with no real file to check it against, or it is my inference. Each one is labelled.

Nothing in this file has been tested on physical calculator hardware. §13 lists the device checks that are still open.

---

## 0. Encoder recipe

This recipe reproduces Casio's own "CP, no footer, encrypted" picture byte-for-byte. Casio's `_Blank.g3p`, `Cans.g3p` and 11 other files are written exactly this way. **[V-real]**

```
pixels  = 384*192 RGB565 big-endian words, row-major, top row first        (147456 bytes)
z       = zlib.compress(pixels, 6)          # RFC1950: 78 9C + deflate + Adler-32(pixels) BE
zo      = bytes(NOT(rotl8(b,3)) for b in z) # Casio payload "crypt", whole stream incl. 78 9C and Adler
FS      = 0xD0 + len(zo)                    # total file length
file    = NOT-each-byte(std_header_decoded(FS))            # 0x00..0x1F, see §3
        + b"CP\x00\x01" + 12*b"\x00"                       # 0x20
        + BE32(FS-0x20)                                    # 0x30
        + BE32(0x00000001)                                 # 0x34 section mask: slot 0 only
        + BE32(0x18+len(zo)) + 31*BE32(0)                  # 0x38..0xB7 section-size table
        + 00 01 00 00                                      # 0xB8
        + BE32(4+len(zo))                                  # 0xBC
        + 00 00  01 80  00 C0  00 10                       # 0xC0: 0, width 384, height 192, depth 16
        + 01 00 00 00                                      # 0xC8
        + BE32(len(zo))                                    # 0xCC
        + zo                                               # 0xD0
```

Decoded standard header (before the NOT), using `b2 = (FS>>8)&0xFF` and `b3 = FS&0xFF`:

```
"USBPower" 7D 00 10 00 10 00 | (b3+0x41) | 01 | BE32(FS) | (b3+0xB8) | FF*7 | (0x7D+b2+b3+0xE9) | (b3+0x7B) | FF FF
```

All sums are taken mod 256. Python code that does this is in `tools/g3p_encode.py` (§11). It reproduces all 55 Casio files.

---

## 1. Sources

All local copies are under `dl/`.

| # | Source | What it is | Local copy |
|---|---|---|---|
| S1 | Simon Lothar, "fx-CG20, G3P": https://bible.planet-casio.com/simlo/chm/v20/fxCG20_G3P.htm | Primary community spec. Covers the standard header, the G3P subheader table and the encryption-detection rule. It also says the fx-CG10 accepts only encrypted images. Dated 01.08.2014. | `simlo-g3p/fxCG20_G3P.htm` |
| S2 | Simon Lothar, "fx-CG20, Bfile": https://bible.planet-casio.com/simlo/chm/v20/fxCG20_Bfile.htm | Syscalls 0x0C0F (FileHeader_Prepare) and 0x0C12 (FileHeader_CheckControlBytes) | `simlo-bfile/fxCG20_Bfile.htm` |
| S3 | Simon Lothar syscall list: https://bible.planet-casio.com/simlo/chm/v20/fx_fxCG20_syscalls.htm | Names of the OS functions involved: 0x0E92 `G3P_crypt(buf,count,mode)`, 0x100F `LoadG3P`, 0x1009 `SaveG3P`, 0x0E57/0x0E5B/0x0E5C `Check_G3P_*`, 0x117A-C `Open/Perform/CloseInflate`, 0x0901/09/0A `*Deflate` | `simlo-g3p/fx_fxCG20_syscalls.htm` |
| S4 | KermMartian, "A Brief Reverse-Engineering Tutorial with the g3p Format" (Cemetech, 13 Aug 2014): https://www.cemetech.net/forum/viewtopic.php?p=222580 (thread t=10560). News versions: https://www.cemetech.net/news.php?id=684 and https://www.cemetech.net/news.php?id=682 | Hex dumps of real `Beach.g3p` and `Books.g3p`, the stored-byte control formulas, the crypt bit diagram, and the Adler-32 finding | `cemetech-t10560/p222580.html` |
| S5 | libcasio by Thomas "Cakeisalie5" Touhey (2017), fork https://github.com/Lailouezzz/libcasio @ `835f4605110c1389cd7b90801357a8afd4f8f194`. Files: `include/libcasio/format/std.h`, `include/libcasio/format/std/picture.h`, `lib/file/decode/std.c` (lines ~120-275), `lib/file/decode/std/picture.c`, `lib/picture/decode.c` (lines 32-42, 181-195) | C decoder, plus the 3-bit palette and nibble order | `Lailouezzz_libcasio/repo` |
| S6 | TI-Planet img2calc (critor, Adriweb): https://github.com/TI-Planet/img2calc @ `460b775be40a10404b9b14b25727873472b7aea2`. `index.html` lines 1708-1941 (`handleOutImgCP`), `palcp.png` | JS encoder for 4 g3p variants (cp, cp_i, cp01, cp01_i), live at https://tiplanet.org/forum/img2calc.php | `TI-Planet_img2calc/repo` |
| S7 | OmniPlotter: https://github.com/danieletoniolo/OmniPlotter @ `8f7947f6f7992f2073b1894e58c924f012236904`. `src/main/java/.../encoder/CasioPictureEncoder.java` | A Java port of S6. It checks byte-equality against img2calc and does not check against real Casio files. | `danieletoniolo_OmniPlotter/repo` |
| S8 | CasPCE: https://github.com/mdanishharoon/CasPCE @ `2bced93b606c7ad7edd9d9487f4e048dd9f7a62b`. `g3p_converter/g3p.py`, `src/g3p.js` | Python/JS encoder for the "3C1B, no footer" variant. It follows S4's formulas. | `mdanishharoon_CasPCE/repo` |
| S9 | Cahute docs: https://github.com/cahute/cahute @ `9b8a4158c5021cbcd9c8a8cad012233ed9f9e16e`, `docs/topics/file-formats/container.rst` and `picture-cg.rst`, rendered at https://cahuteproject.org/topics/file-formats/picture-cg.html | The container table. Cahute marks the g3p page itself "Todo". | `cahute_cahute/repo`, `cahute-doc/` |
| S10 | **Real files.** "The CASIO folder!", Cemetech archive 2356, exported from Casio's fx-CG50 emulator: https://www.cemetech.net/downloads/files/2356 (zip at https://www.cemetech.net/downloads/files/x2777/download, sha256 `7ce34692d9d04a2da4c640fb5db38d307ab4d64641e45646027f28022ea2e41d`) | 47 `.g3p` and 8 `.g3b`, made by Casio. They are Casio's built-in Picture Plot/Geometry pictures. | `cemetech-2356-zip/`, extracted to `cemetech-2356-x/CASIO/{g3p,g3b}/` |
| S11 | Casio, fx-CG50/CG20/CG10 Software User's Guide (CG50 OS 3.60): https://education.casio.co.uk/app/uploads/2022/08/fx-CG50-Software-User-Guide.pdf | Official behaviour: PICT folder, 16-bit vs 3-bit, g3b holds at most 30 images, viewers | `g3p-casio-manual/` |

**Provenance check on S10. [V-real]** S4 published hex dumps of `Beach.g3p` in 2014, from an fx-CG10/20. They are identical to `Beach.g3p` in S10, a 2023 export from the CG50 emulator:

- the first 0x20 bytes;
- `0x30: 00 00 AD C4 00 00 00 01 00 00 AD 2C`;
- `0xB8..0xDF`;
- the stored trailer `85 6A D4 D5`.

S4's `Books.g3p` values also match S10: data length `00 01 70 F5` and checksum `E3 6C F4 79`. Casio has therefore shipped the same bytes across CG10, CG20 and CG50.

The following could not be fetched: omnimaga.org threads (HTTP 403), edu.casio.com (HTTP 403) and web.archive.org (connection reset). The old WikiPrizm g3p page returns 404.

---

## 2. Real-file corpus (S10)

- **47 `.g3p`.** All are 384x192, 16-bit and encrypted. Every one passes all the checks below. There are two tag variants:
  - 24 files tagged `"CP\0\x01"`. 23 of them have no footer (mask 0x1) and 1, `Arches.g3p`, has one footer (mask 0x9). The zlib header is `78 9C`; stored obfuscated it reads `3C 1B`.
  - 23 files tagged `"CP0100Ly755"`, with 3 footers (mask 0xA09). The zlib header is `38 8D`; stored it reads `3E 93`.
- **8 `.g3b`**, each with 9 to 20 frames. All are 384x192, 16-bit, tagged `"CP\0\x01"`, mask 0x492 (image section in slot 1 plus 3 footers), and use `78 9C` streams.
- The per-file table is in the Appendix.
- The library has no 3-bit (depth 3) files and no unencrypted files. Those parts of the layout are **[UNVERIFIED]** against real files.

---

## 3. Standard header, 0x00-0x1F (32 bytes, stored bitwise-NOT)

The file stores `~d[i]` for these 32 bytes only. Everything from 0x20 on is stored plainly (S1, S5, S9). **[V-real]**

`FS` is the total file length. `b2 = (FS>>8)&0xFF` and `b3 = FS&0xFF`, both taken from the plain size. All arithmetic is mod 256.

| Off | Size | Decoded value `d` | Stored bytes | Meaning / formula | Status |
|---|---|---|---|---|---|
| 0x00 | 8 | `"USBPower"` | `AA AC BD AF 90 88 9A 8D` | File identifier | V-real (all 55); S1, S4 |
| 0x08 | 1 | `0x7D` | `82` | Type byte: picture. `.g3b` uses the **same** 0x7D, so the file extension tells g3p from g3b. A `.g3m` program has 0x75, stored 0x8A. | V-real; S1, S4, S9 |
| 0x09 | 5 | `00 10 00 10 00` | `FF EF FF EF FF` | Constant | V-real; S1 |
| 0x0E | 1 | `b3 + 0x41` | stored form: `S13 + 0xBF` | Control byte 1 | V-real; S1, S2, S5 |
| 0x0F | 1 | `0x01` | `FE` | Constant. S9 says `\0`, which is wrong for g3p. | V-real; S1, S2 |
| 0x10 | 4 | BE32 `FS` | `~FS` | Total file size, big-endian | V-real |
| 0x14 | 1 | `b3 + 0xB8` (= `b3 - 0x48`) | `S13 + 0x48` | Control byte 2 | V-real; S1, S2 |
| 0x15 | 7 | `FF`x7 | `00`x7 | Unused. FileHeader_Prepare pre-fills 0xFF (S2). | V-real |
| 0x1C | 1 | encrypted: `0x7D + b2 + b3 + 0xE9` | `S12 + S13 + 0x9B` (S4) = `0x99 - b2 - b3` | Encryption marker; see §3.1 | V-real (55/55) |
| 0x1D | 1 | encrypted: `b3 + 0x7B` | `S13 + 0x85` (S4) = `0x84 - b3` | Companion byte | V-real (55/55) |
| 0x1E | 2 | `FF FF` | `00 00` | S9 calls this an "object count". For pictures the stored value is always 00 00. | V-real |

`Sxx` means the stored (inverted) byte at offset xx, so `S12 = ~b2` and `S13 = ~b3`. The stored-byte formulas are S4's. S4's prose writes "+0x85" for 0x0E, but its own table gives 0xBF; the prose is a typo, and the real files use 0xBF.

### 3.1 Encrypted versus unencrypted payload

**OS rule (S1, S2, syscall 0x0C12):** the payload is encrypted iff `d[0x1C] != d[0x08] + d[0x12] + d[0x13] + 0x7B`.

**[V-doc]** S1 also says: *"On the fx-CG10, only encrypted images are allowed."* S4 says the no-footer CP variant loads on both the CG10 and the CG20.

| Field | Encrypted (Casio files) | Unencrypted |
|---|---|---|
| Decoded `0x1C` | `0x7D + b2 + b3 + 0xE9`. This is the "unencrypted" value + 0x6E, so it never collides. **[V-real]** | `0x7D + b2 + b3 + 0x7B`, from S1/S2. Stored: `(7 - b2 - b3)`, which is exactly what S6's `cp01` variant writes. **[UNVERIFIED: no real unencrypted file found]** |
| Decoded `0x1D` | `b3 + 0x7B` **[V-real]** | `b3 + 0xE9` (stored `0x16 - b3`), from S6 `cp01` only. S1 says the OS overwrites 0x1D during the check, so it is probably not validated. **[UNVERIFIED]** |

**Inference [UNVERIFIED]:** the OS comparison must be mod 256. `0x7D + 0x7B` already exceeds 0xFF. Casio's unencrypted converter output, as described by S6, still loaded on the CG20.

---

## 4. Picture header and section table, 0x20-0xB7 (plain, big-endian)

| Off | Size | Value | Meaning | Status |
|---|---|---|---|---|
| 0x20 | 16 | `43 50 00 01` + 12x`00` ("CP\0\x01") **or** `"CP0100Ly755"` + 5x`00` | Variant tag. S1 says "CP" is checked by syscall 0x0E5B. Not seen in g3p: S6 writes `"CP0100Cy875"` for the fx-CG100 `.g4p`. | V-real (24 + 8 files use CP\0\x01, 23 use CP0100Ly755) |
| 0x30 | 4 | BE32 `FS - 0x20` | Bytes after the standard header | V-real; S4 |
| 0x34 | 4 | BE32 section bitmask | Bit *i* set ⇔ slot *i* present. Seen: `0x1`, `0x9`, `0xA09`, `0x492` (g3b). S1 shows `0x0009`. S4 calls this "always 1", which only holds for the no-footer variant. | V-real |
| 0x38 | 128 | 32 x BE32 | Byte length of section *i* at `0x38 + 4*i`, 0 if absent. Sections follow back-to-back from **0xB8**, in increasing slot order. `0xB8 + Σ len = FS` for all 55 files. | V-real |

For a g3p, slot 0 is the image section, so `0x38 = 0x18 + PDL`. This equals S4's `FS - 0xB8` only when there is no footer. S6's `0x44` "footer length" is simply slot 3.

---

## 5. Image section in a `.g3p` (slot 0, always at 0xB8)

| Off | Size | Value | Meaning | Status |
|---|---|---|---|---|
| 0xB8 | 4 | `00 01 00 00` (CP tag) / `30 31 30 30` "0100" (CP0100 tag) | Section magic. It matches the tag variant. | V-real (24/23) |
| 0xBC | 4 | BE32 `4 + PDL` | Bytes from 0xCC to the end of the section. S4's "FS - 0xCC" holds only without a footer. | V-real |
| 0xC0 | 2 | `00 00` | Unknown, always 0 | V-real (47/47) |
| 0xC2 | 2 | BE16 width | 0x0180 = 384 | V-real |
| 0xC4 | 2 | BE16 height | 0x00C0 = 192 | V-real |
| 0xC6 | 2 | BE16 depth code | `0x0010` = 16-bit RGB565; `0x0003` = 3-bit (S1 calls it "4-bit color") | 0x10 V-real; 0x03 V-doc only |
| 0xC8 | 4 | `01 00 00 00` | Unknown, constant | V-real (47/47); S4 |
| 0xCC | 4 | BE32 `PDL` | Length of the stored zlib stream, including its 2-byte header and 4-byte Adler trailer | V-real; S1 |
| 0xD0 | PDL | obfuscated zlib stream | §6, §7 | V-real |
| 0xD0+PDL | ... | optional footer sections (slots ≥ 1) | §9 | V-real |

There is **no** file-level checksum or trailer after the last section; the file ends exactly at `0xB8 + Σ section lengths`. **[V-real]** The g3a add-in format does have a trailing checksum per S5, but g3p does not.

---

## 6. Payload obfuscation (Casio "G3P_crypt", syscall 0x0E92)

**[V-real] on all 47 g3p streams and 114 g3b frame streams.** It is also described by S4 and S5, and written by S6 and S8.

- **Encode** each byte: `o = ~rotl8(p, 3) & 0xFF`. That is: rotate left by 3, then NOT. The order does not matter, because NOT commutes with rotation.
- **Decode** each byte: `p = rotr8(~o & 0xFF, 3)`, equivalently `((~o)<<5 | (~o)>>3) & 0xFF`.
- **No key and no XOR schedule.** It is a fixed, position-independent byte bijection, and `NOT` is XOR 0xFF.
- **What it covers:** the whole zlib stream, meaning the 2-byte zlib header, the deflate data and the 4-byte Adler-32. It does **not** cover the BE32 length field at 0xCC or any header or section field.
- In a g3b it is applied separately to each frame's stream.
- **Examples:** `78→3C`, `9C→1B`, `38→3E`, `8D→93`. So stored `3C 1B` is an obfuscated `78 9C`, and stored `3E 93` is an obfuscated `38 8D`.
- S5 and S6 call `3C1B`, `3E93`, `388D` and `789C` "generator IDs". They are just obfuscated or plain zlib headers.

---

## 7. Compression and checksum

**[V-real]**

- The stream is a standard zlib stream (RFC 1950): CMF/FLG header, then raw DEFLATE (RFC 1951), then **Adler-32 of the uncompressed pixel bytes, big-endian**.
- Python's `zlib.decompress` (default wbits=15, which checks the header and the Adler) succeeds on all 161 streams (47 g3p + 114 g3b frames), and every one inflates to exactly 147456 bytes.
- The "cryptographic signature" in S4 and the Cemetech news is just this Adler-32. S4 also notes that a wrong checksum gives a blank image, not a rejected file. **[V-doc]**
- Headers seen:
  - `78 9C`: 32 KiB window, FLEVEL 2. Used by the CP-tag g3p and all g3b frames.
  - `38 8D`: 2 KiB window, FLEVEL 2. Used by the CP0100 g3p.
- The calculator's inflater accepts both windows. **[V-real by inference]** Casio ships both.
- Reproducibility with CPython's zlib:
  - `zlib.compress(raw, 6)`, i.e. `compressobj(6, DEFLATED, 15, 8)`, reproduces Casio's stream byte-for-byte for 8/24 `78 9C` g3p and 3/8 g3b files.
  - `compressobj(6, DEFLATED, 11, 5)` reproduces all 23/23 `38 8D` files.
  - The rest were made by another deflater: the first difference is at stream byte 3, inside the Huffman tables. They are still standard zlib.
- Raw DEFLATE alone is **not** what Casio stores. S8 writes the obfuscated header `3C 1B` by hand, then a level-9 raw deflate, then the Adler. That is equivalent, because inflate ignores the FLEVEL bits.

---

## 8. Pixel formats and dimensions

### 16-bit, depth code 0x0010

**[V-real]**

- RGB565, one big-endian 16-bit word per pixel: R in bits 15-11, G in bits 10-5, B in bits 4-0.
- Row-major, top row first, left to right, with no row padding. Size is `w*h*2`, which is 147456 bytes for 384x192.
- I checked this by rendering `Clocks.g3p` and `Floorplan.g3p` to PNG (`out/Clocks.png`, `out/Floorplan.png`). The clock digits read correctly, so the image is not mirrored or flipped, and the colours look natural, so R and B are not swapped.
- S6 and S8 pack pixels the same way.

### 3-bit, depth code 0x0003

**[UNVERIFIED: no real file obtained]**

- Two pixels per byte, high nibble first (the left pixel). The packing runs continuously across rows, so the size is `ceil(w*h/2)` = 36864 bytes for 384x192.
- Nibble value = `R<<2 | G<<1 | B`:

  | Value | Colour |
  |---|---|
  | 0 | black |
  | 1 | blue |
  | 2 | green |
  | 3 | cyan |
  | 4 | red |
  | 5 | magenta |
  | 6 | yellow |
  | 7 | white |

- Sources: S5 `lib/picture/decode.c` (palette and nibble order); S6 `palcp.png`, whose 8 colours appear in exactly that order; and S4, which says "two pixels per byte".
- S11 says on-calc screen captures are 3-bit g3p, and that eActivity accepts "a 16-bit g3p format file or a screen image (3-bit g3p format file)".
- S4's examples Pict01/02/04 were 3-bit, with stored header `3E93`.

### Dimensions

- Every real Casio g3p and g3b is **384x192**. **[V-real]**
- S1 gives width and height only "f. i." (for instance) as 0x0180/0x00C0. S6 allows any canvas up to 384x192, and S5 decodes any size.
- **[UNVERIFIED]** whether, and where, a CG50 displays a picture that is not 384x192. Use exactly 384x192.

---

## 9. Footer sections (optional metadata; copy verbatim or omit)

Each footer section starts with a 4-byte magic, either `"0100"` (ASCII) or `00 01 00 00`, then BE32 = remaining bytes in the section. **[V-real]**

- **g3p slot 3 / g3b slot 4 (140 B).**
  - Header `+0x84`, then 11 x 12-byte Casio BCD reals. Examples: `10 06 30..` = 6.3, `60 06 30..` = -6.3, `10 01..` = 1.
  - This is the saved V-Window. S11 pp. 5-10 and 5-20 say the V-Window is stored with the g3p.
  - The field-by-field mapping is **[UNVERIFIED]**.
- **g3p slot 9 (44 B).** More BCD values; meaning unknown.
- **g3p slot 11 (184-212 B).** `00 01 00 CE ...`. It contains the original path, for example `\\fls0\EU\bugle.g3p`, plus Picture Plot settings. S11 p. 15-5 says Picture Plot "plot data" is added to the image file.
- **g3b slot 7 (44 B).** Contains ASCII `PGTime`.
- **g3b slot 10 (16 B).** `"0100" 00000008 00 05 04 05 00 01 00 00`.
- 23 of 47 Casio g3p have no footer at all (mask 0x1). **For a still picture you can omit every footer.** **[V-real]** S4 also states this variant loads on the CG10 and CG20.

---

## 10. `.g3b` (flipbook / animation) differences

Everything from 0x00 to 0x37 is the same as g3p: decoded type 0x7D, the same control bytes and the same 0x1C/0x1D rule. The tag is `CP\0\x01`. **[V-real, 8/8]**

| Off | Size | Value | Notes |
|---|---|---|---|
| 0x34 | 4 | `0x00000492` | Slots 1, 4, 7, 10. **The image section is slot 1**, not 0, and still starts at 0xB8. |
| 0x3C | 4 | BE32 image-section length | 0x38 is 0 |
| 0x48 / 0x54 / 0x60 | 4 each | 140 / 44 / 16 | Footer lengths: slots 4, 7, 10 |
| 0xB8 | 4 | `00 01 00 00` | Section magic |
| 0xBC | 4 | BE32 | Bytes from 0xCC to the end of the image section, i.e. Σ(4 + frame len) |
| 0xC0 | 2 | BE16 width = 384 | There is **no** leading 0x0000 word, unlike the g3p at 0xC0 |
| 0xC2 | 2 | BE16 height = 192 | |
| 0xC4 | 2 | BE16 frame count | 9-20 seen. S11: a g3b holds up to 30 images. |
| 0xC6 | 2 | BE16 depth `0x0010` | |
| 0xC8 | 4 | `01 00 00 00` | `Bar_chart.g3b` has `01 28 00 00`. Meaning unknown. |
| 0xCC | ... | N x [BE32 len][obfuscated zlib stream] | Each frame is a full 384x192 RGB565 image, 147456 bytes when inflated |
| after | 200 | footers in slots 4, 7, 10 | |

- S11: g3b files open only in Picture Plot.
- **[UNVERIFIED]** whether a g3b without the three footers is accepted. Copy them if you ever write one.

---

## 11. Reference encoder, verification tools and golden vectors

Tools are in `tools/`. Run them as `python3 -I <tool> ...`. They use the stdlib only.

- `g3p_encode.py`: the encoder (`encode_g3p_rgb565`, `encode_g3b_rgb565`, `std_header`, `container`, `obfuscate`).
- `g3p_inspect.py`: the decoder and field dumper.
- `verify_roundtrip.py`: rebuilds every real file.
  - Result: **55/55 byte-identical.** 34 were fully re-encoded from the decoded pixels. 21 were container-exact while reusing Casio's own deflate stream, because a different deflater made those.
- `survey.py`, `g3b_probe.py`, `recompress*.py`, `topng.py`, `golden.py`, `make_sample.py`.

Golden vectors for unit tests:

1. **All-white 384x192.** `encode(b"\xFF" * 147456)` must equal Casio's `_Blank.g3p` exactly: 374 bytes, sha256 `29875a70f766be7457a359818cd88ccca51429fed4e4e62b5cee132a0da3a998`. Full hex:

   ```
   aaacbdaf90889a8d82ffefffefff48fefffffe89d100000000000000220e0000
   435000010000000000000000000000000000015600000001000000be00000000
   0000000000000000000000000000000000000000000000000000000000000000
   0000000000000000000000000000000000000000000000000000000000000000
   0000000000000000000000000000000000000000000000000000000000000000
   00000000000000000000000000000000000000000000000000010000000000aa
   0000018000c0001001000000000000a63c1b90f176f7ffffffe9fa08b2c49787
   faffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
   ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
   ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
   ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
   fffffffffffffffffffffffffffffffb47e77c25f05b
   ```
2. **`Cans.g3p`** (12706 B, sha256 `263d5f917798ddadb62fb09bd98e542201b785303a3b41d6a567628d9fbaa223`). Its decoded pixels (sha256 `fea8b67f...0b47`) re-encode to the identical file.
3. **`Arched_roof.g3p`** (96733 B, sha256 `867bd594...f8bd`). Same property as `Cans.g3p`.
4. **`out/SAMPLE01.g3p`** (935 B, sha256 `2d93a392...71e`). A synthetic orientation chart: red block top-left, blue top-right, green bottom-left, a black border, and 8 grey bars. It is ready for a first test on a device. Its PNG preview is `out/SAMPLE01.png`.

---

## 12. Discrepancies between sources

All of these were resolved against the real files.

1. **img2calc `cp.g3p` (S6) and OmniPlotter (S7) write the wrong 0x1C/0x1D bytes.**
   - They write stored `0x1C = b2+b3+0xAB` and `0x1D = b3+0x98`. Casio writes `0x99-b2-b3` and `0x84-b3`.
   - They agree only when `b2+b3 ≡ 0x77 (mod 128)` and `b3 ∈ {0x76, 0xF6}`. That is `_Blank.g3p`'s size, so the constants were evidently fitted to a file of that size.
   - For most sizes their 0x1C still differs from the "unencrypted" value, so the OS should still treat the payload as encrypted.
   - **Inference [UNVERIFIED]:** when `b2+b3 ≡ 0x2E or 0xAE (mod 256)`, about 1 file size in 128, their byte equals the "unencrypted" value. The OS would then try to inflate an obfuscated stream and show a blank or broken picture.
   - Use Casio's formula instead.
2. **img2calc's variant comments are partly wrong.**
   - "CP0100 + 3 footers, ID 0x3E93, not supported" is plain Casio data with an obfuscated `38 8D` header; the same algorithm decodes it.
   - Its `Array.from(adler32(...))` appends nothing, because `adler32` returns a number. Its output is therefore still correct zlib.
3. **libcasio (S5) has several errors.**
   - The obfuscation check omits the `+0x7B` term.
   - Its decoder strips the 2-byte zlib header and then calls `uncompress()`, which would fail.
   - The `df_size` comment ("image + footer") is wrong: the value is `4 + PDL`.
   - Its "generator IDs" are zlib headers.
4. **Cahute (S9)** has 0x0F as `\0` and calls 0x1C/0x1D "obfuscation options". For g3p, decoded 0x0F is 0x01.
5. **S4 (Kerm)** has a typo for 0x0E (+0x85 should be +0xBF). Its `FS-0xB8` and `FS-0xCC` formulas assume no footer.

---

## 13. Calculator-side facts (S11) and open device questions

### What the manual says [V-doc]

- g3p is "a proprietary format unique to this calculator".
- Graph mode stores `Pict01.g3p` to `Pict20.g3p` in the storage-memory **PICT** folder. On-calc names are at most 8 characters, but Casio's own files use longer names such as `Hexagonal_shape.g3p`.
- g3p files can be opened as:
  - a Graph background (Setup → Background);
  - a recalled picture;
  - a Geometry background;
  - an eActivity picture line, either a 16-bit g3p or a 3-bit capture;
  - a Picture Plot image.
- **Memory app:** highlight a g3p and press DETAIL, then the right arrow, to see an **image preview**. Up and down then step to the next file's preview. This could be the quickest way to page through a folder of solution pictures; whether the preview is full-screen and 1:1 is **[UNVERIFIED]**.
- Screen capture (Capture Set Mode → Memory) saves 3-bit g3p.

### Still to check on a real fx-CG50

1. That a newly generated file (`out/SAMPLE01.g3p`) opens, in the Memory preview and in Picture Plot, with the correct orientation.
2. What area each viewer shows, and whether status bars or function menus cover part of the 384x192 image.
3. Whether sizes other than 384x192 are accepted.
4. The 3-bit format and the unencrypted variants. No real samples were found.
5. The meaning of 0xC0 (`0000`) and 0xC8 (`01000000`).

---

## Appendix: real Casio files examined (S10)

The 0x1C/0x1D rule held for every file: decoded `0x1C - (0x7D+b2+b3) = 0xE9` and `0x1D - b3 = 0x7B`.

All files also passed every structural check:

- `0x10 == FS`;
- `0x0E == b3+0x41`;
- `0x14 == b3+0xB8`;
- `0x30 == FS-0x20`;
- `0xB8 + Σ slot sizes == FS`;
- the Adler-32 is valid.

| file | bytes | tag @0x20 | mask @0x34 [slots] | WxH | frames | zlib hdr (de-obf) | sha256[:16] |
|---|---|---|---|---|---|---|---|
| Amsterdam.g3p | 48176 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `26d37e7fddb009c7` |
| Amusement_park.g3p | 54881 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `e3f862a291e8013a` |
| Arched_roof.g3p | 96733 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `867bd59487592104` |
| Arches.g3p | 108091 | CP\0\x01 | 0x9 [0, 3] | 384x192 | 1 | 789c | `69b082097255f6b7` |
| Bathroom.g3p | 27700 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `ce1b440375737bbc` |
| Beach.g3p | 44516 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `e8191ccf61e51787` |
| Books.g3p | 95053 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `95289d8cff5818d5` |
| Bowling_pins.g3p | 35578 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `18905c6c6c197691` |
| Bridge.g3p | 87786 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `f84a161d33adfc34` |
| Bugle.g3p | 38730 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `5ef6cfcf05904b2f` |
| Building.g3p | 39423 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `7438c486bca8e1e6` |
| Can_telephones.g3p | 27611 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `ab14d2f4d941625a` |
| Cans.g3p | 12706 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `263d5f917798ddad` |
| Chef_juggling.g3p | 18878 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `f31cc4ec70b02583` |
| Clocks.g3p | 38289 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `b84bc75ef30e7a88` |
| Ferris_wheel.g3p | 53690 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `d1c99787dd15f799` |
| Floorplan.g3p | 14245 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `bb616be73e0bb384` |
| Footbridge.g3p | 77012 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `3914ece04db45acb` |
| Forest.g3p | 84326 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `cae26f4ef10bad66` |
| Fountain.g3p | 53079 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `efee425e3e80a286` |
| Gate.g3p | 27338 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `100bad2a98e88a7f` |
| Glass_dome.g3p | 66413 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `f7244ef99ad8faf6` |
| Harbour_bridge.g3p | 81396 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `3281b039662e6e18` |
| Hexagonal_shape.g3p | 47823 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `f8d006a9322a53da` |
| Nautilus.g3p | 84899 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `2810430122bcef02` |
| Night_fountain.g3p | 67964 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `99cf049cfda7335a` |
| Pancakes.g3p | 47340 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `d44fd9ba90398eec` |
| Power_plant.g3p | 52922 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `01928f8a56dd6143` |
| Power_station.g3p | 52783 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `d37fdb31ac03183d` |
| Pyramids.g3p | 49838 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `2d894f188a1c52c0` |
| Rising_coins.g3p | 46059 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `066dabf735a0056b` |
| Roller_coaster.g3p | 62585 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `319565036865484d` |
| Roofs.g3p | 35787 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `5b9120e4e7d00013` |
| Round_point.g3p | 77007 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `d01fb52041e5038f` |
| Satellite_dish.g3p | 72783 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `404cef55932b47f2` |
| Screw.g3p | 27613 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `282aa764a2666e1f` |
| Solar_system.g3p | 47548 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `154e001ed2a65a75` |
| Stained_glass.g3p | 65019 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `9bcf60b8a5f0af3d` |
| Steel_tower.g3p | 27262 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `455751fd443bc96f` |
| Stones.g3p | 48560 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `28d10c6bea29b6c5` |
| Sunsetbridge.g3p | 37954 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `85e116a04695a6e4` |
| Swimming_pool.g3p | 94209 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `f4eec7aee74accb5` |
| Tiles.g3p | 84700 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `827be12324124c89` |
| Two_loops.g3p | 55679 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `61d4dcebf53e74ae` |
| Water_slide.g3p | 75125 | CP0100Ly755 | 0xA09 [0, 3, 9, 11] | 384x192 | 1 | 388d | `31b04ac273ab9242` |
| Wooden_fence.g3p | 78257 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `80a8a1fce0a992d4` |
| _Blank.g3p | 374 | CP\0\x01 | 0x1 [0] | 384x192 | 1 | 789c | `29875a70f766be74` |
| Bar_chart.g3b | 193372 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 9 | 789c | `d61d25a62263b8f4` |
| Chocolate_flow.g3b | 114459 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 12 | 789c | `fcde4b0029303268` |
| Clock_time_lapse.g3b | 453136 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 16 | 789c | `d25ef9dd8500de8e` |
| Coaster_car.g3b | 948471 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 9 | 789c | `8b5e06708c25b564` |
| Hearts.g3b | 677366 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 20 | 789c | `f726e938f68d3cfc` |
| Jumping_fish.g3b | 291119 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 11 | 789c | `06f4a3b260b9466e` |
| Pendulum.g3b | 835509 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 17 | 789c | `ec615a2310cd6780` |
| Wind_turbine.g3b | 594508 | CP\0\x01 | 0x492 [1, 4, 7, 10] | 384x192 | 20 | 789c | `060899e731024cdd` |
