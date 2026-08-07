// glean — interactive screen-region capture that OCRs the selection to the clipboard.
//
// Behaves like ⌘⇧4: crosshair, drag a region (or press Space then click a window).
// Instead of writing a file to the Desktop, the recognized text lands on the pasteboard.
//
// Escape during selection is a no-op: `screencapture` exits 0 but writes nothing,
// so we detect the missing file rather than trusting the exit status.

import AppKit
import Foundation
import QuartzCore
import Vision

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("glean-\(ProcessInfo.processInfo.processIdentifier).png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("glean: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
// The HUD is the point of the tool from a hotkey and pure noise from a pipe, so
// it is on by default and switched off explicitly.
let wantsHUD = !arguments.contains("--no-hud")
arguments.removeAll { $0 == "--no-hud" }

// An explicit path argument OCRs an existing image instead of capturing —
// handy for testing the recognition path without the crosshair.
let source: URL
if let path = arguments.first {
    source = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: source.path) else { fail("no such file") }
} else {
    // -x suppresses the camera shutter sound; we play our own on success instead.
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-i", "-x", tmp.path]
    try capture.run()
    capture.waitUntilExit()

    guard FileManager.default.fileExists(atPath: tmp.path) else { exit(0) }  // user cancelled
    source = tmp
}
defer { try? FileManager.default.removeItem(at: tmp) }

guard let image = NSImage(contentsOf: source),
      let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("could not decode capture") }

// Vision is trained on document-scale text and reads screen-scale text noticeably
// worse: at native size it turns `log.warn(x)` into `1og warn(x)` and sprays spaces
// around punctuation. Resampling up first measurably fixes most of that — on an
// 8-line code sample, exact-line accuracy went 5/8 native -> 7/8 at 3x. Capturing
// at Retina resolution does *not* substitute for this; the gain comes from
// resampling before recognition, not from source detail.
//
// The pixel cap keeps a full-screen grab from ballooning into something slow.
func upscaled(_ img: CGImage, maxScale: CGFloat = 3, maxPixels: CGFloat = 24_000_000) -> CGImage {
    let pixels = CGFloat(img.width * img.height)
    let scale = min(maxScale, max(1, (maxPixels / pixels).squareRoot()))
    guard scale > 1.01 else { return img }

    let w = Int(CGFloat(img.width) * scale), h = Int(CGFloat(img.height) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? img
}

let cgImage = upscaled(original)

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// Off on purpose. Screenshots are usually code, paths, error strings, and IDs —
// the language model "corrects" those into nonsense (`oncomplete]` -> `oncompletel`).
// Literal transcription beats plausible prose here; measured 5/8 exact lines with
// it off versus 4/8 with it on.
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]
// Default is 1/32 of image height, which silently drops normal-sized UI text
// whenever the selection is tall relative to the text in it. We want it all.
request.minimumTextHeight = 0

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

// Vision returns observations in reading order; each is one visual line. Alongside
// the text it hands back a normalized bounding box, which is the only record of
// where the line started — indentation exists nowhere in the transcription itself.
struct Line {
    let text: String
    let x: CGFloat       // normalized distance from the left edge
    let height: CGFloat  // normalized glyph height, our only scale reference
    let box: CGRect
}

let lines: [Line] = (request.results ?? []).compactMap {
    guard let text = $0.topCandidates(1).first?.string else { return nil }
    return Line(text: text, x: $0.boundingBox.minX,
                height: $0.boundingBox.height, box: $0.boundingBox)
}

// Re-derive indentation from those boxes. Bounding boxes are normalized to the
// image, so a character's width in x-units depends on the aspect ratio; glyph
// height is the only scale we're given, and ~0.6 of it approximates the advance
// width of a monospace character.
//
// This reproduces the measured column rather than guessing at "indent levels", so
// 2-space and 4-space source both come back at their true width. Ragged left edges
// in proportional text drift well under one character and round away to zero, so
// prose stays flush without needing a flag.

// Only a stacked block of text has meaningful indentation. Grab a whole window and
// Vision also returns things laid out side by side — a menu bar, a toolbar, a row
// of columns — where a large x-offset means "further right on the same line", not
// "indented". Reconstructing columns there produced 147 spaces before the clock.
//
// The tell is vertical overlap: in a text block no two lines share a baseline, and
// in a horizontal layout many do. When we see overlap, leave the text flush.
func isStackedText(_ lines: [Line], _ boxes: [CGRect]) -> Bool {
    let sorted = boxes.sorted { $0.midY > $1.midY }
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        if overlap > min(a.height, b.height) * 0.5 { return false }
    }
    return true
}

func indented(_ lines: [Line], _ boxes: [CGRect]) -> [String] {
    guard lines.count > 1, let base = lines.map(\.x).min(),
          isStackedText(lines, boxes) else { return lines.map(\.text) }

    let heights = lines.map(\.height).sorted()
    let medianHeight = heights[heights.count / 2]
    let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
    let charWidth = (medianHeight * 0.6) / aspect
    guard charWidth > 0 else { return lines.map(\.text) }

    // Under a character and a half is noise, not indentation.
    let columns = lines.map { max(0, ($0.x - base) / charWidth) }
    let indents = columns.filter { $0 >= 1.5 }

    // Measuring each line independently leaves the odd column off by one, and
    // indentation that is ragged by a single space is worse to paste than none at
    // all. Real indentation comes in multiples of one unit, so infer that unit from
    // the narrowest indent present and snap everything to it — this is what turns
    // 13 back into 12 without needing to know the source used four spaces.
    let unit = indents.min() ?? 0
    let snap: (CGFloat) -> Int = { columns in
        guard columns >= 1.5 else { return 0 }
        guard unit >= 1.5 else { return Int(columns.rounded()) }
        // Round the snapped width — truncating it turns a measured 1.7 into one
        // space where two were meant.
        return Int(((columns / unit).rounded() * unit).rounded())
    }

    return zip(lines, columns).map { line, columns in
        String(repeating: " ", count: snap(columns)) + line.text
    }
}

let text = indented(lines, lines.map(\.box)).joined(separator: "\n")

// MARK: - The HUD
//
// A chime tells you *that* something was copied; it cannot tell you *what*. The
// obvious place to show that is the launcher — but Raycast's HUD renders only the
// last line of stdout, so capturing a paragraph flashed its closing fragment and
// nothing else, which reads like a bug even when the copy was perfect.
//
// So glean draws its own panel. That buys three things the launcher could not give
// us: the *beginning* of the text rather than its tail, several lines instead of
// one, and identical feedback from Raycast, a Quick Action, or a bare shell.

// Measured dominant pitch of the system sounds: Funk ~324 Hz, Basso ~440, Glass
// ~831. Glass reads as a bright chime and Funk as a soft thump an octave-and-a-third
// below it. The copy confirmation is the one you hear all day, so it takes the lower,
// less insistent sound. Basso is only a fifth above Funk but percussive rather than
// synthetic, so the two never blur together.
let copiedSound = "Funk"
let emptySound = "Basso"

enum HUD {
    static let maxLines = 4        // source lines shown before we summarize the rest
    static let maxColumns = 64     // characters per line before the ellipsis
    static let fontSize: CGFloat = 14

    // The wave. Amplitude and wavelength are in glyphs and points; `speed` is
    // radians per second. Wider wavelength reads as a swell, tighter as a jitter.
    static let amplitude: CGFloat = 3.2
    static let wavelength = 7.0    // glyphs per full cycle
    static let speed = 6.0

    static let fadeIn = 0.18
    static let hold = 1.75
    static let fadeOut = 0.32
}

struct HUDLine {
    let text: String
    let dim: Bool  // the "+N more" summary is chrome, not content
}

/// Trim one source line to the HUD's width, breaking on a word when one is near
/// the cut so the preview doesn't end mid-identifier.
func clamped(_ line: String, to limit: Int) -> String {
    var line = line
    while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
    guard line.count > limit else { return line }

    let cut = line.prefix(limit - 1)
    if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 12 {
        return cut[..<space] + "…"
    }
    return cut + "…"
}

/// The copied text, reduced to something readable at a glance.
///
/// Vision returns one observation per *visual* line, so keeping that structure
/// costs nothing and preserves the shape of what you grabbed — code stays indented,
/// prose still breaks where it broke on screen. Re-wrapping would destroy both.
func hudLines(for text: String) -> [HUDLine] {
    var lines = text.components(separatedBy: "\n")
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }

    var out = lines.prefix(HUD.maxLines).map { HUDLine(text: clamped($0, to: HUD.maxColumns), dim: false) }
    let hidden = lines.count - out.count
    if hidden > 0 {
        out.append(HUDLine(text: "+\(hidden) more line\(hidden == 1 ? "" : "s")", dim: true))
    }
    return out
}

/// Draws each glyph itself so it can ride a travelling sine wave.
///
/// The phase advances per glyph across the whole block rather than per line, so the
/// crest runs through the text as one continuous ripple instead of restarting at
/// every left margin. Spaces still consume a phase step — dropping them would make
/// the wave stutter across word gaps.
final class WaveTextView: NSView {
    private let lines: [HUDLine]
    private let font = NSFont.monospacedSystemFont(ofSize: HUD.fontSize, weight: .medium)
    private let start = CACurrentMediaTime()

    init(lines: [HUDLine]) {
        self.lines = lines
        super.init(frame: .zero)
        frame = NSRect(origin: .zero, size: intrinsicContentSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Normal leading plus room for the wave: without it a crest on one line and a
    // trough on the line above collide, and the block reads as one smeared mass.
    private var lineHeight: CGFloat {
        (font.ascender - font.descender + font.leading).rounded() + HUD.amplitude * 1.75
    }

    private func attributes(dim: Bool) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(dim ? 0.45 : 0.95)]
    }

    /// Measured the same way it is drawn — per character, no kerning — so the panel
    /// is exactly as wide as the glyphs that land in it.
    private func width(of line: HUDLine) -> CGFloat {
        let attrs = attributes(dim: line.dim)
        return line.text.reduce(0) { $0 + String($1).size(withAttributes: attrs).width }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (lines.map(width(of:)).max() ?? 0).rounded(.up),
               height: lineHeight * CGFloat(lines.count))
    }

    override func draw(_ dirtyRect: NSRect) {
        let elapsed = CACurrentMediaTime() - start
        // Ease the amplitude in, or the text pops into motion at full swing.
        let swell = min(1, elapsed / HUD.fadeIn)
        let step = 2 * Double.pi / HUD.wavelength

        var glyph = 0
        for (row, line) in lines.enumerated() {
            let attrs = attributes(dim: line.dim)
            var x: CGFloat = 0
            let baseline = CGFloat(row) * lineHeight

            for character in line.text {
                let piece = String(character)
                let advance = piece.size(withAttributes: attrs).width
                if character != " " {
                    let offset = HUD.amplitude * swell * CGFloat(sin(elapsed * HUD.speed - Double(glyph) * step))
                    piece.draw(at: CGPoint(x: x, y: baseline + offset), withAttributes: attrs)
                }
                x += advance
                glyph += 1
            }
        }
    }
}

/// Show the panel, run the animation, then exit. Never returns.
func showHUD(_ lines: [HUDLine], sound: String) -> Never {
    let app = NSApplication.shared
    // .accessory keeps us out of the Dock and the ⌘-Tab switcher; a bare
    // command-line binary would otherwise be .prohibited and unable to show a window.
    app.setActivationPolicy(.accessory)

    let text = WaveTextView(lines: lines)
    let padding = NSSize(width: 22, height: 16)
    // The wave lifts glyphs past their layout box, so the panel has to reserve room
    // for a full crest at the top and a full trough at the bottom.
    let size = NSSize(width: text.frame.width + padding.width * 2,
                      height: text.frame.height + padding.height * 2 + HUD.amplitude * 2)

    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
    let visible = screen.visibleFrame  // excludes the Dock and menu bar
    let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                         y: (visible.minY + visible.height * 0.13).rounded())

    let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true          // never intercept a click meant for the app below
    panel.level = .screenSaver               // above full-screen apps and other floating panels
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.appearance = NSAppearance(named: .vibrantDark)  // a HUD is dark in either system theme
    panel.alphaValue = 0

    // The blur is a *subview* of a plain host, never the panel's contentView. In the
    // contentView role AppKit dresses an NSVisualEffectView in window chrome: a 1px
    // light stroke on the window's square bounds, which sits outside our rounded
    // corners and reads as a stray border. Demoting it keeps the material and drops
    // the chrome. The stroke survives dropping the vibrantDark appearance and
    // vanishes the moment the effect view stops being the contentView, so the
    // content-view role is the trigger — not the appearance, not the corner radius.
    let host = NSView(frame: NSRect(origin: .zero, size: size))

    let backdrop = NSVisualEffectView(frame: host.bounds)
    backdrop.material = .hudWindow
    backdrop.blendingMode = .behindWindow
    backdrop.state = .active
    backdrop.wantsLayer = true
    backdrop.layer?.cornerRadius = 14
    backdrop.layer?.masksToBounds = true

    text.setFrameOrigin(NSPoint(x: padding.width, y: padding.height + HUD.amplitude))
    backdrop.addSubview(text)
    host.addSubview(backdrop)
    panel.contentView = host
    panel.orderFrontRegardless()  // show without stealing focus from the frontmost app

    NSSound(named: sound)?.play()

    NSAnimationContext.runAnimationGroup { context in
        context.duration = HUD.fadeIn
        panel.animator().alphaValue = 1
    }

    let frame = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        text.needsDisplay = true
    }
    // The wave keeps running through the fade — freezing it first reads as a stall.
    Timer.scheduledTimer(withTimeInterval: HUD.fadeIn + HUD.hold, repeats: false) { _ in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HUD.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            frame.invalidate()
            exit(0)
        })
    }

    app.run()
    exit(0)
}

guard !text.isEmpty else {
    guard wantsHUD else {
        NSSound(named: emptySound)?.play()
        Thread.sleep(forTimeInterval: 0.4)  // NSSound is async; process exit would cut it off
        exit(0)
    }
    showHUD([HUDLine(text: "No text found", dim: false)], sound: emptySound)
}

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)

// Also print it, unconditionally. The clipboard is what you want from a hotkey and
// stdout is what you want from a shell, and writing to both costs nothing: `glean |
// grep ERROR` works, and the terminal shows you what you got. Deciding between them
// by checking isatty would silently drop the clipboard write under any launcher
// that captures output, which is precisely the case that matters most.
print(text)

guard wantsHUD else {
    NSSound(named: copiedSound)?.play()
    Thread.sleep(forTimeInterval: 0.4)
    exit(0)
}
showHUD(hudLines(for: text), sound: copiedSound)
