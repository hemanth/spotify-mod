// Records one on-screen Ghostty window's display area plus system audio to a .mov
// with ScreenCaptureKit, until a stop file appears.
//
//   screenrec <window-id-or-title> <out.mov> <stop-file>
//
// Captures the whole display cropped to the window frame so both the terminal
// (including inline kitty-graphics album covers) and any floating macOS popup/login
// windows inside that frame are recorded along with system audio.
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write("usage: screenrec <window-id-or-title> <out.mov> <stop-file>\n".data(using: .utf8)!)
  exit(2)
}
let targetArg = args[1]
let outURL = URL(fileURLWithPath: args[2])
let stopPath = args[3]

final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
    print("recording")
    fflush(stdout)
  }
  func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
    print("error recording: \(error)")
    exit(1)
  }
  func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
    print("finished \(outURL.path)")
    exit(0)
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    print("error stream: \(error)")
    exit(1)
  }
}

let recorder = Recorder()

Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let ghosttyWindows = content.windows.filter {
      $0.owningApplication?.bundleIdentifier == "com.mitchellh.ghostty"
    }
    let matchedWindow: SCWindow?
    if let wid = UInt32(targetArg) {
      matchedWindow = ghosttyWindows.first(where: { $0.windowID == wid })
    } else {
      matchedWindow = ghosttyWindows.first(where: { ($0.title ?? "").contains(targetArg) })
    }

    guard let window = matchedWindow else {
      print("error could not find Ghostty window matching \"\(targetArg)\" among \(ghosttyWindows.map { "\($0.windowID):\($0.title ?? "")" })")
      exit(1)
    }
    guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else {
      print("error no display under the window")
      exit(1)
    }

    let hidden = content.windows.filter { $0.title == "screenrec" }
    let filter = SCContentFilter(display: display, excludingWindows: hidden)
    let config = SCStreamConfiguration()
    let crop = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    config.sourceRect = crop
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int(crop.width * scale) & ~1
    config.height = Int(crop.height * scale) & ~1
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.showsCursor = false
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2

    try? FileManager.default.removeItem(at: outURL)
    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    let outputConfig = SCRecordingOutputConfiguration()
    outputConfig.outputURL = outURL
    outputConfig.outputFileType = .mov
    outputConfig.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: outputConfig, delegate: recorder)
    try stream.addRecordingOutput(output)
    try await stream.startCapture()

    while !FileManager.default.fileExists(atPath: stopPath) {
      try await Task.sleep(nanoseconds: 200_000_000)
    }
    try await stream.stopCapture()
    try await Task.sleep(nanoseconds: 10_000_000_000)
    print("error recording did not finish")
    exit(1)
  } catch {
    print("error \(error)")
    exit(1)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
