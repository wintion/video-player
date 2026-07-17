#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import Foundation

enum GeneratorError: Error, CustomStringConvertible {
  case usage
  case missingAudioTrack
  case cannotCreateTrack(String)
  case cannotStartWriter(String)
  case cannotAppendFrame(Int)
  case writerFailed(String)
  case cannotCreateExporter
  case exportFailed(String)

  var description: String {
    switch self {
    case .usage:
      return "Usage: generate_ai_subtitle_test_video.swift <audio-file> [audio-file ...] <output.mov>\n"
        + "   or: generate_ai_subtitle_test_video.swift --silent-duration <seconds> <output.mov>"
    case .missingAudioTrack:
      return "The input file has no audio track."
    case let .cannotCreateTrack(kind):
      return "Could not create the composition \(kind) track."
    case let .cannotStartWriter(message):
      return "Could not start the video writer: \(message)"
    case let .cannotAppendFrame(index):
      return "Could not append video frame \(index)."
    case let .writerFailed(message):
      return "Video writer failed: \(message)"
    case .cannotCreateExporter:
      return "Could not create the media exporter."
    case let .exportFailed(message):
      return "Media export failed: \(message)"
    }
  }
}

func waitUntilReady(_ input: AVAssetWriterInput) {
  while !input.isReadyForMoreMediaData {
    Thread.sleep(forTimeInterval: 0.002)
  }
}

func generateVideoTrack(at url: URL, duration: CMTime) throws {
  let width = 960
  let height = 540
  let framesPerSecond: Int32 = 10
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])

  guard writer.canAdd(input) else {
    throw GeneratorError.cannotCreateTrack("video")
  }
  writer.add(input)
  guard writer.startWriting() else {
    throw GeneratorError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown error")
  }
  writer.startSession(atSourceTime: .zero)

  let frameCount = max(1, Int(ceil(duration.seconds * Double(framesPerSecond))))
  for index in 0..<frameCount {
    waitUntilReady(input)
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    guard let pixelBuffer else {
      throw GeneratorError.cannotAppendFrame(index)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixelBuffer),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(CGColor(red: 0.06, green: 0.075, blue: 0.09, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.49, alpha: 1))
    context.fill(CGRect(x: 0, y: height - 12, width: width, height: 12))
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let presentationTime = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
      throw GeneratorError.cannotAppendFrame(index)
    }
  }

  input.markAsFinished()
  let semaphore = DispatchSemaphore(value: 0)
  writer.finishWriting { semaphore.signal() }
  semaphore.wait()
  guard writer.status == .completed else {
    throw GeneratorError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
  }
}

func longestDuration(of assets: [AVURLAsset]) async throws -> CMTime {
  var duration = CMTime.zero
  for asset in assets {
    let candidate = try await asset.load(.duration)
    if CMTimeCompare(candidate, duration) > 0 {
      duration = candidate
    }
  }
  return duration
}

func combine(videoURL: URL, audioURLs: [URL], outputURL: URL) async throws {
  let audioAssets = audioURLs.map(AVURLAsset.init(url:))
  let videoAsset = AVURLAsset(url: videoURL)
  var sourceAudioTracks: [AVAssetTrack] = []
  for asset in audioAssets {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw GeneratorError.missingAudioTrack
    }
    sourceAudioTracks.append(track)
  }
  guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else {
    throw GeneratorError.cannotCreateTrack("source video")
  }

  let composition = AVMutableComposition()
  guard let videoTrack = composition.addMutableTrack(
    withMediaType: .video,
    preferredTrackID: kCMPersistentTrackID_Invalid) else {
    throw GeneratorError.cannotCreateTrack("video")
  }
  let duration = try await longestDuration(of: audioAssets)
  try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
  for (index, sourceAudio) in sourceAudioTracks.enumerated() {
    guard let audioTrack = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw GeneratorError.cannotCreateTrack("audio \(index + 1)")
    }
    let audioDuration = try await audioAssets[index].load(.duration)
    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                                   of: sourceAudio,
                                   at: .zero)
  }
  videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

  guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
    throw GeneratorError.cannotCreateExporter
  }
  exporter.shouldOptimizeForNetworkUse = true
  try await exporter.export(to: outputURL, as: .mov)
}

do {
  guard CommandLine.arguments.count >= 3 else { throw GeneratorError.usage }
  let outputURL = URL(fileURLWithPath: CommandLine.arguments.last!)
  let silentDuration: Double?
  let audioURLs: [URL]
  if CommandLine.arguments.dropFirst().first == "--silent-duration" {
    guard CommandLine.arguments.count == 4,
          let seconds = Double(CommandLine.arguments[2]),
          seconds > 0 else { throw GeneratorError.usage }
    silentDuration = seconds
    audioURLs = []
  } else {
    silentDuration = nil
    audioURLs = CommandLine.arguments.dropFirst().dropLast().map(URL.init(fileURLWithPath:))
  }
  let temporaryVideoURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("rawya-ai-subtitle-\(UUID().uuidString).mov")
  defer { try? FileManager.default.removeItem(at: temporaryVideoURL) }

  try? FileManager.default.removeItem(at: outputURL)
  let duration: CMTime
  if let silentDuration {
    duration = CMTime(seconds: silentDuration, preferredTimescale: 600)
  } else {
    duration = try await longestDuration(of: audioURLs.map(AVURLAsset.init(url:)))
  }
  try generateVideoTrack(at: temporaryVideoURL, duration: duration)
  if audioURLs.isEmpty {
    try FileManager.default.moveItem(at: temporaryVideoURL, to: outputURL)
  } else {
    try await combine(videoURL: temporaryVideoURL, audioURLs: audioURLs, outputURL: outputURL)
  }
  print(outputURL.path)
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
