//
//  AISubtitleScheduler.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Foundation

final class AISubtitlePassThroughTranslator: AISubtitleTranslator {
  let providerID: AISubtitleProviderID
  let modelIdentifier = "identity"

  init(providerID: AISubtitleProviderID) {
    self.providerID = providerID
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    AISubtitleProviderCapability(providerID: providerID,
                                 role: .translator,
                                 status: .available,
                                 reason: "Source and target languages are the same.",
                                 supportsCloudProcessing: providerID.isCloudProvider,
                                 modelIdentifier: modelIdentifier)
  }

  func translate(_ segments: [AISubtitleSegment],
                 request: AISubtitleProviderRequest,
                 completion: @escaping (Result<[AISubtitleCue], AISubtitleError>) -> Void) {
    completion(.success(segments.map {
      AISubtitleCue(id: $0.id,
                    timeRange: $0.timeRange,
                    text: $0.text,
                    language: request.targetLanguage)
    }))
  }
}

final class AISubtitleScheduler {
  struct Configuration {
    var aheadDuration: Double = 300
    var refillThreshold: Double = 60
    var chunkPlanner = AISubtitleChunkPlanner()
  }

  typealias StateHandler = (AISubtitleTaskState) -> Void
  typealias SubtitleFileHandler = (URL) -> Void

  private let queue: DispatchQueue
  private let extractor: AISubtitleAudioExtracting
  private let transcriber: AISubtitleTranscriber
  private let translator: AISubtitleTranslator
  private let cacheStore: AISubtitleCacheStore
  private let configuration: Configuration
  private let fileManager: FileManager

  private var generation = UUID()
  private var media: AISubtitleMediaContext?
  private var mediaDuration: Double = 0
  private var request: AISubtitleProviderRequest?
  private var cacheKey: AISubtitleCacheKey?
  private var pendingRanges: [AISubtitleTimeRange] = []
  private var coveredRanges: [AISubtitleTimeRange] = []
  private var transcript: [AISubtitleSegment] = []
  private var translatedCues: [AISubtitleCue] = []
  private var focusPosition: Double = 0
  private var isProcessing = false
  private var activeRange: AISubtitleTimeRange?
  private var stateHandler: StateHandler?
  private var subtitleFileHandler: SubtitleFileHandler?

  init(extractor: AISubtitleAudioExtracting,
       transcriber: AISubtitleTranscriber,
       translator: AISubtitleTranslator,
       cacheStore: AISubtitleCacheStore = AISubtitleCacheStore(),
       configuration: Configuration = Configuration(),
       fileManager: FileManager = .default,
       queue: DispatchQueue = DispatchQueue(label: "IINAAISubtitleScheduler", qos: .utility)) {
    self.extractor = extractor
    self.transcriber = transcriber
    self.translator = translator
    self.cacheStore = cacheStore
    self.configuration = configuration
    self.fileManager = fileManager
    self.queue = queue
  }

  func start(media: AISubtitleMediaContext,
             mediaDuration: Double,
             cacheKey: AISubtitleCacheKey,
             playbackPosition: Double,
             stateHandler: @escaping StateHandler,
             subtitleFileHandler: @escaping SubtitleFileHandler) {
    queue.async {
      self.generation = UUID()
      self.media = media
      self.mediaDuration = max(0, mediaDuration)
      self.request = AISubtitleProviderRequest(sourceLanguage: media.sourceLanguage,
                                               targetLanguage: media.targetLanguage,
                                               media: media)
      self.cacheKey = cacheKey
      self.pendingRanges.removeAll()
      self.coveredRanges.removeAll()
      self.transcript.removeAll()
      self.translatedCues.removeAll()
      self.isProcessing = false
      self.activeRange = nil
      self.stateHandler = stateHandler
      self.subtitleFileHandler = subtitleFileHandler
      if let cached = try? self.cacheStore.cachedContent(for: cacheKey) {
        self.coveredRanges = self.mergedRanges(cached.metadata.coveredRanges)
        self.transcript = cached.transcript
        self.translatedCues = cached.cues
        if let cachedVTT = self.cacheStore.cachedVTT(for: cacheKey) {
          self.subtitleFileHandler?(cachedVTT)
        }
      }
      self.emit(AISubtitleTaskState(.preparing))
      let initialPosition = self.mediaDuration > 0 && playbackPosition >= self.mediaDuration
        ? 0
        : playbackPosition
      self.focusPosition = min(max(0, initialPosition), self.mediaDuration)
      self.enqueueAheadWindow(from: initialPosition)
      self.processNextIfNeeded()
    }
  }

  func updatePlaybackPosition(_ position: Double) {
    queue.async {
      guard self.media != nil else { return }
      self.focusPosition = min(max(0, position), self.mediaDuration)
      self.pendingRanges.removeAll()
      self.enqueueAheadWindow(from: position)
      self.processNextIfNeeded()
    }
  }

  func cancel() {
    queue.async {
      self.generation = UUID()
      (self.extractor as? AISubtitleCancelableProvider)?.cancelAll()
      (self.transcriber as? AISubtitleCancelableProvider)?.cancelAll()
      (self.translator as? AISubtitleCancelableProvider)?.cancelAll()
      self.pendingRanges.removeAll()
      self.media = nil
      self.request = nil
      self.cacheKey = nil
      self.isProcessing = false
      self.activeRange = nil
      self.focusPosition = 0
      self.emit(AISubtitleTaskState(.canceled))
      self.stateHandler = nil
      self.subtitleFileHandler = nil
    }
  }

  private func enqueueAheadWindow(from playbackPosition: Double) {
    let start = min(max(0, playbackPosition), mediaDuration)
    let end = min(mediaDuration, start + configuration.aheadDuration)
    guard end > start else {
      pendingRanges.removeAll()
      return
    }

    let containingCoverage = coveredRanges.first { start >= $0.start && start <= $0.end }
    let requiredAhead = max(0, end - start - configuration.refillThreshold)
    if let containingCoverage = containingCoverage,
       containingCoverage.end - start >= requiredAhead {
      pendingRanges.removeAll()
      return
    }

    let overlap = max(0, configuration.chunkPlanner.overlapDuration)
    let generationStart = containingCoverage.map { max(start, $0.end - overlap) } ?? start
    pendingRanges = configuration.chunkPlanner
      .ranges(covering: AISubtitleTimeRange(start: generationStart, end: end))
      .filter { !isCovered($0) && $0 != activeRange }
  }

  private func processNextIfNeeded() {
    guard !isProcessing,
          let media = media,
          let request = request,
          let cacheKey = cacheKey else { return }
    guard let range = pendingRanges.first else {
      emit(AISubtitleTaskState(.maintaining,
                               coveredRange: focusedCoveredRange(),
                               progress: progress))
      return
    }
    pendingRanges.removeFirst()
    isProcessing = true
    activeRange = range
    let activeGeneration = generation
    let artifacts: AISubtitleCacheArtifacts
    do {
      artifacts = try cacheStore.layout.artifacts(for: cacheKey, createDirectories: true)
    } catch {
      fail(AISubtitleError(code: "cache_directory_failed", message: error.localizedDescription))
      return
    }
    let outputURL = artifacts.chunksDirectoryURL
      .appendingPathComponent(chunkFilename(for: range), isDirectory: false)
    emit(AISubtitleTaskState(.extracting,
                             currentRange: range,
                             coveredRange: focusedCoveredRange(),
                             progress: progress))
    extractor.extract(media: media, timeRange: range, outputURL: outputURL) { result in
      self.queue.async {
        guard activeGeneration == self.generation else {
          if case .success(let chunk) = result {
            try? self.fileManager.removeItem(at: chunk.url)
          }
          return
        }
        switch result {
        case .failure(let error):
          self.fail(error)
        case .success(let chunk):
          self.emit(AISubtitleTaskState(.transcribing,
                                        currentRange: range,
                                        coveredRange: self.focusedCoveredRange(),
                                        progress: self.progress))
          self.transcriber.transcribe(chunk, request: request) { result in
            self.queue.async {
              try? self.fileManager.removeItem(at: chunk.url)
              guard activeGeneration == self.generation else { return }
              switch result {
              case .failure(let error):
                self.fail(error)
              case .success(let segments):
                self.emit(AISubtitleTaskState(.translating,
                                              currentRange: range,
                                              coveredRange: self.focusedCoveredRange(),
                                              progress: self.progress))
                self.translator.translate(segments, request: request) { result in
                  self.queue.async {
                    guard activeGeneration == self.generation else { return }
                    switch result {
                    case .failure(let error):
                      self.fail(error)
                    case .success(let cues):
                      self.finish(range: range,
                                  newSegments: segments,
                                  newCues: cues,
                                  cacheKey: cacheKey)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func finish(range: AISubtitleTimeRange,
                      newSegments: [AISubtitleSegment],
                      newCues: [AISubtitleCue],
                      cacheKey: AISubtitleCacheKey) {
    transcript.append(contentsOf: newSegments)
    translatedCues.append(contentsOf: newCues)
    coveredRanges.append(range)
    coveredRanges = mergedRanges(coveredRanges)
    let normalizedCues = normalizedTranslatedCues()
    emit(AISubtitleTaskState(.assembling,
                             currentRange: range,
                             coveredRange: focusedCoveredRange(),
                             progress: progress))
    do {
      let artifacts = try cacheStore.save(transcript: transcript,
                                          cues: normalizedCues,
                                          coveredRanges: coveredRanges,
                                          for: cacheKey)
      emit(AISubtitleTaskState(.loading,
                               currentRange: range,
                               coveredRange: focusedCoveredRange(),
                               progress: progress))
      subtitleFileHandler?(artifacts.translatedVTTURL)
      isProcessing = false
      activeRange = nil
      processNextIfNeeded()
    } catch {
      fail(AISubtitleError(code: "subtitle_cache_write_failed", message: error.localizedDescription))
    }
  }

  private func normalizedTranslatedCues() -> [AISubtitleCue] {
    let language = request?.targetLanguage ?? AISubtitleLanguage("und")
    let segments = translatedCues.map {
      AISubtitleSegment(id: $0.id,
                        timeRange: $0.timeRange,
                        text: $0.text,
                        language: language)
    }
    return AISubtitleTimelineAssembler().assemble(segments, targetLanguage: language)
  }

  private func mergedRanges(_ ranges: [AISubtitleTimeRange]) -> [AISubtitleTimeRange] {
    var result: [AISubtitleTimeRange] = []
    for range in ranges.sorted(by: { $0.start < $1.start }) {
      guard var previous = result.popLast() else {
        result.append(range)
        continue
      }
      if range.start <= previous.end + 0.01 {
        previous.end = max(previous.end, range.end)
        result.append(previous)
      } else {
        result.append(previous)
        result.append(range)
      }
    }
    return result
  }

  private func isCovered(_ range: AISubtitleTimeRange) -> Bool {
    coveredRanges.contains { range.start >= $0.start && range.end <= $0.end }
  }

  private func focusedCoveredRange() -> AISubtitleTimeRange? {
    coveredRanges.first {
      focusPosition >= $0.start - 0.01 && focusPosition <= $0.end + 0.01
    }
  }

  private var progress: Double? {
    guard configuration.aheadDuration > 0 else { return nil }
    let covered = coveredRanges.reduce(0) { $0 + $1.duration }
    return min(1, covered / min(configuration.aheadDuration, max(mediaDuration, 1)))
  }

  private func chunkFilename(for range: AISubtitleTimeRange) -> String {
    let start = Int64((range.start * 1000).rounded())
    let end = Int64((range.end * 1000).rounded())
    return "chunk-\(start)-\(end).wav"
  }

  private func fail(_ error: AISubtitleError) {
    pendingRanges.removeAll()
    isProcessing = false
    activeRange = nil
    emit(AISubtitleTaskState(.failed,
                             coveredRange: focusedCoveredRange(),
                             progress: progress,
                             error: error))
  }

  private func emit(_ state: AISubtitleTaskState) {
    stateHandler?(state)
  }
}
