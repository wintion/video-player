//
//  AISubtitleAudioExtractor.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Foundation

protocol AISubtitleAudioExtracting {
  func extract(media: AISubtitleMediaContext,
               timeRange: AISubtitleTimeRange,
               outputURL: URL,
               completion: @escaping (Result<AISubtitleAudioChunk, AISubtitleError>) -> Void)
}

struct AISubtitleChunkPlanner {
  var chunkDuration: Double = 60
  var overlapDuration: Double = 1.5

  func ranges(covering range: AISubtitleTimeRange) -> [AISubtitleTimeRange] {
    guard !range.isEmpty, chunkDuration > 0 else { return [] }
    let overlap = min(max(0, overlapDuration), chunkDuration / 2)
    var result: [AISubtitleTimeRange] = []
    var start = range.start
    while start < range.end {
      let end = min(start + chunkDuration, range.end)
      result.append(AISubtitleTimeRange(start: start, end: end))
      guard end < range.end else { break }
      start = end - overlap
    }
    return result
  }
}

final class FFmpegAISubtitleAudioExtractor: AISubtitleAudioExtracting, AISubtitleCancelableProvider {
  private let queue: DispatchQueue
  private let fileManager: FileManager
  private let cancellationLock = NSLock()
  private var canceled = false

  init(queue: DispatchQueue = DispatchQueue(label: "IINAAISubtitleAudioExtractor", qos: .utility),
       fileManager: FileManager = .default) {
    self.queue = queue
    self.fileManager = fileManager
  }

  func extract(media: AISubtitleMediaContext,
               timeRange: AISubtitleTimeRange,
               outputURL: URL,
               completion: @escaping (Result<AISubtitleAudioChunk, AISubtitleError>) -> Void) {
    guard !timeRange.isEmpty else {
      completion(.failure(AISubtitleError(code: "invalid_audio_range",
                                          message: "The requested audio range is empty.")))
      return
    }

    queue.async { [fileManager] in
      guard !self.isCanceled else {
        completion(.failure(AISubtitleError(code: "audio_extraction_canceled",
                                            message: "Audio extraction was canceled.")))
        return
      }
      do {
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try FFmpegController.extractAudio(from: media.url,
                                          streamIndex: media.audioStreamIndex ?? -1,
                                          startTime: timeRange.start,
                                          duration: timeRange.duration,
                                          outputURL: outputURL,
                                          shouldCancel: { self.isCanceled })
        completion(.success(AISubtitleAudioChunk(url: outputURL,
                                                 timeRange: timeRange,
                                                 format: .wav16kMono,
                                                 audioTrackID: media.audioTrackID,
                                                 audioStreamIndex: media.audioStreamIndex)))
      } catch let error as NSError {
        completion(.failure(AISubtitleError(code: "ffmpeg_audio_\(error.code)",
                                            message: error.localizedDescription)))
      }
    }
  }

  func cancelAll() {
    cancellationLock.lock()
    canceled = true
    cancellationLock.unlock()
  }

  private var isCanceled: Bool {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return canceled
  }
}
