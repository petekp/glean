# glean

⌘⇧4 for text. Drag a region of the screen; the text inside it lands on your
clipboard with its indentation intact.

No dependencies, no network, no API keys — just `screencapture` and Apple's Vision
framework, both of which ship with macOS. OCR runs entirely on-device.

```
hotkey  →  crosshair  →  drag  →  chime  →  ⌘V
```

A panel shows you what landed on the clipboard, its glyphs riding a wave.

## Install

```sh
swiftc -O glean.swift -o glean
cp glean ~/.local/bin/glean
```

Then bind a hotkey.

### Raycast (recommended)

Copy the script command and point Raycast at it:

```sh
mkdir -p ~/.raycast-scripts
cp raycast/glean-text.sh ~/.raycast-scripts/
```

**Raycast Settings → Extensions → Script Commands → Add Directories →**
`~/.raycast-scripts`, then assign a hotkey to **Glean Text**.

### Automator Quick Action (no Raycast)

Create a Quick Action (**no input**, **any application**) with one *Run Shell
Script* step running `exec ~/.local/bin/glean`, save to `~/Library/Services/`,
and assign a key in **System Settings → Keyboard → Keyboard Shortcuts → Services**.

Be warned that Services shortcuts fail silently and lose to any running app
holding the same key, with no indication of the conflict. If a hotkey manager is
available, prefer it.

## Usage

Run with no arguments to capture interactively — same crosshair as ⌘⇧4, including
Space to toggle window-selection mode.

Pass an image path to OCR an existing file instead of capturing:

```sh
glean ~/Desktop/screenshot.png
```

The text goes to the clipboard *and* to stdout, always — the clipboard is what you
want from a hotkey, stdout is what you want from a shell, and writing both costs
nothing:

```sh
glean --no-hud | grep ERROR
```

Indentation is preserved. Vision reports lines, not columns, so `glean`
reconstructs leading whitespace from each line's measured x-offset and snaps it to
the narrowest indent present — 2-space and 4-space source both come back at their
true width, and code pastes without repair. Captures that aren't a stacked block of
text (a menu bar, a toolbar, side-by-side columns) are left flush, since a large
x-offset there means "further right on the same line", not "indented".

## Feedback

After a capture, a HUD panel fades in over whatever you were looking at, shows the
first few lines of the copied text, and fades out. It never takes focus and never
swallows a click.

| Sound | Panel | Meaning |
|---|---|---|
| Funk | the text | Text recognized and copied |
| Basso | *No text found* | Capture worked, but Vision found no text |
| *silence* | — | You pressed Escape |

The confirmation is the low, soft one on purpose — it's the sound you hear all day.
Swap either via `copiedSound` / `emptySound` in `glean.swift`; any name from
`/System/Library/Sounds` works.

Up to four lines are shown, each trimmed to 64 columns, with `+N more lines` when
there is more. It keeps the capture's own line breaks rather than re-wrapping, so
code stays indented and prose still breaks where it broke on screen. The knobs —
line count, width, wave amplitude, speed, timings — are the `HUD` constants at the
top of the HUD section in `glean.swift`.

`--no-hud` suppresses the panel for scripting:

```sh
glean --no-hud ~/Desktop/screenshot.png | grep ERROR
```

Showing this in the launcher instead was tried and doesn't work. Raycast's silent
mode renders only the **last** line of stdout, so capturing a paragraph flashed its
closing fragment and nothing else — feedback that looks like a bug even when the
copy was perfect. The bundled script command sends stdout to `/dev/null` so the two
HUDs don't stack.

## Three settings worth explaining

Measured on a rendered 8-line Python screenshot, scoring whole lines including
indentation.

**Upscale ~3x before recognizing.** Vision is trained on document-scale text and
reads screen-scale text noticeably worse — at native size it turns `log.warn(x)`
into `1og warn(x)` and sprays spaces around punctuation. Resampling first took
exact lines from **5/8 to 7/8**. Capturing at Retina resolution is not a
substitute: a true @2x render still scored 5/8. The gain comes from resampling
before recognition, not from source detail.

**`usesLanguageCorrection = false`.** Screenshots are mostly code, paths, and error
strings. With correction on, Vision's language model "fixes" `oncomplete]` into
`oncompletel` and quietly mangles identifiers — it scored **4/8**, worse than
leaving it off. Transcription should be literal.

**`minimumTextHeight = 0`.** The default is 1/32 of the *image* height, so a tall
selection containing normal-sized text returns nothing at all — no error, no
exception, just an empty result set. If you ever debug a silent OCR failure in
Vision, start here.

## Known limits

- The last stubborn error is glyph ambiguity: `log` still reads as `1og` in some
  monospace fonts. Vision cannot separate lowercase L from digit 1 without a
  language model, and enabling that model costs more than it fixes.
- Multi-column layouts are read in Vision's reading order, which can interleave.
- Indentation is reconstructed, not recovered — it is inferred from pixel offsets
  and can be off in unusual fonts.
- English only. Add to `recognitionLanguages` for others.

## Requirements

macOS 13+ and the Xcode command line tools (for `swiftc`). Whichever app invokes
`glean` needs Screen Recording permission — macOS will prompt on first capture.

## License

MIT
