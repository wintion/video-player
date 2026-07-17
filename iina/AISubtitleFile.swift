//
//  AISubtitleFile.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Foundation

struct AISubtitleAssemblerOptions {
  var duplicateMergeGap: Double = 0.5
  var adjacentMergeGap: Double = 0.15
  var maximumMergedCharacterCount: Int = 84
}

struct AISubtitleTimelineAssembler {
  var options = AISubtitleAssemblerOptions()

  func assemble(_ segments: [AISubtitleSegment], targetLanguage: AISubtitleLanguage) -> [AISubtitleCue] {
    let sorted = segments
      .compactMap(normalizedSegment)
      .sorted {
        if $0.timeRange.start == $1.timeRange.start {
          return $0.timeRange.end < $1.timeRange.end
        }
        return $0.timeRange.start < $1.timeRange.start
      }

    var cues: [AISubtitleCue] = []
    for segment in sorted {
      var cue = AISubtitleCue(id: segment.id,
                              timeRange: segment.timeRange,
                              text: segment.text,
                              language: targetLanguage)
      guard var previous = cues.popLast() else {
        cues.append(cue)
        continue
      }

      let gap = cue.timeRange.start - previous.timeRange.end
      if previous.text == cue.text && gap <= options.duplicateMergeGap {
        previous.timeRange.end = max(previous.timeRange.end, cue.timeRange.end)
        cues.append(previous)
        continue
      }

      if isPunctuationOnly(cue.text), gap >= 0, gap <= options.duplicateMergeGap {
        previous.timeRange.end = max(previous.timeRange.end, cue.timeRange.end)
        previous.text += cue.text
        cues.append(previous)
        continue
      }

      if cue.timeRange.start < previous.timeRange.end {
        cue.timeRange.start = previous.timeRange.end
      }
      guard !cue.timeRange.isEmpty else {
        cues.append(previous)
        continue
      }

      let mergedText = previous.text + separator(between: previous.text, and: cue.text) + cue.text
      if gap >= 0,
         gap <= options.adjacentMergeGap,
         mergedText.count <= options.maximumMergedCharacterCount {
        previous.timeRange.end = cue.timeRange.end
        previous.text = mergedText
        cues.append(previous)
      } else {
        cues.append(previous)
        cues.append(cue)
      }
    }
    return cues
  }

  private func normalizedSegment(_ segment: AISubtitleSegment) -> AISubtitleSegment? {
    let text = segment.text
      .components(separatedBy: .newlines)
      .map { line in
        line.components(separatedBy: .whitespacesAndNewlines)
          .filter { !$0.isEmpty }
          .joined(separator: " ")
      }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    guard !text.isEmpty, !segment.timeRange.isEmpty else { return nil }
    var normalized = segment
    normalized.text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#,
                                                with: "$1",
                                                options: .regularExpression)
    return normalized
  }

  private func isPunctuationOnly(_ text: String) -> Bool {
    !text.unicodeScalars.isEmpty
      && text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
  }

  private func separator(between first: String, and second: String) -> String {
    guard let last = first.last, let next = second.first else { return "" }
    return last.isASCII && next.isASCII ? " " : ""
  }
}

enum AISubtitleFileFormat {
  case webVTT
  case srt
}

struct AISubtitleFileWriter {
  func string(for cues: [AISubtitleCue], format: AISubtitleFileFormat) -> String {
    switch format {
    case .webVTT:
      let body = cues.map(webVTTCue).joined(separator: "\n\n")
      return body.isEmpty ? "WEBVTT\n" : "WEBVTT\n\n\(body)\n"
    case .srt:
      let body = cues.enumerated().map { srtCue(index: $0.offset + 1, cue: $0.element) }
        .joined(separator: "\n\n")
      return body.isEmpty ? "" : "\(body)\n"
    }
  }

  private func webVTTCue(_ cue: AISubtitleCue) -> String {
    let start = timestamp(cue.timeRange.start, millisecondSeparator: ".")
    let end = timestamp(cue.timeRange.end, millisecondSeparator: ".")
    return "\(start) --> \(end)\n\(safePayload(cue.text))"
  }

  private func srtCue(index: Int, cue: AISubtitleCue) -> String {
    let start = timestamp(cue.timeRange.start, millisecondSeparator: ",")
    let end = timestamp(cue.timeRange.end, millisecondSeparator: ",")
    return "\(index)\n\(start) --> \(end)\n\(safePayload(cue.text))"
  }

  private func timestamp(_ seconds: Double, millisecondSeparator: Character) -> String {
    let totalMilliseconds = Int64((max(0, seconds) * 1000).rounded())
    let milliseconds = totalMilliseconds % 1000
    let totalSeconds = totalMilliseconds / 1000
    let second = totalSeconds % 60
    let totalMinutes = totalSeconds / 60
    let minute = totalMinutes % 60
    let hour = totalMinutes / 60
    return String(format: "%02lld:%02lld:%02lld%c%03lld",
                  hour, minute, second, millisecondSeparator.asciiValue ?? 46, milliseconds)
  }

  private func safePayload(_ text: String) -> String {
    text.replacingOccurrences(of: "\0", with: "")
      .replacingOccurrences(of: "-->", with: "--\u{200B}>")
  }
}

struct AISubtitleCacheMetadata: Codable, Hashable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var key: AISubtitleCacheKey
  var createdAt: Date
  var updatedAt: Date
  var coveredRanges: [AISubtitleTimeRange]
  var transcriptSegmentCount: Int
  var cueCount: Int

  init(key: AISubtitleCacheKey,
       createdAt: Date = Date(),
       updatedAt: Date = Date(),
       coveredRanges: [AISubtitleTimeRange],
       transcriptSegmentCount: Int,
       cueCount: Int,
       schemaVersion: Int = AISubtitleCacheMetadata.currentSchemaVersion) {
    self.schemaVersion = schemaVersion
    self.key = key
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.coveredRanges = coveredRanges
    self.transcriptSegmentCount = transcriptSegmentCount
    self.cueCount = cueCount
  }
}

struct AISubtitleCachePolicy {
  static let maximumBytesDefaultsKey = "aiSubtitle.cacheMaximumBytes"
  static let defaultMaximumBytes: Int64 = 2 * 1024 * 1024 * 1024

  var maximumBytes: Int64

  init(maximumBytes: Int64 = (UserDefaults.standard.object(forKey: maximumBytesDefaultsKey) as? NSNumber)?.int64Value
    ?? defaultMaximumBytes) {
    self.maximumBytes = max(0, maximumBytes)
  }
}

struct AISubtitleCacheUsage: Hashable {
  var totalBytes: Int64
  var entryCount: Int
  var removedBytes: Int64
  var removedEntryCount: Int
}

struct AISubtitleCacheStore {
  var layout: AISubtitleCacheLayout
  var fileManager: FileManager = .default
  private let writer = AISubtitleFileWriter()

  init(layout: AISubtitleCacheLayout = AISubtitleCacheLayout(),
       fileManager: FileManager = .default) {
    self.layout = layout
    self.fileManager = fileManager
  }

  @discardableResult
  func save(transcript: [AISubtitleSegment],
            cues: [AISubtitleCue],
            coveredRanges: [AISubtitleTimeRange],
            for key: AISubtitleCacheKey,
            now: Date = Date()) throws -> AISubtitleCacheArtifacts {
    let artifacts = try layout.artifacts(for: key, createDirectories: true)
    let existingMetadata = try? metadata(for: key)
    let metadata = AISubtitleCacheMetadata(key: key,
                                           createdAt: existingMetadata?.createdAt ?? now,
                                           updatedAt: now,
                                           coveredRanges: coveredRanges,
                                           transcriptSegmentCount: transcript.count,
                                           cueCount: cues.count)

    try encodedData(transcript).write(to: artifacts.transcriptURL, options: .atomic)
    try encodedData(cues).write(to: artifacts.translatedCuesURL, options: .atomic)
    try writer.string(for: cues, format: .webVTT)
      .write(to: artifacts.translatedVTTURL, atomically: true, encoding: .utf8)
    try writer.string(for: cues, format: .srt)
      .write(to: artifacts.translatedSRTURL, atomically: true, encoding: .utf8)
    // Metadata is the commit marker. Readers only accept a cache after this write succeeds.
    try encodedData(metadata).write(to: artifacts.metadataURL, options: .atomic)
    _ = try? prune(maximumBytes: AISubtitleCachePolicy().maximumBytes, excluding: key)
    return artifacts
  }

  func metadata(for key: AISubtitleCacheKey) throws -> AISubtitleCacheMetadata {
    let artifacts = try layout.artifacts(for: key)
    let data = try Data(contentsOf: artifacts.metadataURL)
    return try decoder().decode(AISubtitleCacheMetadata.self, from: data)
  }

  func cachedContent(for key: AISubtitleCacheKey) throws -> (metadata: AISubtitleCacheMetadata,
                                                              transcript: [AISubtitleSegment],
                                                              cues: [AISubtitleCue]) {
    let artifacts = try layout.artifacts(for: key)
    let metadata = try self.metadata(for: key)
    guard metadata.schemaVersion == AISubtitleCacheMetadata.currentSchemaVersion,
          metadata.key.stableIdentifier == key.stableIdentifier else {
      throw AISubtitleError(code: "cache_schema_mismatch",
                            message: "The AI subtitle cache was created by an incompatible schema.")
    }
    let transcript = try decoder().decode([AISubtitleSegment].self,
                                          from: Data(contentsOf: artifacts.transcriptURL))
    let cues = try decoder().decode([AISubtitleCue].self,
                                    from: Data(contentsOf: artifacts.translatedCuesURL))
    return (metadata, transcript, cues)
  }

  func cachedVTT(for key: AISubtitleCacheKey) -> URL? {
    guard let artifacts = try? layout.artifacts(for: key),
          fileManager.fileExists(atPath: artifacts.metadataURL.path),
          fileManager.fileExists(atPath: artifacts.translatedCuesURL.path),
          fileManager.fileExists(atPath: artifacts.translatedVTTURL.path),
          (try? cachedContent(for: key)) != nil else {
      return nil
    }
    return artifacts.translatedVTTURL
  }

  func usage() throws -> AISubtitleCacheUsage {
    let entries = try cacheEntries()
    return AISubtitleCacheUsage(totalBytes: entries.reduce(0) { $0 + $1.byteCount },
                                entryCount: entries.count,
                                removedBytes: 0,
                                removedEntryCount: 0)
  }

  @discardableResult
  func prune(maximumBytes: Int64,
             excluding protectedKey: AISubtitleCacheKey? = nil) throws -> AISubtitleCacheUsage {
    var entries = try cacheEntries()
    var totalBytes = entries.reduce(0) { $0 + $1.byteCount }
    let protectedDirectoryName = protectedKey?.stableIdentifier
    var removedBytes: Int64 = 0
    var removedEntryCount = 0

    entries.sort { $0.updatedAt < $1.updatedAt }
    for entry in entries where totalBytes > max(0, maximumBytes) {
      guard entry.url.lastPathComponent != protectedDirectoryName else { continue }
      try fileManager.removeItem(at: entry.url)
      totalBytes -= entry.byteCount
      removedBytes += entry.byteCount
      removedEntryCount += 1
    }
    return AISubtitleCacheUsage(totalBytes: totalBytes,
                                entryCount: entries.count - removedEntryCount,
                                removedBytes: removedBytes,
                                removedEntryCount: removedEntryCount)
  }

  private func cacheEntries() throws -> [(url: URL, byteCount: Int64, updatedAt: Date)] {
    guard fileManager.fileExists(atPath: layout.rootURL.path) else { return [] }
    let directories = try fileManager.contentsOfDirectory(at: layout.rootURL,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
    return try directories.compactMap { directoryURL in
      let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else { return nil }
      let metadataURL = directoryURL.appendingPathComponent("metadata.json")
      let updatedAt = (try? decodedMetadata(at: metadataURL).updatedAt)
        ?? (try? directoryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return (directoryURL, try directoryByteCount(directoryURL), updatedAt)
    }
  }

  private func decodedMetadata(at url: URL) throws -> AISubtitleCacheMetadata {
    try decoder().decode(AISubtitleCacheMetadata.self, from: Data(contentsOf: url))
  }

  private func directoryByteCount(_ directoryURL: URL) throws -> Int64 {
    guard let enumerator = fileManager.enumerator(at: directoryURL,
                                                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true {
        total += Int64(values.fileSize ?? 0)
      }
    }
    return total
  }

  private func encodedData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

struct AISubtitleFilePipeline {
  var assembler = AISubtitleTimelineAssembler()
  var cacheStore = AISubtitleCacheStore()

  func prepare(transcript: [AISubtitleSegment],
               targetLanguage: AISubtitleLanguage,
               cacheKey: AISubtitleCacheKey) throws -> AISubtitleCacheArtifacts {
    let cues = assembler.assemble(transcript, targetLanguage: targetLanguage)
    guard !cues.isEmpty else {
      throw AISubtitleError(code: "empty_transcript",
                            message: "The transcript does not contain any timed subtitle text.")
    }
    return try cacheStore.save(transcript: transcript,
                               cues: cues,
                               coveredRanges: coveredRanges(for: cues),
                               for: cacheKey)
  }

  func prepare(transcriptURL: URL,
               targetLanguage: AISubtitleLanguage,
               cacheKey: AISubtitleCacheKey) throws -> AISubtitleCacheArtifacts {
    let data = try Data(contentsOf: transcriptURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let transcript = try decoder.decode([AISubtitleSegment].self, from: data)
    return try prepare(transcript: transcript,
                       targetLanguage: targetLanguage,
                       cacheKey: cacheKey)
  }

  private func coveredRanges(for cues: [AISubtitleCue]) -> [AISubtitleTimeRange] {
    guard let first = cues.first else { return [] }
    var ranges = [first.timeRange]
    for cue in cues.dropFirst() {
      var last = ranges.removeLast()
      if cue.timeRange.start <= last.end + 1 {
        last.end = max(last.end, cue.timeRange.end)
        ranges.append(last)
      } else {
        ranges.append(last)
        ranges.append(cue.timeRange)
      }
    }
    return ranges
  }
}

final class AISubtitleFileLoader {
  private let minimumReloadInterval: TimeInterval
  private var loadedURL: URL?
  private var lastLoadAt: Date?
  private var pendingReload: DispatchWorkItem?

  init(minimumReloadInterval: TimeInterval = 2) {
    self.minimumReloadInterval = minimumReloadInterval
  }

  func update(url: URL, load: @escaping (URL) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let now = Date()
      let isNewFile = self.loadedURL?.standardizedFileURL != url.standardizedFileURL
      let elapsed = now.timeIntervalSince(self.lastLoadAt ?? .distantPast)
      if isNewFile || elapsed >= self.minimumReloadInterval {
        self.performLoad(url: url, load: load)
        return
      }

      self.pendingReload?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.performLoad(url: url, load: load)
      }
      self.pendingReload = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + self.minimumReloadInterval - elapsed,
                                    execute: workItem)
    }
  }

  func reset() {
    DispatchQueue.main.async { [weak self] in
      self?.pendingReload?.cancel()
      self?.pendingReload = nil
      self?.loadedURL = nil
      self?.lastLoadAt = nil
    }
  }

  private func performLoad(url: URL, load: (URL) -> Void) {
    pendingReload?.cancel()
    pendingReload = nil
    loadedURL = url
    lastLoadAt = Date()
    load(url)
  }
}
