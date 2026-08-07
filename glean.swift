// glean — interactive screen-region capture that OCRs the selection to the clipboard.
//
// Behaves like ⌘⇧4: crosshair, drag a region (or press Space then click a window).
// Instead of writing a file to the Desktop, the recognized text lands on the pasteboard.
//
// Escape during selection is a no-op: `screencapture` exits 0 but writes nothing,
// so we detect the missing file rather than trusting the exit status.

import AppKit
import Foundation
import Vision

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("glean-\(ProcessInfo.processInfo.processIdentifier).png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("glean: \(message)\n".utf8))
    exit(1)
}

// An explicit path argument OCRs an existing image instead of capturing —
// handy for testing the recognition path without the crosshair.
let source: URL
if CommandLine.arguments.count > 1 {
    source = URL(fileURLWithPath: CommandLine.arguments[1])
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

guard !text.isEmpty else {
    NSSound(named: "Funk")?.play()
    Thread.sleep(forTimeInterval: 0.4)  // NSSound is async; process exit would cut it off
    exit(0)
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

NSSound(named: "Glass")?.play()
Thread.sleep(forTimeInterval: 0.4)
