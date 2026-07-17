//
//  AISubtitleCore.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Foundation

func aiSubtitleLocalized(_ key: String, fallback: String) -> String {
  NSLocalizedString(key,
                    tableName: nil,
                    bundle: .main,
                    value: fallback,
                    comment: "AI subtitles")
}

enum AISubtitleProviderID: String, Codable, CaseIterable {
  case apple
  case openAI
  case aliyun
  case whisperCpp
}

extension AISubtitleProviderID {
  init?(preferenceIndex: Int) {
    switch preferenceIndex {
    case 0: self = .apple
    case 1: self = .openAI
    case 2: self = .aliyun
    case 3: self = .whisperCpp
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .apple:
      return "Apple"
    case .openAI:
      return "OpenAI"
    case .aliyun:
      return "Aliyun"
    case .whisperCpp:
      return "whisper.cpp"
    }
  }

  var isCloudProvider: Bool {
    switch self {
    case .openAI, .aliyun:
      return true
    case .apple, .whisperCpp:
      return false
    }
  }
}

enum AISubtitleProviderModelCatalog {
  static func identifier(for providerID: AISubtitleProviderID?,
                         role: AISubtitleProviderRole) -> String? {
    guard let providerID = providerID else { return nil }
    switch (providerID, role) {
    case (.apple, .transcriber):
      return "apple-speech-transcriber-v1"
    case (.apple, .translator):
      return "apple-translation-system"
    case (.openAI, .transcriber):
      return "whisper-1"
    case (.openAI, .translator):
      return "gpt-5.6-luna"
    case (.aliyun, .transcriber):
      return "paraformer-v2"
    case (.aliyun, .translator):
      return "aliyun-machine-translation"
    case (.whisperCpp, .transcriber):
      return "whisper-cpp"
    case (.whisperCpp, .translator):
      return nil
    }
  }
}

enum AISubtitleProviderRole: String, Codable {
  case transcriber
  case translator
}

enum AISubtitleProviderStatus: String, Codable {
  case available
  case unavailable
  case needsAuthorization
  case needsConfiguration
  case needsDownload
  case requiresRuntimeProbe
}

enum AISubtitlePlanStatus: String, Codable {
  case ready
  case unavailable
  case needsConfiguration
  case needsDownload
  case requiresRuntimeProbe
}

struct AISubtitleLanguage: Codable, Hashable {
  var code: String

  init(_ code: String) {
    self.code = code
  }

  func isEquivalent(to other: AISubtitleLanguage) -> Bool {
    let lhs = normalizedComponents
    let rhs = other.normalizedComponents
    guard lhs.primary == rhs.primary else { return false }
    guard lhs.primary == "zh" else { return true }
    guard let lhsScript = lhs.chineseScript, let rhsScript = rhs.chineseScript else { return true }
    return lhsScript == rhsScript
  }

  private var normalizedComponents: (primary: String, chineseScript: String?) {
    let parts = code.replacingOccurrences(of: "_", with: "-")
      .lowercased()
      .split(separator: "-")
      .map(String.init)
    let primary = parts.first ?? code.lowercased()
    let script: String?
    if parts.contains("hant") || parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) {
      script = "hant"
    } else if parts.contains("hans") || parts.contains(where: { ["cn", "sg"].contains($0) }) {
      script = "hans"
    } else {
      script = nil
    }
    return (primary, script)
  }
}

enum AISubtitleSuggestionPolicy {
  static func shouldSchedule(isEnabled: Bool,
                             mediaURL: URL?,
                             previouslySuggestedMediaURL: URL?) -> Bool {
    isEnabled && mediaURL != nil && mediaURL != previouslySuggestedMediaURL
  }

  static func shouldPresent(scheduledMediaURL: URL,
                            currentMediaURL: URL?,
                            isPlaybackActive: Bool,
                            hasAudioTracks: Bool,
                            hasSubtitleTracks: Bool,
                            hasExportableAISubtitles: Bool) -> Bool {
    scheduledMediaURL == currentMediaURL
      && isPlaybackActive
      && hasAudioTracks
      && !hasSubtitleTracks
      && !hasExportableAISubtitles
  }
}

struct AISubtitleTimeRange: Codable, Hashable {
  var start: Double
  var end: Double

  init(start: Double, end: Double) {
    self.start = max(0, start)
    self.end = max(self.start, end)
  }

  var duration: Double {
    end - start
  }

  var isEmpty: Bool {
    duration <= 0
  }

  func contains(_ time: Double) -> Bool {
    time >= start && time <= end
  }

  func intersects(_ other: AISubtitleTimeRange) -> Bool {
    start < other.end && other.start < end
  }

  func expanded(by seconds: Double) -> AISubtitleTimeRange {
    AISubtitleTimeRange(start: start - seconds, end: end + seconds)
  }
}

struct AISubtitleMediaContext: Codable, Hashable {
  var url: URL
  var isNetworkResource: Bool
  var fileSize: UInt64?
  var fileModifiedAt: Date?
  var audioTrackID: Int?
  var audioStreamIndex: Int?
  var sourceLanguage: AISubtitleLanguage?
  var targetLanguage: AISubtitleLanguage

  init(url: URL,
       isNetworkResource: Bool,
       fileSize: UInt64? = nil,
       fileModifiedAt: Date? = nil,
       audioTrackID: Int? = nil,
       audioStreamIndex: Int? = nil,
       sourceLanguage: AISubtitleLanguage? = nil,
       targetLanguage: AISubtitleLanguage) {
    self.url = url
    self.isNetworkResource = isNetworkResource
    self.fileSize = fileSize
    self.fileModifiedAt = fileModifiedAt
    self.audioTrackID = audioTrackID
    self.audioStreamIndex = audioStreamIndex
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
  }
}

struct AISubtitleSegment: Codable, Hashable {
  var id: String
  var timeRange: AISubtitleTimeRange
  var text: String
  var language: AISubtitleLanguage?
  var confidence: Double?

  init(id: String = UUID().uuidString,
       timeRange: AISubtitleTimeRange,
       text: String,
       language: AISubtitleLanguage? = nil,
       confidence: Double? = nil) {
    self.id = id
    self.timeRange = timeRange
    self.text = text
    self.language = language
    self.confidence = confidence
  }
}

struct AISubtitleCue: Codable, Hashable {
  var id: String
  var timeRange: AISubtitleTimeRange
  var text: String
  var originalText: String?
  var language: AISubtitleLanguage

  init(id: String = UUID().uuidString,
       timeRange: AISubtitleTimeRange,
       text: String,
       originalText: String? = nil,
       language: AISubtitleLanguage) {
    self.id = id
    self.timeRange = timeRange
    self.text = text
    self.originalText = originalText
    self.language = language
  }
}

struct AISubtitleError: Error, Codable, Hashable {
  var code: String
  var message: String
  var recoverable: Bool

  init(code: String, message: String, recoverable: Bool = true) {
    self.code = code
    self.message = message
    self.recoverable = recoverable
  }
}

extension AISubtitleError: LocalizedError {
  var errorDescription: String? { message }
}

final class AISubtitleSwiftTaskBag {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var reservations: Set<UUID> = []
  private var canceled = false

  func reserve() -> UUID {
    let identifier = UUID()
    lock.lock()
    if !canceled { reservations.insert(identifier) }
    lock.unlock()
    return identifier
  }

  func attach(_ task: Task<Void, Never>, to identifier: UUID) {
    lock.lock()
    if canceled {
      lock.unlock()
      task.cancel()
    } else if reservations.contains(identifier) {
      tasks[identifier] = task
      lock.unlock()
    } else {
      lock.unlock()
    }
  }

  func remove(_ identifier: UUID) {
    lock.lock()
    reservations.remove(identifier)
    tasks.removeValue(forKey: identifier)
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    canceled = true
    let pending = Array(tasks.values)
    tasks.removeAll()
    reservations.removeAll()
    lock.unlock()
    pending.forEach { $0.cancel() }
  }

  var activeTaskCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tasks.count
  }
}

struct AISubtitleTaskState: Codable, Hashable {
  enum Phase: String, Codable {
    case idle
    case preparing
    case extracting
    case transcribing
    case translating
    case assembling
    case loading
    case maintaining
    case completed
    case failed
    case canceled
  }

  var phase: Phase
  var currentRange: AISubtitleTimeRange?
  var coveredRange: AISubtitleTimeRange?
  var progress: Double?
  var message: String?
  var error: AISubtitleError?

  init(_ phase: Phase,
       currentRange: AISubtitleTimeRange? = nil,
       coveredRange: AISubtitleTimeRange? = nil,
       progress: Double? = nil,
       message: String? = nil,
       error: AISubtitleError? = nil) {
    self.phase = phase
    self.currentRange = currentRange
    self.coveredRange = coveredRange
    if let progress = progress {
      self.progress = min(max(progress, 0), 1)
    } else {
      self.progress = nil
    }
    self.message = message
    self.error = error
  }
}

struct AISubtitleJob: Codable, Hashable {
  var id: UUID
  var media: AISubtitleMediaContext
  var state: AISubtitleTaskState
  var providerPlan: AISubtitleProviderPlan?
  var requestedAt: Date

  init(id: UUID = UUID(),
       media: AISubtitleMediaContext,
       state: AISubtitleTaskState = AISubtitleTaskState(.idle),
       providerPlan: AISubtitleProviderPlan? = nil,
       requestedAt: Date = Date()) {
    self.id = id
    self.media = media
    self.state = state
    self.providerPlan = providerPlan
    self.requestedAt = requestedAt
  }
}

struct AISubtitleAudioChunk: Codable, Hashable {
  enum Format: String, Codable {
    case wav16kMono
    case pcm16kMono
  }

  var url: URL
  var timeRange: AISubtitleTimeRange
  var format: Format
  var audioTrackID: Int?
  var audioStreamIndex: Int?

  init(url: URL,
       timeRange: AISubtitleTimeRange,
       format: Format,
       audioTrackID: Int? = nil,
       audioStreamIndex: Int? = nil) {
    self.url = url
    self.timeRange = timeRange
    self.format = format
    self.audioTrackID = audioTrackID
    self.audioStreamIndex = audioStreamIndex
  }
}

struct AISubtitleProviderCapability: Codable, Hashable {
  var providerID: AISubtitleProviderID
  var role: AISubtitleProviderRole
  var status: AISubtitleProviderStatus
  var reason: String?
  var supportsCloudProcessing: Bool
  var modelIdentifier: String?

  init(providerID: AISubtitleProviderID,
       role: AISubtitleProviderRole,
       status: AISubtitleProviderStatus,
       reason: String? = nil,
       supportsCloudProcessing: Bool,
       modelIdentifier: String? = nil) {
    self.providerID = providerID
    self.role = role
    self.status = status
    self.reason = reason
    self.supportsCloudProcessing = supportsCloudProcessing
    self.modelIdentifier = modelIdentifier
  }

  var debugSummary: String {
    let model = modelIdentifier.map { ", model=\($0)" } ?? ""
    let reasonText = reason.map { ", reason=\($0)" } ?? ""
    return "\(providerID.displayName).\(role.rawValue)=\(status.rawValue)\(model)\(reasonText)"
  }
}

struct AISubtitleProviderPlan: Codable, Hashable {
  var status: AISubtitlePlanStatus
  var transcriber: AISubtitleProviderID?
  var translator: AISubtitleProviderID?
  var reason: String?
  var requiresCloudAuthorization: Bool

  init(status: AISubtitlePlanStatus,
       transcriber: AISubtitleProviderID?,
       translator: AISubtitleProviderID?,
       reason: String? = nil,
       requiresCloudAuthorization: Bool = false) {
    self.status = status
    self.transcriber = transcriber
    self.translator = translator
    self.reason = reason
    self.requiresCloudAuthorization = requiresCloudAuthorization
  }

  var debugSummary: String {
    let transcriberName = transcriber?.displayName ?? "none"
    let translatorName = translator?.displayName ?? "none"
    let cloud = requiresCloudAuthorization ? ", cloudAuthorization=true" : ""
    let reasonText = reason.map { ", reason=\($0)" } ?? ""
    return "status=\(status.rawValue), transcriber=\(transcriberName), translator=\(translatorName)\(cloud)\(reasonText)"
  }
}

struct AISubtitleProviderRequest: Codable, Hashable {
  var sourceLanguage: AISubtitleLanguage?
  var targetLanguage: AISubtitleLanguage
  var media: AISubtitleMediaContext?

  init(sourceLanguage: AISubtitleLanguage?,
       targetLanguage: AISubtitleLanguage,
       media: AISubtitleMediaContext? = nil) {
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.media = media
  }
}

extension AISubtitleProviderRequest {
  var requiresTranslation: Bool {
    guard let sourceLanguage = sourceLanguage else { return true }
    return !sourceLanguage.isEquivalent(to: targetLanguage)
  }
}

struct AISubtitleCacheKey: Codable, Hashable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var mediaURLString: String
  var fileSize: UInt64?
  var fileModifiedAt: Date?
  var audioTrackID: Int?
  var audioStreamIndex: Int?
  var sourceLanguageCode: String?
  var targetLanguageCode: String
  var transcriberID: AISubtitleProviderID?
  var translatorID: AISubtitleProviderID?
  var transcriberModelIdentifier: String?
  var translatorModelIdentifier: String?

  init(media: AISubtitleMediaContext,
       transcriberID: AISubtitleProviderID?,
       translatorID: AISubtitleProviderID?,
       transcriberModelIdentifier: String? = nil,
       translatorModelIdentifier: String? = nil,
       schemaVersion: Int = AISubtitleCacheKey.currentSchemaVersion) {
    self.schemaVersion = schemaVersion
    self.mediaURLString = media.url.absoluteString
    self.fileSize = media.fileSize
    self.fileModifiedAt = media.fileModifiedAt
    self.audioTrackID = media.audioTrackID
    self.audioStreamIndex = media.audioStreamIndex
    self.sourceLanguageCode = media.sourceLanguage?.code
    self.targetLanguageCode = media.targetLanguage.code
    self.transcriberID = transcriberID
    self.translatorID = translatorID
    self.transcriberModelIdentifier = transcriberModelIdentifier
    self.translatorModelIdentifier = translatorModelIdentifier
  }

  var stableIdentifier: String {
    AISubtitleStableHash.hash(canonicalString)
  }

  private var canonicalString: String {
    [
      "schema=\(schemaVersion)",
      "media=\(mediaURLString)",
      "size=\(fileSize.map(String.init) ?? "-")",
      "mtime=\(fileModifiedAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "-")",
      "audioTrack=\(audioTrackID.map(String.init) ?? "-")",
      "audioStream=\(audioStreamIndex.map(String.init) ?? "-")",
      "sourceLanguage=\(sourceLanguageCode ?? "-")",
      "targetLanguage=\(targetLanguageCode)",
      "transcriber=\(transcriberID?.rawValue ?? "-")",
      "translator=\(translatorID?.rawValue ?? "-")",
      "transcriberModel=\(transcriberModelIdentifier ?? "-")",
      "translatorModel=\(translatorModelIdentifier ?? "-")"
    ].joined(separator: "\n")
  }
}

struct AISubtitleCacheArtifacts: Codable, Hashable {
  var directoryURL: URL
  var metadataURL: URL
  var transcriptURL: URL
  var translatedCuesURL: URL
  var translatedVTTURL: URL
  var translatedSRTURL: URL
  var chunksDirectoryURL: URL
}

struct AISubtitleCacheLayout {
  static let rootDirectoryName = "ai_subtitles"

  var rootURL: URL
  var fileManager: FileManager

  init(rootURL: URL = Utility.cacheURL.appendingPathComponent(rootDirectoryName, isDirectory: true),
       fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  func artifacts(for key: AISubtitleCacheKey, createDirectories: Bool = false) throws -> AISubtitleCacheArtifacts {
    let directoryURL = rootURL.appendingPathComponent(key.stableIdentifier, isDirectory: true)
    let chunksDirectoryURL = directoryURL.appendingPathComponent("chunks", isDirectory: true)
    if createDirectories {
      try fileManager.createDirectory(at: chunksDirectoryURL, withIntermediateDirectories: true)
    }
    return AISubtitleCacheArtifacts(
      directoryURL: directoryURL,
      metadataURL: directoryURL.appendingPathComponent("metadata.json", isDirectory: false),
      transcriptURL: directoryURL.appendingPathComponent("transcript.json", isDirectory: false),
      translatedCuesURL: directoryURL.appendingPathComponent("translated-cues.json", isDirectory: false),
      translatedVTTURL: directoryURL.appendingPathComponent("translated.vtt", isDirectory: false),
      translatedSRTURL: directoryURL.appendingPathComponent("translated.srt", isDirectory: false),
      chunksDirectoryURL: chunksDirectoryURL
    )
  }
}

private enum AISubtitleStableHash {
  static func hash(_ string: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
  }
}

protocol AISubtitleTranscriber {
  var providerID: AISubtitleProviderID { get }
  var modelIdentifier: String { get }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability
  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void)
}

protocol AISubtitleTranslator {
  var providerID: AISubtitleProviderID { get }
  var modelIdentifier: String { get }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability
  func translate(_ segments: [AISubtitleSegment],
                 request: AISubtitleProviderRequest,
                 completion: @escaping (Result<[AISubtitleCue], AISubtitleError>) -> Void)
}

protocol AISubtitleCancelableProvider {
  func cancelAll()
}

protocol AISubtitleCredentialChecking {
  func hasCredential(for providerID: AISubtitleProviderID) -> Bool
}

extension KeychainAccess.ServiceName {
  static let aiSubtitleOpenAI = KeychainAccess.ServiceName(rawValue: "IINA AI Subtitle OpenAI")
  static let aiSubtitleAliyun = KeychainAccess.ServiceName(rawValue: "IINA AI Subtitle Aliyun")
  static let aiSubtitleAliyunMachineTranslation = KeychainAccess.ServiceName(rawValue: "IINA AI Subtitle Aliyun Machine Translation")
}

struct AISubtitleKeychainCredentialChecker: AISubtitleCredentialChecking {
  func hasCredential(for providerID: AISubtitleProviderID) -> Bool {
    let serviceName: KeychainAccess.ServiceName
    switch providerID {
    case .openAI:
      serviceName = .aiSubtitleOpenAI
    case .aliyun:
      serviceName = .aiSubtitleAliyun
    case .apple, .whisperCpp:
      return false
    }
    return (try? KeychainAccess.read(username: nil, forService: serviceName)) != nil
  }
}

struct AISubtitlePlatform: Codable, Hashable {
  var majorVersion: Int
  var minorVersion: Int
  var patchVersion: Int
  var architecture: String

  static var current: AISubtitlePlatform {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let architecture: String
    #if arch(arm64)
    architecture = "arm64"
    #elseif arch(x86_64)
    architecture = "x86_64"
    #else
    architecture = "unknown"
    #endif
    return AISubtitlePlatform(majorVersion: version.majorVersion,
                              minorVersion: version.minorVersion,
                              patchVersion: version.patchVersion,
                              architecture: architecture)
  }

  var supportsAppleAISubtitles: Bool {
    guard majorVersion >= 26 else { return false }
    if #available(macOS 26.0, *) {
      return true
    }
    return false
  }

  var isAppleSilicon: Bool {
    architecture == "arm64" || architecture.hasPrefix("arm64")
  }

  var versionString: String {
    "\(majorVersion).\(minorVersion).\(patchVersion)"
  }
}

protocol AISubtitleLocalAssetChecking {
  var whisperBinaryURL: URL? { get }
  var whisperModelURL: URL? { get }
}

struct AISubtitleLocalAssetLocator: AISubtitleLocalAssetChecking {
  var fileManager: FileManager = .default

  var whisperBinaryURL: URL? {
    let candidates = [
      Utility.appSupportDirUrl
        .appendingPathComponent("whisper.cpp", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("whisper-cli"),
      Utility.binariesURL.appendingPathComponent("whisper-cli"),
      Utility.binariesURL.appendingPathComponent("main"),
      Utility.exeDirURL.appendingPathComponent("whisper-cli"),
      Utility.exeDirURL.appendingPathComponent("main")
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }

  var whisperModelURL: URL? {
    let modelDir = Utility.appSupportDirUrl
      .appendingPathComponent("whisper.cpp", isDirectory: true)
      .appendingPathComponent("models", isDirectory: true)
    guard let contents = try? fileManager.contentsOfDirectory(at: modelDir,
                                                              includingPropertiesForKeys: nil) else {
      return nil
    }
    let models = contents
      .filter { $0.pathExtension == "bin" || $0.lastPathComponent.hasPrefix("ggml-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if let selectedName = UserDefaults.standard.string(forKey: AISubtitleWhisperModelManager.selectedModelDefaultsKey),
       let selected = models.first(where: { $0.lastPathComponent == selectedName }) {
      return selected
    }
    return models.first
  }
}

final class AISubtitleCapabilityDetector {
  enum CloudPolicy {
    case localOnly
    case cloudAllowed
  }

  private let platform: AISubtitlePlatform
  private let credentialChecker: AISubtitleCredentialChecking
  private let assetLocator: AISubtitleLocalAssetChecking

  init(platform: AISubtitlePlatform = .current,
       credentialChecker: AISubtitleCredentialChecking = AISubtitleKeychainCredentialChecker(),
       assetLocator: AISubtitleLocalAssetChecking = AISubtitleLocalAssetLocator()) {
    self.platform = platform
    self.credentialChecker = credentialChecker
    self.assetLocator = assetLocator
  }

  func capabilities(for request: AISubtitleProviderRequest) -> [AISubtitleProviderCapability] {
    [
      appleCapability(role: .transcriber),
      appleCapability(role: .translator),
      cloudCapability(providerID: .openAI, role: .transcriber),
      cloudCapability(providerID: .openAI, role: .translator),
      cloudCapability(providerID: .aliyun, role: .transcriber),
      cloudCapability(providerID: .aliyun, role: .translator),
      whisperCapability(role: .transcriber),
      whisperTranslatorCapability()
    ]
  }

  func recommendedPlan(for request: AISubtitleProviderRequest,
                       cloudPolicy: CloudPolicy = .cloudAllowed) -> AISubtitleProviderPlan {
    let appleTranscriber = appleCapability(role: .transcriber)
    let appleTranslator = appleCapability(role: .translator)
    if appleTranscriber.status == .requiresRuntimeProbe && appleTranslator.status == .requiresRuntimeProbe {
      let translationRequired = request.requiresTranslation
      return AISubtitleProviderPlan(status: .requiresRuntimeProbe,
                                    transcriber: .apple,
                                    translator: translationRequired ? .apple : nil,
                                    reason: translationRequired
                                      ? "macOS \(platform.versionString) can use Apple local speech and translation adapters after runtime language probing."
                                      : "macOS \(platform.versionString) can use Apple local speech after runtime language probing; no translation is required.")
    }

    if cloudPolicy == .cloudAllowed {
      if credentialChecker.hasCredential(for: .openAI) {
        return AISubtitleProviderPlan(status: .ready,
                                      transcriber: .openAI,
                                      translator: .openAI,
                                      reason: "OpenAI credentials are configured.",
                                      requiresCloudAuthorization: true)
      }

      if credentialChecker.hasCredential(for: .aliyun) {
        return AISubtitleProviderPlan(status: .ready,
                                      transcriber: .aliyun,
                                      translator: .aliyun,
                                      reason: "Aliyun credentials are configured.",
                                      requiresCloudAuthorization: true)
      }
    }

    let whisper = whisperCapability(role: .transcriber)
    if whisper.status == .available {
      if request.sourceLanguage?.code == request.targetLanguage.code {
        return AISubtitleProviderPlan(status: .ready,
                                      transcriber: .whisperCpp,
                                      translator: nil,
                                      reason: "whisper.cpp is available and no translation is required.")
      }
      if platform.supportsAppleAISubtitles {
        return AISubtitleProviderPlan(status: .requiresRuntimeProbe,
                                      transcriber: .whisperCpp,
                                      translator: .apple,
                                      reason: "whisper.cpp is available for local transcription; Apple translation requires runtime language probing.")
      }
      if cloudPolicy == .cloudAllowed {
        return AISubtitleProviderPlan(status: .needsConfiguration,
                                      transcriber: .whisperCpp,
                                      translator: nil,
                                      reason: "whisper.cpp can transcribe locally, but translation requires OpenAI or Aliyun credentials on this macOS version.")
      }
      return AISubtitleProviderPlan(status: .unavailable,
                                    transcriber: .whisperCpp,
                                    translator: nil,
                                    reason: "whisper.cpp can transcribe locally, but no local translation provider is available on this macOS version.")
    }
    if whisper.status == .needsDownload {
      return AISubtitleProviderPlan(status: .needsDownload,
                                    transcriber: .whisperCpp,
                                    translator: nil,
                                    reason: whisper.reason)
    }

    if cloudPolicy == .cloudAllowed {
      return AISubtitleProviderPlan(status: .needsConfiguration,
                                    transcriber: nil,
                                    translator: nil,
                                    reason: "Configure OpenAI or Aliyun credentials, or install whisper.cpp local assets.")
    }

    return AISubtitleProviderPlan(status: .unavailable,
                                  transcriber: nil,
                                  translator: nil,
                                  reason: "No local AI subtitle provider is currently available.")
  }

  private func appleCapability(role: AISubtitleProviderRole) -> AISubtitleProviderCapability {
    guard platform.supportsAppleAISubtitles else {
      return AISubtitleProviderCapability(providerID: .apple,
                                          role: role,
                                          status: .unavailable,
                                          reason: "Apple local AI subtitle support requires macOS 26 or later.",
                                          supportsCloudProcessing: false)
    }
    return AISubtitleProviderCapability(providerID: .apple,
                                        role: role,
                                        status: .requiresRuntimeProbe,
                                        reason: "macOS 26+ is present; the \(role.rawValue) adapter must probe language assets and authorization at runtime.",
                                        supportsCloudProcessing: false)
  }

  private func cloudCapability(providerID: AISubtitleProviderID,
                               role: AISubtitleProviderRole) -> AISubtitleProviderCapability {
    let hasCredential = credentialChecker.hasCredential(for: providerID)
    return AISubtitleProviderCapability(providerID: providerID,
                                        role: role,
                                        status: hasCredential ? .available : .needsConfiguration,
                                        reason: hasCredential ? nil : "\(providerID.displayName) API credentials are not configured.",
                                        supportsCloudProcessing: true)
  }

  private func whisperCapability(role: AISubtitleProviderRole) -> AISubtitleProviderCapability {
    guard role == .transcriber else {
      return whisperTranslatorCapability()
    }
    guard assetLocator.whisperBinaryURL != nil else {
      return AISubtitleProviderCapability(providerID: .whisperCpp,
                                          role: role,
                                          status: .needsDownload,
                                          reason: "whisper.cpp executable is not installed.",
                                          supportsCloudProcessing: false)
    }
    guard assetLocator.whisperModelURL != nil else {
      return AISubtitleProviderCapability(providerID: .whisperCpp,
                                          role: role,
                                          status: .needsDownload,
                                          reason: "No whisper.cpp model is installed.",
                                          supportsCloudProcessing: false)
    }
    return AISubtitleProviderCapability(providerID: .whisperCpp,
                                        role: role,
                                        status: .available,
                                        reason: nil,
                                        supportsCloudProcessing: false)
  }

  private func whisperTranslatorCapability() -> AISubtitleProviderCapability {
    AISubtitleProviderCapability(providerID: .whisperCpp,
                                 role: .translator,
                                 status: .unavailable,
                                 reason: "whisper.cpp only provides transcription; translation must use Apple or a cloud provider.",
                                 supportsCloudProcessing: false)
  }
}
