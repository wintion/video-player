//
//  AppleAISubtitleProvider.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import AVFoundation
import Foundation
import Speech
import Translation

final class AppleAISubtitleTranscriber: AISubtitleTranscriber, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.apple
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .apple, role: .transcriber)!
  private let taskBag = AISubtitleSwiftTaskBag()

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    guard #available(macOS 26.0, *) else {
      return capability(status: .unavailable,
                        reason: "Apple SpeechTranscriber requires macOS 26 or later.")
    }
    guard SpeechTranscriber.isAvailable else {
      return capability(status: .unavailable,
                        reason: "Apple SpeechTranscriber is not available on this Mac.")
    }
    guard request.sourceLanguage != nil else {
      return capability(status: .needsConfiguration,
                        reason: "Choose the spoken language because Apple SpeechTranscriber does not auto-detect it.")
    }
    return capability(status: .requiresRuntimeProbe,
                      reason: "The spoken language and its on-device model must be checked asynchronously.")
  }

  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    guard #available(macOS 26.0, *) else {
      completion(.failure(AISubtitleError(code: "apple_speech_unavailable",
                                          message: "Apple SpeechTranscriber requires macOS 26 or later.",
                                          recoverable: false)))
      return
    }
    guard let language = request.sourceLanguage else {
      completion(.failure(AISubtitleError(code: "apple_speech_language_required",
                                          message: "Choose the spoken language before generating subtitles.")))
      return
    }

    let taskIdentifier = taskBag.reserve()
    let task = Task {
      defer { self.taskBag.remove(taskIdentifier) }
      do {
        let segments = try await transcribe(chunk, language: language)
        completion(.success(segments))
      } catch let error as AISubtitleError {
        completion(.failure(error))
      } catch {
        completion(.failure(AISubtitleError(code: "apple_speech_failed",
                                            message: error.localizedDescription)))
      }
    }
    taskBag.attach(task, to: taskIdentifier)
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  @available(macOS 26.0, *)
  func probe(language: AISubtitleLanguage) async -> AISubtitleProviderCapability {
    guard SpeechTranscriber.isAvailable else {
      return capability(status: .unavailable,
                        reason: "Apple SpeechTranscriber is not available on this Mac.")
    }
    let requestedLocale = Locale(identifier: language.code)
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      return capability(status: .unavailable,
                        reason: "Apple SpeechTranscriber does not support \(language.code).")
    }
    let transcriber = SpeechTranscriber(locale: supportedLocale,
                                        preset: .timeIndexedTranscriptionWithAlternatives)
    switch await AssetInventory.status(forModules: [transcriber]) {
    case .installed:
      return capability(status: .available,
                        reason: "The Apple speech model for \(supportedLocale.identifier) is installed.")
    case .supported, .downloading:
      return capability(status: .needsDownload,
                        reason: "The Apple speech model for \(supportedLocale.identifier) must finish downloading.")
    case .unsupported:
      return capability(status: .unavailable,
                        reason: "The Apple speech model for \(supportedLocale.identifier) is unsupported on this Mac.")
    @unknown default:
      return capability(status: .unavailable,
                        reason: "The Apple speech model returned an unknown availability state.")
    }
  }

  @available(macOS 26.0, *)
  func installAssets(language: AISubtitleLanguage,
                     progressHandler: @escaping (Progress) -> Void,
                     completion: @escaping (Result<Void, AISubtitleError>) -> Void) {
    Task {
      do {
        let requestedLocale = Locale(identifier: language.code)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
          throw AISubtitleError(code: "apple_speech_language_unsupported",
                                message: "Apple SpeechTranscriber does not support \(language.code).",
                                recoverable: false)
        }
        let transcriber = SpeechTranscriber(locale: supportedLocale,
                                            preset: .timeIndexedTranscriptionWithAlternatives)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
          progressHandler(installation.progress)
          try await installation.downloadAndInstall()
        }
        completion(.success(()))
      } catch let error as AISubtitleError {
        completion(.failure(error))
      } catch {
        completion(.failure(AISubtitleError(code: "apple_speech_asset_installation_failed",
                                            message: error.localizedDescription)))
      }
    }
  }

  @available(macOS 26.0, *)
  private func transcribe(_ chunk: AISubtitleAudioChunk,
                          language: AISubtitleLanguage) async throws -> [AISubtitleSegment] {
    let requestedLocale = Locale(identifier: language.code)
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw AISubtitleError(code: "apple_speech_language_unsupported",
                            message: "Apple SpeechTranscriber does not support \(language.code).",
                            recoverable: false)
    }
    let transcriber = SpeechTranscriber(locale: supportedLocale,
                                        preset: .timeIndexedTranscriptionWithAlternatives)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw AISubtitleError(code: "apple_speech_assets_required",
                            message: "The on-device speech model for \(supportedLocale.identifier) is not installed.")
    }

    let audioFile = try AVAudioFile(forReading: chunk.url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    async let resultFuture = collectResults(from: transcriber,
                                            chunkOffset: chunk.timeRange.start,
                                            language: language)
    if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
      try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
      await analyzer.cancelAndFinishNow()
    }
    return try await resultFuture
  }

  @available(macOS 26.0, *)
  private func collectResults(from transcriber: SpeechTranscriber,
                              chunkOffset: Double,
                              language: AISubtitleLanguage) async throws -> [AISubtitleSegment] {
    var segments: [AISubtitleSegment] = []
    for try await result in transcriber.results where result.isFinal {
      let text = String(result.text.characters)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let start = chunkOffset + result.range.start.seconds
      let end = start + result.range.duration.seconds
      segments.append(AISubtitleSegment(timeRange: AISubtitleTimeRange(start: start, end: end),
                                        text: text,
                                        language: language))
    }
    return segments
  }

  private func capability(status: AISubtitleProviderStatus,
                          reason: String?) -> AISubtitleProviderCapability {
    AISubtitleProviderCapability(providerID: providerID,
                                 role: .transcriber,
                                 status: status,
                                 reason: reason,
                                 supportsCloudProcessing: false,
                                 modelIdentifier: modelIdentifier)
  }
}

final class AppleAISubtitleTranslator: AISubtitleTranslator, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.apple
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .apple, role: .translator)!
  private let taskBag = AISubtitleSwiftTaskBag()

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    guard #available(macOS 26.0, *) else {
      return capability(status: .unavailable,
                        reason: "Direct Apple Translation sessions require macOS 26 or later.")
    }
    guard request.sourceLanguage != nil else {
      return capability(status: .needsConfiguration,
                        reason: "Choose the source language before translating subtitles.")
    }
    if !request.requiresTranslation {
      return capability(status: .available, reason: "Source and target languages are the same.")
    }
    return capability(status: .requiresRuntimeProbe,
                      reason: "The Apple Translation language pair must be checked asynchronously.")
  }

  func translate(_ segments: [AISubtitleSegment],
                 request: AISubtitleProviderRequest,
                 completion: @escaping (Result<[AISubtitleCue], AISubtitleError>) -> Void) {
    guard #available(macOS 26.0, *) else {
      completion(.failure(AISubtitleError(code: "apple_translation_unavailable",
                                          message: "Direct Apple Translation sessions require macOS 26 or later.",
                                          recoverable: false)))
      return
    }
    guard let sourceLanguage = request.sourceLanguage else {
      completion(.failure(AISubtitleError(code: "apple_translation_source_required",
                                          message: "Choose the source language before translating subtitles.")))
      return
    }
    if sourceLanguage.isEquivalent(to: request.targetLanguage) {
      completion(.success(identityCues(segments, language: request.targetLanguage)))
      return
    }

    let taskIdentifier = taskBag.reserve()
    let task = Task {
      defer { self.taskBag.remove(taskIdentifier) }
      do {
        let cues = try await translate(segments,
                                       sourceLanguage: sourceLanguage,
                                       targetLanguage: request.targetLanguage)
        completion(.success(cues))
      } catch let error as AISubtitleError {
        completion(.failure(error))
      } catch {
        completion(.failure(AISubtitleError(code: "apple_translation_failed",
                                            message: error.localizedDescription)))
      }
    }
    taskBag.attach(task, to: taskIdentifier)
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  @available(macOS 26.0, *)
  func probe(sourceLanguage: AISubtitleLanguage,
             targetLanguage: AISubtitleLanguage) async -> AISubtitleProviderCapability {
    if sourceLanguage.isEquivalent(to: targetLanguage) {
      return capability(status: .available, reason: "Source and target languages are the same.")
    }
    let availability = LanguageAvailability()
    let status = await availability.status(from: Locale.Language(identifier: sourceLanguage.code),
                                           to: Locale.Language(identifier: targetLanguage.code))
    switch status {
    case .installed:
      return capability(status: .available, reason: "The Apple Translation language pair is installed.")
    case .supported:
      return capability(status: .needsDownload, reason: "The Apple Translation language pair requires a download.")
    case .unsupported:
      return capability(status: .unavailable, reason: "The Apple Translation language pair is unsupported.")
    @unknown default:
      return capability(status: .unavailable, reason: "Apple Translation returned an unknown availability state.")
    }
  }

  @available(macOS 26.0, *)
  private func translate(_ segments: [AISubtitleSegment],
                         sourceLanguage: AISubtitleLanguage,
                         targetLanguage: AISubtitleLanguage) async throws -> [AISubtitleCue] {
    let source = Locale.Language(identifier: sourceLanguage.code)
    let target = Locale.Language(identifier: targetLanguage.code)
    let availability = LanguageAvailability()
    switch await availability.status(from: source, to: target) {
    case .installed:
      break
    case .supported:
      throw AISubtitleError(code: "apple_translation_assets_required",
                            message: "The on-device translation languages are not installed.")
    case .unsupported:
      throw AISubtitleError(code: "apple_translation_language_unsupported",
                            message: "Apple Translation does not support this language pair.",
                            recoverable: false)
    @unknown default:
      throw AISubtitleError(code: "apple_translation_availability_unknown",
                            message: "Apple Translation could not determine language availability.")
    }

    let session = TranslationSession(installedSource: source, target: target)
    try await session.prepareTranslation()
    let requests = segments.map {
      TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
    }
    let responses = try await session.translations(from: requests)
    var responseByID: [String: TranslationSession.Response] = [:]
    for response in responses {
      guard let identifier = response.clientIdentifier else {
        throw AISubtitleError(code: "apple_translation_response_id_missing",
                              message: "Apple Translation returned a response without its cue identifier.")
      }
      guard responseByID[identifier] == nil else {
        throw AISubtitleError(code: "apple_translation_response_id_duplicate",
                              message: "Apple Translation returned duplicate cue identifier \(identifier).")
      }
      responseByID[identifier] = response
    }
    return try segments.map { segment in
      guard let response = responseByID[segment.id] else {
        throw AISubtitleError(code: "apple_translation_response_missing",
                              message: "Apple Translation did not return cue \(segment.id).")
      }
      return AISubtitleCue(id: segment.id,
                          timeRange: segment.timeRange,
                          text: response.targetText,
                          originalText: segment.text,
                          language: targetLanguage)
    }
  }

  private func identityCues(_ segments: [AISubtitleSegment],
                            language: AISubtitleLanguage) -> [AISubtitleCue] {
    segments.map {
      AISubtitleCue(id: $0.id,
                    timeRange: $0.timeRange,
                    text: $0.text,
                    originalText: nil,
                    language: language)
    }
  }

  private func capability(status: AISubtitleProviderStatus,
                          reason: String?) -> AISubtitleProviderCapability {
    AISubtitleProviderCapability(providerID: providerID,
                                 role: .translator,
                                 status: status,
                                 reason: reason,
                                 supportsCloudProcessing: false,
                                 modelIdentifier: modelIdentifier)
  }
}
