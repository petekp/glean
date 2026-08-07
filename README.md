# glean

⌘⇧4 for text. Drag a region of the screen, and the text inside it lands on your clipboard.

No dependencies, no network, no API keys — just `screencapture` and Apple's Vision
framework, both of which ship with macOS. OCR runs entirely on-device.

```
⌘⇧1  →  crosshair  →  drag  →  chime  →  ⌘V
```

## Install

```sh
swiftc -O glean.swift -o glean
cp glean ~/.local/bin/glean
```

Then bind a hotkey. The path of least resistance is an Automator Quick Action
(**no input**, **any application**) containing a single *Run Shell Script* step:

```sh
exec ~/.local/bin/glean
```

Save it to `~/Library/Services/`, then assign a key in
**System Settings → Keyboard → Keyboard Shortcuts → Services**.

## Usage

Run with no arguments to capture interactively — same crosshair as ⌘⇧4, including
Space to toggle window-selection mode.

Pass an image path to skip the capture and OCR an existing file instead, which is
also the easiest way to test:

```sh
glean ~/Desktop/screenshot.png && pbpaste
```

## Feedback

| Sound | Meaning |
|---|---|
| Glass | Text recognized and copied |
| Funk | Capture worked, but Vision found no text |
| *silence* | You pressed Escape |

## Two settings worth explaining

**`usesLanguageCorrection = false`.** Screenshots are mostly code, paths, and error
strings. With correction on, Vision's language model "fixes" `oncomplete]` into
`oncompletel` and quietly mangles identifiers. Off, transcription is literal.

**`minimumTextHeight = 0`.** The default is 1/32 of the *image* height, so a tall
selection containing normal-sized text returns nothing at all — no error, no
exception, just an empty result set. If you ever debug a silent OCR failure in
Vision, start here.

## Known limits

- Leading indentation is not preserved; Vision reports lines, not columns.
- Multi-column layouts are read in Vision's reading order, which can interleave.
- English only. Add to `recognitionLanguages` for others.

## Requirements

macOS 13+ and the Xcode command line tools (for `swiftc`). Whichever app invokes
`glean` needs Screen Recording permission — macOS will prompt on first capture.

## License

MIT
