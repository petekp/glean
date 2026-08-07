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
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("could not decode capture") }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// Off on purpose. Screenshots are usually code, paths, error strings, and IDs —
// the language model "corrects" those into nonsense (`oncomplete]` -> `oncompletel`).
// Literal transcription beats plausible prose here.
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]
// Default is 1/32 of image height, which silently drops normal-sized UI text
// whenever the selection is tall relative to the text in it. We want it all.
request.minimumTextHeight = 0

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

// Vision returns observations in reading order; each is one visual line.
// topCandidates(1) is the highest-confidence transcription for that line.
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
let text = lines.joined(separator: "\n")

guard !text.isEmpty else {
    NSSound(named: "Funk")?.play()
    Thread.sleep(forTimeInterval: 0.4)  // NSSound is async; process exit would cut it off
    exit(0)
}

let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)

NSSound(named: "Glass")?.play()
Thread.sleep(forTimeInterval: 0.4)
