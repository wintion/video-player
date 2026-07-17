//
//  AISubtitleCloudProvider.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Foundation

private struct AISubtitleOpenAIErrorEnvelope: Decodable {
  struct ServiceError: Decodable {
    var message: String
    var code: String?
  }

  var error: ServiceError?
}

protocol AISubtitleCloudConsentChecking {
  func hasConsent(for providerID: AISubtitleProviderID) -> Bool
}

protocol AISubtitleCloudConsentStoring: AISubtitleCloudConsentChecking {
  func setConsent(_ consent: Bool, for providerID: AISubtitleProviderID)
}

struct UserDefaultsAISubtitleCloudConsentStore: AISubtitleCloudConsentStoring {
  private static let keyPrefix = "aiSubtitle.cloudConsent."
  var userDefaults: UserDefaults = .standard

  func hasConsent(for providerID: AISubtitleProviderID) -> Bool {
    guard providerID.isCloudProvider else { return true }
    return userDefaults.bool(forKey: Self.keyPrefix + providerID.rawValue)
  }

  func setConsent(_ consent: Bool, for providerID: AISubtitleProviderID) {
    guard providerID.isCloudProvider else { return }
    userDefaults.set(consent, forKey: Self.keyPrefix + providerID.rawValue)
  }
}

protocol AISubtitleAPIKeyProviding {
  func apiKey(for providerID: AISubtitleProviderID) -> String?
}

struct AISubtitleKeychainAPIKeyProvider: AISubtitleAPIKeyProviding {
  func apiKey(for providerID: AISubtitleProviderID) -> String? {
    let serviceName: KeychainAccess.ServiceName
    switch providerID {
    case .openAI:
      serviceName = .aiSubtitleOpenAI
    case .aliyun:
      serviceName = .aiSubtitleAliyun
    case .apple, .whisperCpp:
      return nil
    }
    return try? KeychainAccess.read(username: nil, forService: serviceName).password
  }
}

struct AISubtitleCloudCredentialStore {
  func saveOpenAIAPIKey(_ apiKey: String) throws {
    try KeychainAccess.write(username: "api-key",
                             password: apiKey,
                             forService: .aiSubtitleOpenAI)
  }

  func saveAliyunDashScopeAPIKey(_ apiKey: String) throws {
    try KeychainAccess.write(username: "api-key",
                             password: apiKey,
                             forService: .aiSubtitleAliyun)
  }

  func saveAliyunMachineTranslation(accessKeyID: String,
                                    accessKeySecret: String) throws {
    try KeychainAccess.write(username: accessKeyID,
                             password: accessKeySecret,
                             forService: .aiSubtitleAliyunMachineTranslation)
  }

  func removeCredentials(for providerID: AISubtitleProviderID) throws {
    switch providerID {
    case .openAI:
      try KeychainAccess.delete(forService: .aiSubtitleOpenAI)
    case .aliyun:
      try KeychainAccess.delete(forService: .aiSubtitleAliyun)
      try KeychainAccess.delete(forService: .aiSubtitleAliyunMachineTranslation)
    case .apple, .whisperCpp:
      return
    }
  }
}

protocol AISubtitleHTTPTask: AnyObject {
  func cancel()
}

extension URLSessionTask: AISubtitleHTTPTask {}

final class AISubtitleHTTPTaskBag {
  private final class Entry {
    var task: AISubtitleHTTPTask?
  }

  private let lock = NSLock()
  private var entries: [UUID: Entry] = [:]
  private var canceled = false

  private func reserve() -> UUID {
    let identifier = UUID()
    lock.lock()
    if !canceled {
      entries[identifier] = Entry()
    }
    lock.unlock()
    return identifier
  }

  private func attach(_ task: AISubtitleHTTPTask?, to identifier: UUID) {
    guard let task = task else { return }
    lock.lock()
    guard !canceled else {
      lock.unlock()
      task.cancel()
      return
    }
    guard let entry = entries[identifier] else {
      lock.unlock()
      return
    }
    entry.task = task
    lock.unlock()
  }

  private func remove(_ identifier: UUID) {
    lock.lock()
    entries.removeValue(forKey: identifier)
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    canceled = true
    let pending = entries.values.compactMap(\.task)
    entries.removeAll()
    lock.unlock()
    pending.forEach { $0.cancel() }
  }
}

protocol AISubtitleHTTPTransport {
  @discardableResult
  func send(_ request: URLRequest,
            completion: @escaping (Result<(HTTPURLResponse, Data), AISubtitleError>) -> Void) -> AISubtitleHTTPTask?
}

extension AISubtitleHTTPTaskBag {
  func send(using transport: AISubtitleHTTPTransport,
            request: URLRequest,
            completion: @escaping (Result<(HTTPURLResponse, Data), AISubtitleError>) -> Void) {
    let identifier = reserve()
    let task = transport.send(request) { [weak self] result in
      self?.remove(identifier)
      completion(result)
    }
    attach(task, to: identifier)
  }
}

final class URLSessionAISubtitleHTTPTransport: AISubtitleHTTPTransport {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  @discardableResult
  func send(_ request: URLRequest,
            completion: @escaping (Result<(HTTPURLResponse, Data), AISubtitleError>) -> Void) -> AISubtitleHTTPTask? {
    let task = session.dataTask(with: request) { data, response, error in
      if let error = error as NSError? {
        completion(.failure(AISubtitleError(code: error.code == NSURLErrorCancelled
                                              ? "cloud_request_canceled"
                                              : "cloud_network_failed",
                                            message: error.localizedDescription)))
        return
      }
      guard let response = response as? HTTPURLResponse else {
        completion(.failure(AISubtitleError(code: "cloud_response_invalid",
                                            message: "The cloud service returned no HTTP response.")))
        return
      }
      completion(.success((response, data ?? Data())))
    }
    task.resume()
    return task
  }
}

struct AISubtitleCostEstimate: Codable, Hashable {
  var providerID: AISubtitleProviderID
  var currencyCode: String
  var amount: Decimal
  var isApproximate: Bool
  var explanation: String
}

struct AISubtitleOpenAIPricing {
  var transcriptionUSDPerMinute: Decimal = Decimal(string: "0.006")!
  var translationInputUSDPerMillionTokens: Decimal = 1
  var translationOutputUSDPerMillionTokens: Decimal = 6
  var assumedCharactersPerToken: Decimal = 3

  func transcriptionEstimate(duration: Double) -> AISubtitleCostEstimate {
    let minutes = Decimal(max(0, duration) / 60)
    return AISubtitleCostEstimate(providerID: .openAI,
                                  currencyCode: "USD",
                                  amount: minutes * transcriptionUSDPerMinute,
                                  isApproximate: true,
                                  explanation: "Estimated from audio duration at the configured per-minute rate.")
  }

  func translationEstimate(sourceCharacters: Int,
                           estimatedOutputCharacters: Int? = nil) -> AISubtitleCostEstimate {
    let outputCharacters = estimatedOutputCharacters ?? sourceCharacters
    let divisor = max(Decimal(1), assumedCharactersPerToken) * Decimal(1_000_000)
    let inputTokensInMillions = Decimal(max(0, sourceCharacters)) / divisor
    let outputTokensInMillions = Decimal(max(0, outputCharacters)) / divisor
    return AISubtitleCostEstimate(providerID: .openAI,
                                  currencyCode: "USD",
                                  amount: inputTokensInMillions * translationInputUSDPerMillionTokens
                                    + outputTokensInMillions * translationOutputUSDPerMillionTokens,
                                  isApproximate: true,
                                  explanation: "Token usage is approximated from character counts and may differ from billing.")
  }
}

private protocol OpenAISubtitleProviderSupport: AnyObject {
  var apiKeyProvider: AISubtitleAPIKeyProviding { get }
  var consentChecker: AISubtitleCloudConsentChecking { get }
  var transport: AISubtitleHTTPTransport { get }
}

private extension OpenAISubtitleProviderSupport {
  func capability(role: AISubtitleProviderRole,
                  modelIdentifier: String) -> AISubtitleProviderCapability {
    guard consentChecker.hasConsent(for: .openAI) else {
      return AISubtitleProviderCapability(providerID: .openAI,
                                          role: role,
                                          status: .needsAuthorization,
                                          reason: "Cloud processing requires explicit consent before media or text is uploaded.",
                                          supportsCloudProcessing: true,
                                          modelIdentifier: modelIdentifier)
    }
    guard apiKeyProvider.apiKey(for: .openAI) != nil else {
      return AISubtitleProviderCapability(providerID: .openAI,
                                          role: role,
                                          status: .needsConfiguration,
                                          reason: "Configure an OpenAI API key.",
                                          supportsCloudProcessing: true,
                                          modelIdentifier: modelIdentifier)
    }
    return AISubtitleProviderCapability(providerID: .openAI,
                                        role: role,
                                        status: .available,
                                        supportsCloudProcessing: true,
                                        modelIdentifier: modelIdentifier)
  }

  func authorizedAPIKey() -> Result<String, AISubtitleError> {
    guard consentChecker.hasConsent(for: .openAI) else {
      return .failure(AISubtitleError(code: "openai_cloud_consent_required",
                                      message: "Allow cloud processing before uploading audio or subtitle text."))
    }
    guard let apiKey = apiKeyProvider.apiKey(for: .openAI), !apiKey.isEmpty else {
      return .failure(AISubtitleError(code: "openai_api_key_required",
                                      message: "Configure an OpenAI API key."))
    }
    return .success(apiKey)
  }

  func serviceError(prefix: String,
                    response: HTTPURLResponse,
                    data: Data) -> AISubtitleError {
    let envelope = try? JSONDecoder().decode(AISubtitleOpenAIErrorEnvelope.self, from: data)
    let serviceCode = envelope?.error?.code.map { "_\($0)" } ?? ""
    let message = envelope?.error?.message
      ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    return AISubtitleError(code: "\(prefix)_http_\(response.statusCode)\(serviceCode)",
                           message: message,
                           recoverable: response.statusCode == 408
                             || response.statusCode == 409
                             || response.statusCode == 429
                             || response.statusCode >= 500)
  }
}

final class OpenAIAISubtitleTranscriber: AISubtitleTranscriber, OpenAISubtitleProviderSupport, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.openAI
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .openAI, role: .transcriber)!
  let apiKeyProvider: AISubtitleAPIKeyProviding
  let consentChecker: AISubtitleCloudConsentChecking
  let transport: AISubtitleHTTPTransport
  private let endpoint: URL
  private let taskBag = AISubtitleHTTPTaskBag()

  init(apiKeyProvider: AISubtitleAPIKeyProviding = AISubtitleKeychainAPIKeyProvider(),
       consentChecker: AISubtitleCloudConsentChecking = UserDefaultsAISubtitleCloudConsentStore(),
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport(),
       endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!) {
    self.apiKeyProvider = apiKeyProvider
    self.consentChecker = consentChecker
    self.transport = transport
    self.endpoint = endpoint
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    capability(role: .transcriber, modelIdentifier: modelIdentifier)
  }

  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    let apiKey: String
    switch authorizedAPIKey() {
    case .failure(let error):
      completion(.failure(error))
      return
    case .success(let key):
      apiKey = key
    }

    let audio: Data
    do {
      audio = try Data(contentsOf: chunk.url, options: .mappedIfSafe)
    } catch {
      completion(.failure(AISubtitleError(code: "openai_audio_read_failed",
                                          message: error.localizedDescription)))
      return
    }

    let boundary = "IINAAISubtitle-\(UUID().uuidString)"
    var requestURL = URLRequest(url: endpoint)
    requestURL.httpMethod = "POST"
    requestURL.timeoutInterval = 120
    requestURL.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    requestURL.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    requestURL.httpBody = multipartBody(boundary: boundary,
                                        audio: audio,
                                        filename: chunk.url.lastPathComponent,
                                        language: request.sourceLanguage)
    taskBag.send(using: transport, request: requestURL) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(prefix: "openai_transcription",
                                                response: response,
                                                data: data)))
          return
        }
        completion(self.decodeTranscription(data, chunk: chunk, request: request))
      }
    }
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  private func multipartBody(boundary: String,
                             audio: Data,
                             filename: String,
                             language: AISubtitleLanguage?) -> Data {
    var body = Data()
    func append(_ string: String) {
      body.append(string.data(using: .utf8)!)
    }
    func appendField(name: String, value: String) {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      append("\(value)\r\n")
    }
    appendField(name: "model", value: modelIdentifier)
    appendField(name: "response_format", value: "verbose_json")
    appendField(name: "timestamp_granularities[]", value: "segment")
    if let languageCode = language.flatMap(openAILanguageCode) {
      appendField(name: "language", value: languageCode)
    }
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(audio)
    append("\r\n--\(boundary)--\r\n")
    return body
  }

  private func openAILanguageCode(_ language: AISubtitleLanguage) -> String? {
    let normalized = language.code.replacingOccurrences(of: "_", with: "-").lowercased()
    guard let primary = normalized.split(separator: "-").first, primary.count == 2 else { return nil }
    return String(primary)
  }

  private func decodeTranscription(_ data: Data,
                                   chunk: AISubtitleAudioChunk,
                                   request: AISubtitleProviderRequest) -> Result<[AISubtitleSegment], AISubtitleError> {
    struct Response: Decodable {
      struct Segment: Decodable {
        var id: Int?
        var start: Double
        var end: Double
        var text: String
      }
      var segments: [Segment]
    }
    do {
      let response = try JSONDecoder().decode(Response.self, from: data)
      let segments = response.segments.compactMap { segment -> AISubtitleSegment? in
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite else { return nil }
        let start = chunk.timeRange.start + max(0, segment.start)
        let end = min(chunk.timeRange.end, chunk.timeRange.start + max(segment.start, segment.end))
        guard end > start else { return nil }
        return AISubtitleSegment(id: segment.id.map { "openai-\(Int(chunk.timeRange.start * 1000))-\($0)" }
                                  ?? UUID().uuidString,
                                 timeRange: AISubtitleTimeRange(start: start, end: end),
                                 text: text,
                                 language: request.sourceLanguage)
      }
      return .success(segments)
    } catch {
      return .failure(AISubtitleError(code: "openai_transcription_decode_failed",
                                      message: error.localizedDescription))
    }
  }
}

final class OpenAIAISubtitleTranslator: AISubtitleTranslator, OpenAISubtitleProviderSupport, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.openAI
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .openAI, role: .translator)!
  let apiKeyProvider: AISubtitleAPIKeyProviding
  let consentChecker: AISubtitleCloudConsentChecking
  let transport: AISubtitleHTTPTransport
  private let endpoint: URL
  private let taskBag = AISubtitleHTTPTaskBag()

  init(apiKeyProvider: AISubtitleAPIKeyProviding = AISubtitleKeychainAPIKeyProvider(),
       consentChecker: AISubtitleCloudConsentChecking = UserDefaultsAISubtitleCloudConsentStore(),
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport(),
       endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!) {
    self.apiKeyProvider = apiKeyProvider
    self.consentChecker = consentChecker
    self.transport = transport
    self.endpoint = endpoint
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    if !request.requiresTranslation {
      return AISubtitleProviderCapability(providerID: .openAI,
                                          role: .translator,
                                          status: .available,
                                          reason: "Source and target languages are the same.",
                                          supportsCloudProcessing: false,
                                          modelIdentifier: "identity")
    }
    return capability(role: .translator, modelIdentifier: modelIdentifier)
  }

  func translate(_ segments: [AISubtitleSegment],
                 request: AISubtitleProviderRequest,
                 completion: @escaping (Result<[AISubtitleCue], AISubtitleError>) -> Void) {
    guard !segments.isEmpty else {
      completion(.success([]))
      return
    }
    if !request.requiresTranslation {
      completion(.success(segments.map {
        AISubtitleCue(id: $0.id,
                      timeRange: $0.timeRange,
                      text: $0.text,
                      language: request.targetLanguage)
      }))
      return
    }
    guard Set(segments.map(\.id)).count == segments.count else {
      completion(.failure(AISubtitleError(code: "openai_translation_duplicate_input_id",
                                          message: "Subtitle cue identifiers must be unique.")))
      return
    }

    let apiKey: String
    switch authorizedAPIKey() {
    case .failure(let error):
      completion(.failure(error))
      return
    case .success(let key):
      apiKey = key
    }

    let body: Data
    do {
      body = try translationRequestBody(segments: segments, request: request)
    } catch {
      completion(.failure(AISubtitleError(code: "openai_translation_request_failed",
                                          message: error.localizedDescription)))
      return
    }
    var requestURL = URLRequest(url: endpoint)
    requestURL.httpMethod = "POST"
    requestURL.timeoutInterval = 120
    requestURL.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    requestURL.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requestURL.httpBody = body
    taskBag.send(using: transport, request: requestURL) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(prefix: "openai_translation",
                                                response: response,
                                                data: data)))
          return
        }
        completion(self.decodeTranslation(data,
                                          segments: segments,
                                          targetLanguage: request.targetLanguage))
      }
    }
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  private func translationRequestBody(segments: [AISubtitleSegment],
                                      request: AISubtitleProviderRequest) throws -> Data {
    let inputs: [[String: String]] = segments.map { ["id": $0.id, "text": $0.text] }
    let inputData = try JSONSerialization.data(withJSONObject: ["segments": inputs])
    let inputJSON = String(data: inputData, encoding: .utf8)!
    let source = request.sourceLanguage?.code ?? "auto-detected source language"
    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "translations": [
          "type": "array",
          "items": [
            "type": "object",
            "properties": [
              "id": ["type": "string"],
              "text": ["type": "string"]
            ],
            "required": ["id", "text"],
            "additionalProperties": false
          ]
        ]
      ],
      "required": ["translations"],
      "additionalProperties": false
    ]
    let object: [String: Any] = [
      "model": modelIdentifier,
      "store": false,
      "instructions": "Translate each subtitle from \(source) to \(request.targetLanguage.code). Preserve meaning, tone, names, numbers, and one output per input ID. Return only the schema output.",
      "input": inputJSON,
      "text": [
        "format": [
          "type": "json_schema",
          "name": "subtitle_translations",
          "strict": true,
          "schema": schema
        ]
      ]
    ]
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func decodeTranslation(_ data: Data,
                                 segments: [AISubtitleSegment],
                                 targetLanguage: AISubtitleLanguage) -> Result<[AISubtitleCue], AISubtitleError> {
    struct Response: Decodable {
      struct Output: Decodable {
        struct Content: Decodable {
          var type: String
          var text: String?
        }
        var type: String
        var content: [Content]?
      }
      var output: [Output]
    }
    struct TranslationPayload: Decodable {
      struct Translation: Decodable {
        var id: String
        var text: String
      }
      var translations: [Translation]
    }
    do {
      let response = try JSONDecoder().decode(Response.self, from: data)
      guard let outputText = response.output
        .filter({ $0.type == "message" })
        .compactMap({ $0.content })
        .flatMap({ $0 })
        .first(where: { $0.type == "output_text" })?.text,
        let payloadData = outputText.data(using: .utf8) else {
        throw AISubtitleError(code: "openai_translation_output_missing",
                              message: "OpenAI returned no translation output.")
      }
      let payload = try JSONDecoder().decode(TranslationPayload.self, from: payloadData)
      var byID: [String: String] = [:]
      for translation in payload.translations {
        guard byID[translation.id] == nil else {
          throw AISubtitleError(code: "openai_translation_duplicate_response_id",
                                message: "OpenAI returned duplicate cue identifier \(translation.id).")
        }
        byID[translation.id] = translation.text
      }
      let cues = try segments.map { segment -> AISubtitleCue in
        guard let text = byID[segment.id] else {
          throw AISubtitleError(code: "openai_translation_response_missing",
                                message: "OpenAI did not return cue \(segment.id).")
        }
        return AISubtitleCue(id: segment.id,
                            timeRange: segment.timeRange,
                            text: text,
                            originalText: segment.text,
                            language: targetLanguage)
      }
      guard byID.count == segments.count else {
        throw AISubtitleError(code: "openai_translation_unexpected_response_id",
                              message: "OpenAI returned an unexpected cue identifier.")
      }
      return .success(cues)
    } catch let error as AISubtitleError {
      return .failure(error)
    } catch {
      return .failure(AISubtitleError(code: "openai_translation_decode_failed",
                                      message: error.localizedDescription))
    }
  }
}

struct AISubtitleProviderPair {
  var transcriber: AISubtitleTranscriber
  var translator: AISubtitleTranslator
  var translatorIDForCache: AISubtitleProviderID?
}

final class AISubtitleCloudProviderFactory {
  private let openAIAPIKeyProvider: AISubtitleAPIKeyProviding
  private let aliyunCredentialProvider: AISubtitleAliyunCredentialProviding
  private let consentChecker: AISubtitleCloudConsentChecking
  private let aliyunAudioPublisher: AISubtitleAliyunAudioPublishing
  private let transport: AISubtitleHTTPTransport

  init(openAIAPIKeyProvider: AISubtitleAPIKeyProviding = AISubtitleKeychainAPIKeyProvider(),
       aliyunCredentialProvider: AISubtitleAliyunCredentialProviding = AISubtitleAliyunKeychainCredentialProvider(),
       consentChecker: AISubtitleCloudConsentChecking = UserDefaultsAISubtitleCloudConsentStore(),
       aliyunAudioPublisher: AISubtitleAliyunAudioPublishing? = nil,
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport()) {
    self.openAIAPIKeyProvider = openAIAPIKeyProvider
    self.aliyunCredentialProvider = aliyunCredentialProvider
    self.consentChecker = consentChecker
    self.transport = transport
    self.aliyunAudioPublisher = aliyunAudioPublisher
      ?? DashScopeTemporaryAISubtitleAliyunAudioPublisher(credentialProvider: aliyunCredentialProvider,
                                                          transport: transport)
  }

  func makePair(providerID: AISubtitleProviderID,
                request: AISubtitleProviderRequest) -> Result<AISubtitleProviderPair, AISubtitleError> {
    let transcriber: AISubtitleTranscriber
    let translator: AISubtitleTranslator
    switch providerID {
    case .openAI:
      transcriber = OpenAIAISubtitleTranscriber(apiKeyProvider: openAIAPIKeyProvider,
                                                consentChecker: consentChecker,
                                                transport: transport)
      translator = OpenAIAISubtitleTranslator(apiKeyProvider: openAIAPIKeyProvider,
                                              consentChecker: consentChecker,
                                              transport: transport)
    case .aliyun:
      transcriber = AliyunAISubtitleTranscriber(credentialProvider: aliyunCredentialProvider,
                                                consentChecker: consentChecker,
                                                publisher: aliyunAudioPublisher,
                                                transport: transport)
      translator = AliyunAISubtitleTranslator(credentialProvider: aliyunCredentialProvider,
                                              consentChecker: consentChecker,
                                              transport: transport)
    case .apple, .whisperCpp:
      return .failure(AISubtitleError(code: "ai_subtitle_cloud_provider_invalid",
                                      message: "\(providerID.displayName) is not a cloud provider.",
                                      recoverable: false))
    }

    let transcriberCapability = transcriber.capability(for: request)
    guard transcriberCapability.status == .available else {
      return .failure(AISubtitleError(code: "\(providerID.rawValue)_transcriber_\(transcriberCapability.status.rawValue)",
                                      message: transcriberCapability.reason ?? "The transcriber is not ready."))
    }
    let translationRequired = request.requiresTranslation
    if translationRequired {
      let translatorCapability = translator.capability(for: request)
      guard translatorCapability.status == .available else {
        return .failure(AISubtitleError(code: "\(providerID.rawValue)_translator_\(translatorCapability.status.rawValue)",
                                        message: translatorCapability.reason ?? "The translator is not ready."))
      }
    }
    return .success(AISubtitleProviderPair(
      transcriber: transcriber,
      translator: translationRequired
        ? translator
        : AISubtitlePassThroughTranslator(providerID: providerID),
      translatorIDForCache: translationRequired ? providerID : nil
    ))
  }

  func makeTranslator(providerID: AISubtitleProviderID,
                      request: AISubtitleProviderRequest) -> Result<AISubtitleTranslator, AISubtitleError> {
    let translator: AISubtitleTranslator
    switch providerID {
    case .openAI:
      translator = OpenAIAISubtitleTranslator(apiKeyProvider: openAIAPIKeyProvider,
                                              consentChecker: consentChecker,
                                              transport: transport)
    case .aliyun:
      translator = AliyunAISubtitleTranslator(credentialProvider: aliyunCredentialProvider,
                                              consentChecker: consentChecker,
                                              transport: transport)
    case .apple, .whisperCpp:
      return .failure(AISubtitleError(code: "ai_subtitle_cloud_translator_invalid",
                                      message: "\(providerID.displayName) is not a cloud translation provider.",
                                      recoverable: false))
    }
    let capability = translator.capability(for: request)
    guard capability.status == .available else {
      return .failure(AISubtitleError(code: "\(providerID.rawValue)_translator_\(capability.status.rawValue)",
                                      message: capability.reason ?? "The translator is not ready."))
    }
    return .success(translator)
  }
}
