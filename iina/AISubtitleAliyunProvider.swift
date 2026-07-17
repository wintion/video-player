//
//  AISubtitleAliyunProvider.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import CryptoKit
import Foundation

struct AISubtitleAliyunCredentials {
  var dashScopeAPIKey: String?
  var machineTranslationAccessKeyID: String?
  var machineTranslationAccessKeySecret: String?
}

protocol AISubtitleAliyunCredentialProviding {
  func credentials() -> AISubtitleAliyunCredentials
}

struct AISubtitleAliyunKeychainCredentialProvider: AISubtitleAliyunCredentialProviding {
  func credentials() -> AISubtitleAliyunCredentials {
    let dashScope = try? KeychainAccess.read(username: nil, forService: .aiSubtitleAliyun)
    let machineTranslation = try? KeychainAccess.read(username: nil,
                                                      forService: .aiSubtitleAliyunMachineTranslation)
    return AISubtitleAliyunCredentials(
      dashScopeAPIKey: dashScope?.password,
      machineTranslationAccessKeyID: machineTranslation?.username,
      machineTranslationAccessKeySecret: machineTranslation?.password
    )
  }
}

protocol AISubtitleAliyunAudioPublishing {
  var isConfigured: Bool { get }
  func publish(_ chunk: AISubtitleAudioChunk,
               completion: @escaping (Result<URL, AISubtitleError>) -> Void)
  func revoke(_ publishedURL: URL)
}

struct UnavailableAISubtitleAliyunAudioPublisher: AISubtitleAliyunAudioPublishing {
  let isConfigured = false

  func publish(_ chunk: AISubtitleAudioChunk,
               completion: @escaping (Result<URL, AISubtitleError>) -> Void) {
    completion(.failure(AISubtitleError(code: "aliyun_audio_publisher_required",
                                        message: "Configure temporary audio publishing before using Paraformer file transcription.")))
  }

  func revoke(_ publishedURL: URL) {}
}

final class DashScopeTemporaryAISubtitleAliyunAudioPublisher: AISubtitleAliyunAudioPublishing, AISubtitleCancelableProvider {
  private struct CredentialResponse: Decodable {
    struct Credential: Decodable {
      var policy: String
      var signature: String
      var upload_dir: String
      var upload_host: String
      var oss_access_key_id: String
      var x_oss_object_acl: String
      var x_oss_forbid_overwrite: String
    }
    var data: Credential
  }

  private let credentialProvider: AISubtitleAliyunCredentialProviding
  private let transport: AISubtitleHTTPTransport
  private let credentialEndpoint: URL
  private let modelIdentifier: String
  private let taskBag = AISubtitleHTTPTaskBag()

  init(credentialProvider: AISubtitleAliyunCredentialProviding = AISubtitleAliyunKeychainCredentialProvider(),
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport(),
       credentialEndpoint: URL = URL(string: "https://dashscope.aliyuncs.com/api/v1/uploads")!,
       modelIdentifier: String = "paraformer-v2") {
    self.credentialProvider = credentialProvider
    self.transport = transport
    self.credentialEndpoint = credentialEndpoint
    self.modelIdentifier = modelIdentifier
  }

  var isConfigured: Bool {
    credentialProvider.credentials().dashScopeAPIKey?.isEmpty == false
  }

  func publish(_ chunk: AISubtitleAudioChunk,
               completion: @escaping (Result<URL, AISubtitleError>) -> Void) {
    guard let apiKey = credentialProvider.credentials().dashScopeAPIKey, !apiKey.isEmpty else {
      completion(.failure(AISubtitleError(code: "aliyun_dashscope_api_key_required",
                                          message: "Configure an Alibaba Cloud Model Studio API key.")))
      return
    }
    guard let components = URLComponents(url: credentialEndpoint, resolvingAgainstBaseURL: false) else {
      completion(.failure(AISubtitleError(code: "aliyun_upload_credential_url_invalid",
                                          message: "The DashScope upload credential URL is invalid.")))
      return
    }
    var requestComponents = components
    requestComponents.queryItems = [
      URLQueryItem(name: "action", value: "getPolicy"),
      URLQueryItem(name: "model", value: modelIdentifier)
    ]
    guard let requestURL = requestComponents.url else {
      completion(.failure(AISubtitleError(code: "aliyun_upload_credential_url_invalid",
                                          message: "The DashScope upload credential URL is invalid.")))
      return
    }
    var request = URLRequest(url: requestURL)
    request.timeoutInterval = 60
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    taskBag.send(using: transport, request: request) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(AISubtitleError(code: "aliyun_upload_credential_http_\(response.statusCode)",
                                              message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))))
          return
        }
        do {
          let credential = try JSONDecoder().decode(CredentialResponse.self, from: data).data
          try self.upload(chunk, credential: credential, completion: completion)
        } catch let error as AISubtitleError {
          completion(.failure(error))
        } catch {
          completion(.failure(AISubtitleError(code: "aliyun_upload_credential_decode_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }

  func revoke(_ publishedURL: URL) {
    // DashScope temporary objects cannot be managed after upload and expire automatically after 48 hours.
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  private func upload(_ chunk: AISubtitleAudioChunk,
                      credential: CredentialResponse.Credential,
                      completion: @escaping (Result<URL, AISubtitleError>) -> Void) throws {
    guard let uploadURL = URL(string: credential.upload_host),
          let audioData = try? Data(contentsOf: chunk.url, options: .mappedIfSafe) else {
      throw AISubtitleError(code: "aliyun_audio_read_failed",
                            message: "The extracted audio chunk could not be read for upload.")
    }
    let boundary = "IINAAISubtitle-\(UUID().uuidString)"
    let filename = "chunk-\(UUID().uuidString).wav"
    let objectKey = credential.upload_dir + "/" + filename
    let fields = [
      ("OSSAccessKeyId", credential.oss_access_key_id),
      ("policy", credential.policy),
      ("Signature", credential.signature),
      ("key", objectKey),
      ("x-oss-object-acl", credential.x_oss_object_acl),
      ("x-oss-forbid-overwrite", credential.x_oss_forbid_overwrite),
      ("success_action_status", "200")
    ]
    var body = Data()
    for (name, value) in fields {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    body.append(audioData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    taskBag.send(using: transport, request: request) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode),
              let publishedURL = URL(string: "oss://\(objectKey)") else {
          let message = String(data: data, encoding: .utf8)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
          completion(.failure(AISubtitleError(code: "aliyun_temporary_upload_http_\(response.statusCode)",
                                              message: message)))
          return
        }
        completion(.success(publishedURL))
      }
    }
  }
}

struct AISubtitleAliyunPricing {
  var transcriptionCNYPerSecond: Decimal = Decimal(string: "0.00008")!
  var translationCNYPerMillionCharacters: Decimal = 50

  func transcriptionEstimate(duration: Double) -> AISubtitleCostEstimate {
    AISubtitleCostEstimate(providerID: .aliyun,
                           currencyCode: "CNY",
                           amount: Decimal(max(0, duration)) * transcriptionCNYPerSecond,
                           isApproximate: true,
                           explanation: "Estimated from audio duration; Paraformer bills recognized speech duration.")
  }

  func translationEstimate(characterCount: Int) -> AISubtitleCostEstimate {
    AISubtitleCostEstimate(providerID: .aliyun,
                           currencyCode: "CNY",
                           amount: Decimal(max(0, characterCount))
                             * translationCNYPerMillionCharacters / Decimal(1_000_000),
                           isApproximate: true,
                           explanation: "Estimated before free quota or prepaid resource-plan deductions.")
  }
}

private struct AliyunServiceErrorEnvelope: Decodable {
  var code: String?
  var message: String?
  var Code: String?
  var Message: String?
}

private struct AliyunParaformerSubmitResponse: Decodable {
  struct Output: Decodable {
    var task_id: String
  }
  var output: Output
}

private struct AliyunParaformerTaskResponse: Decodable {
  struct Output: Decodable {
    struct TaskResult: Decodable {
      var transcription_url: String?
      var subtask_status: String
      var code: String?
      var message: String?
    }
    var task_status: String
    var results: [TaskResult]?
  }
  var output: Output
}

private struct AliyunParaformerTranscription: Decodable {
  struct Transcript: Decodable {
    struct Sentence: Decodable {
      var begin_time: Int
      var end_time: Int
      var text: String
      var sentence_id: Int?
    }
    var sentences: [Sentence]?
  }
  var transcripts: [Transcript]
}

final class AliyunAISubtitleTranscriber: AISubtitleTranscriber, AISubtitleCancelableProvider {
  typealias DelayHandler = (TimeInterval, @escaping () -> Void) -> Void

  let providerID = AISubtitleProviderID.aliyun
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .aliyun, role: .transcriber)!
  private let credentialProvider: AISubtitleAliyunCredentialProviding
  private let consentChecker: AISubtitleCloudConsentChecking
  private let publisher: AISubtitleAliyunAudioPublishing
  private let transport: AISubtitleHTTPTransport
  private let submitEndpoint: URL
  private let taskBaseURL: URL
  private let pollInterval: TimeInterval
  private let maximumPollAttempts: Int
  private let delay: DelayHandler
  private let taskBag = AISubtitleHTTPTaskBag()
  private let cancellationLock = NSLock()
  private var canceled = false

  init(credentialProvider: AISubtitleAliyunCredentialProviding = AISubtitleAliyunKeychainCredentialProvider(),
       consentChecker: AISubtitleCloudConsentChecking = UserDefaultsAISubtitleCloudConsentStore(),
       publisher: AISubtitleAliyunAudioPublishing = UnavailableAISubtitleAliyunAudioPublisher(),
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport(),
       submitEndpoint: URL = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription")!,
       taskBaseURL: URL = URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks/")!,
       pollInterval: TimeInterval = 0.5,
       maximumPollAttempts: Int = 240,
       delay: @escaping DelayHandler = { interval, work in
         DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: work)
       }) {
    self.credentialProvider = credentialProvider
    self.consentChecker = consentChecker
    self.publisher = publisher
    self.transport = transport
    self.submitEndpoint = submitEndpoint
    self.taskBaseURL = taskBaseURL
    self.pollInterval = max(0, pollInterval)
    self.maximumPollAttempts = max(1, maximumPollAttempts)
    self.delay = delay
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    let status: AISubtitleProviderStatus
    let reason: String?
    if !consentChecker.hasConsent(for: .aliyun) {
      status = .needsAuthorization
      reason = "Cloud processing requires explicit consent before audio is uploaded."
    } else if credentialProvider.credentials().dashScopeAPIKey?.isEmpty != false {
      status = .needsConfiguration
      reason = "Configure an Alibaba Cloud Model Studio API key."
    } else if !publisher.isConfigured {
      status = .needsConfiguration
      reason = "Configure temporary HTTPS or OSS audio publishing for Paraformer file transcription."
    } else {
      status = .available
      reason = nil
    }
    return AISubtitleProviderCapability(providerID: providerID,
                                        role: .transcriber,
                                        status: status,
                                        reason: reason,
                                        supportsCloudProcessing: true,
                                        modelIdentifier: modelIdentifier)
  }

  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    guard consentChecker.hasConsent(for: .aliyun) else {
      completion(.failure(AISubtitleError(code: "aliyun_cloud_consent_required",
                                          message: "Allow cloud processing before uploading audio.")))
      return
    }
    guard let apiKey = credentialProvider.credentials().dashScopeAPIKey, !apiKey.isEmpty else {
      completion(.failure(AISubtitleError(code: "aliyun_dashscope_api_key_required",
                                          message: "Configure an Alibaba Cloud Model Studio API key.")))
      return
    }
    guard publisher.isConfigured else {
      completion(.failure(AISubtitleError(code: "aliyun_audio_publisher_required",
                                          message: "Configure temporary audio publishing before using Paraformer.")))
      return
    }

    guard !isCanceled else {
      completion(.failure(AISubtitleError(code: "aliyun_transcription_canceled",
                                          message: "Alibaba Cloud transcription was canceled.")))
      return
    }
    publisher.publish(chunk) { result in
      guard !self.isCanceled else {
        completion(.failure(AISubtitleError(code: "aliyun_transcription_canceled",
                                            message: "Alibaba Cloud transcription was canceled.")))
        return
      }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let publishedURL):
        guard ["http", "https", "oss"].contains(publishedURL.scheme?.lowercased() ?? "") else {
          self.publisher.revoke(publishedURL)
          completion(.failure(AISubtitleError(code: "aliyun_published_audio_url_invalid",
                                              message: "Paraformer requires an HTTP, HTTPS, or OSS audio URL.")))
          return
        }
        self.submit(publishedURL: publishedURL,
                    apiKey: apiKey,
                    chunk: chunk,
                    request: request) { result in
          self.publisher.revoke(publishedURL)
          completion(result)
        }
      }
    }
  }

  private func submit(publishedURL: URL,
                      apiKey: String,
                      chunk: AISubtitleAudioChunk,
                      request: AISubtitleProviderRequest,
                      completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    var parameters: [String: Any] = [
      "channel_id": [0],
      "timestamp_alignment_enabled": true
    ]
    if let language = request.sourceLanguage.flatMap(paraformerLanguageCode) {
      parameters["language_hints"] = [language]
    }
    let object: [String: Any] = [
      "model": modelIdentifier,
      "input": ["file_urls": [publishedURL.absoluteString]],
      "parameters": parameters
    ]
    let body: Data
    do {
      body = try JSONSerialization.data(withJSONObject: object)
    } catch {
      completion(.failure(AISubtitleError(code: "aliyun_transcription_request_failed",
                                          message: error.localizedDescription)))
      return
    }
    var requestURL = authorizedRequest(url: submitEndpoint, apiKey: apiKey)
    requestURL.httpMethod = "POST"
    requestURL.httpBody = body
    requestURL.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requestURL.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
    if publishedURL.scheme?.lowercased() == "oss" {
      requestURL.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
    }
    taskBag.send(using: transport, request: requestURL) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(prefix: "aliyun_transcription_submit",
                                                response: response,
                                                data: data)))
          return
        }
        do {
          let taskID = try JSONDecoder().decode(AliyunParaformerSubmitResponse.self, from: data).output.task_id
          self.poll(taskID: taskID,
                    apiKey: apiKey,
                    chunk: chunk,
                    request: request,
                    attempt: 0,
                    completion: completion)
        } catch {
          completion(.failure(AISubtitleError(code: "aliyun_transcription_submit_decode_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }

  private func poll(taskID: String,
                    apiKey: String,
                    chunk: AISubtitleAudioChunk,
                    request: AISubtitleProviderRequest,
                    attempt: Int,
                    completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    guard !isCanceled else {
      completion(.failure(AISubtitleError(code: "aliyun_transcription_canceled",
                                          message: "Alibaba Cloud transcription was canceled.")))
      return
    }
    guard attempt < maximumPollAttempts else {
      completion(.failure(AISubtitleError(code: "aliyun_transcription_poll_timeout",
                                          message: "Paraformer did not finish before the polling timeout.")))
      return
    }
    let taskURL = taskBaseURL.appendingPathComponent(taskID, isDirectory: false)
    taskBag.send(using: transport,
                 request: authorizedRequest(url: taskURL, apiKey: apiKey)) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(prefix: "aliyun_transcription_poll",
                                                response: response,
                                                data: data)))
          return
        }
        let task: AliyunParaformerTaskResponse
        do {
          task = try JSONDecoder().decode(AliyunParaformerTaskResponse.self, from: data)
        } catch {
          completion(.failure(AISubtitleError(code: "aliyun_transcription_poll_decode_failed",
                                              message: error.localizedDescription)))
          return
        }
        switch task.output.task_status.uppercased() {
        case "PENDING", "RUNNING":
          self.delay(self.pollInterval) {
            self.poll(taskID: taskID,
                      apiKey: apiKey,
                      chunk: chunk,
                      request: request,
                      attempt: attempt + 1,
                      completion: completion)
          }
        case "SUCCEEDED":
          guard let result = task.output.results?.first(where: {
            $0.subtask_status.uppercased() == "SUCCEEDED" && $0.transcription_url != nil
          }), let resultURLString = result.transcription_url,
            let resultURL = URL(string: resultURLString) else {
            let failed = task.output.results?.first(where: { $0.subtask_status.uppercased() == "FAILED" })
            completion(.failure(AISubtitleError(code: "aliyun_transcription_subtask_failed",
                                                message: failed?.message ?? "Paraformer returned no successful transcription result.")))
            return
          }
          self.fetchResult(resultURL, chunk: chunk, request: request, completion: completion)
        default:
          completion(.failure(AISubtitleError(code: "aliyun_transcription_task_failed",
                                              message: "Paraformer task ended with status \(task.output.task_status).")))
        }
      }
    }
  }

  private func fetchResult(_ resultURL: URL,
                           chunk: AISubtitleAudioChunk,
                           request: AISubtitleProviderRequest,
                           completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    taskBag.send(using: transport, request: URLRequest(url: resultURL)) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(prefix: "aliyun_transcription_result",
                                                response: response,
                                                data: data)))
          return
        }
        do {
          let result = try JSONDecoder().decode(AliyunParaformerTranscription.self, from: data)
          let sentences = result.transcripts.flatMap { $0.sentences ?? [] }
          let segments = sentences.compactMap { sentence -> AISubtitleSegment? in
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, sentence.end_time > sentence.begin_time else { return nil }
            let start = chunk.timeRange.start + Double(max(0, sentence.begin_time)) / 1000
            let end = min(chunk.timeRange.end,
                          chunk.timeRange.start + Double(max(sentence.begin_time, sentence.end_time)) / 1000)
            guard end > start else { return nil }
            return AISubtitleSegment(id: sentence.sentence_id.map {
              "aliyun-\(Int(chunk.timeRange.start * 1000))-\($0)"
            } ?? UUID().uuidString,
                                     timeRange: AISubtitleTimeRange(start: start, end: end),
                                     text: text,
                                     language: request.sourceLanguage)
          }
          completion(.success(segments.sorted { $0.timeRange.start < $1.timeRange.start }))
        } catch {
          completion(.failure(AISubtitleError(code: "aliyun_transcription_result_decode_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }

  func cancelAll() {
    cancellationLock.lock()
    canceled = true
    cancellationLock.unlock()
    taskBag.cancelAll()
    (publisher as? AISubtitleCancelableProvider)?.cancelAll()
  }

  private var isCanceled: Bool {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return canceled
  }

  private func authorizedRequest(url: URL, apiKey: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = 120
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func paraformerLanguageCode(_ language: AISubtitleLanguage) -> String? {
    let code = AISubtitleAliyunLanguage.code(for: language)
    return ["zh", "en", "ja", "yue", "ko", "de", "fr", "ru"].contains(code) ? code : nil
  }

  private func serviceError(prefix: String,
                            response: HTTPURLResponse,
                            data: Data) -> AISubtitleError {
    let envelope = try? JSONDecoder().decode(AliyunServiceErrorEnvelope.self, from: data)
    let code = envelope?.code ?? envelope?.Code
    return AISubtitleError(code: "\(prefix)_http_\(response.statusCode)\(code.map { "_\($0)" } ?? "")",
                           message: envelope?.message ?? envelope?.Message
                             ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                           recoverable: response.statusCode == 408
                             || response.statusCode == 429
                             || response.statusCode >= 500)
  }
}

private enum AISubtitleAliyunLanguage {
  static func code(for language: AISubtitleLanguage) -> String {
    let normalized = language.code.replacingOccurrences(of: "_", with: "-").lowercased()
    if normalized == "zh-hant" || normalized.hasPrefix("zh-tw") { return "zh-tw" }
    if normalized == "zh-hans" || normalized.hasPrefix("zh-cn") { return "zh" }
    return normalized.split(separator: "-").first.map(String.init) ?? normalized
  }
}

struct AISubtitleAliyunMachineTranslationCredentials {
  var accessKeyID: String
  var accessKeySecret: String
}

struct AISubtitleAliyunROASigner {
  var date: Date
  var nonce: String

  init(date: Date = Date(), nonce: String = UUID().uuidString) {
    self.date = date
    self.nonce = nonce
  }

  func signedRequest(endpoint: URL,
                     body: Data,
                     credentials: AISubtitleAliyunMachineTranslationCredentials) -> URLRequest {
    let accept = "application/json"
    let contentType = "application/json;charset=utf-8"
    let contentMD5 = md5(body).base64EncodedString()
    let dateString = httpDate(date)
    let path = endpoint.path.isEmpty ? "/" : endpoint.path
    let stringToSign = [
      "POST",
      accept,
      contentMD5,
      contentType,
      dateString,
      "x-acs-signature-method:HMAC-SHA1",
      "x-acs-signature-nonce:\(nonce)",
      "x-acs-version:2019-01-02"
    ].joined(separator: "\n") + "\n" + path
    let signature = hmacSHA1(Data(stringToSign.utf8), key: Data(credentials.accessKeySecret.utf8))
      .base64EncodedString()

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.httpBody = body
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(contentMD5, forHTTPHeaderField: "Content-MD5")
    request.setValue(dateString, forHTTPHeaderField: "Date")
    request.setValue(endpoint.host, forHTTPHeaderField: "Host")
    request.setValue("HMAC-SHA1", forHTTPHeaderField: "x-acs-signature-method")
    request.setValue(nonce, forHTTPHeaderField: "x-acs-signature-nonce")
    request.setValue("2019-01-02", forHTTPHeaderField: "x-acs-version")
    request.setValue("acs \(credentials.accessKeyID):\(signature)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func md5(_ data: Data) -> Data {
    Data(Insecure.MD5.hash(data: data))
  }

  private func hmacSHA1(_ data: Data, key: Data) -> Data {
    let authenticationCode = HMAC<Insecure.SHA1>
      .authenticationCode(for: data, using: SymmetricKey(data: key))
    return Data(authenticationCode)
  }

  private func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }
}

final class AliyunAISubtitleTranslator: AISubtitleTranslator, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.aliyun
  let modelIdentifier = AISubtitleProviderModelCatalog.identifier(for: .aliyun, role: .translator)!
  private let credentialProvider: AISubtitleAliyunCredentialProviding
  private let consentChecker: AISubtitleCloudConsentChecking
  private let transport: AISubtitleHTTPTransport
  private let endpoint: URL
  private let signerFactory: () -> AISubtitleAliyunROASigner
  private let taskBag = AISubtitleHTTPTaskBag()

  init(credentialProvider: AISubtitleAliyunCredentialProviding = AISubtitleAliyunKeychainCredentialProvider(),
       consentChecker: AISubtitleCloudConsentChecking = UserDefaultsAISubtitleCloudConsentStore(),
       transport: AISubtitleHTTPTransport = URLSessionAISubtitleHTTPTransport(),
       endpoint: URL = URL(string: "https://mt.cn-hangzhou.aliyuncs.com/api/translate/web/general")!,
       signerFactory: @escaping () -> AISubtitleAliyunROASigner = { AISubtitleAliyunROASigner() }) {
    self.credentialProvider = credentialProvider
    self.consentChecker = consentChecker
    self.transport = transport
    self.endpoint = endpoint
    self.signerFactory = signerFactory
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    if !request.requiresTranslation {
      return AISubtitleProviderCapability(providerID: providerID,
                                          role: .translator,
                                          status: .available,
                                          reason: "Source and target languages are the same.",
                                          supportsCloudProcessing: false,
                                          modelIdentifier: "identity")
    }
    let credentials = credentialProvider.credentials()
    let status: AISubtitleProviderStatus
    let reason: String?
    if !consentChecker.hasConsent(for: .aliyun) {
      status = .needsAuthorization
      reason = "Cloud processing requires explicit consent before subtitle text is uploaded."
    } else if credentials.machineTranslationAccessKeyID?.isEmpty != false
                || credentials.machineTranslationAccessKeySecret?.isEmpty != false {
      status = .needsConfiguration
      reason = "Configure Alibaba Cloud Machine Translation AccessKey credentials."
    } else {
      status = .available
      reason = nil
    }
    return AISubtitleProviderCapability(providerID: providerID,
                                        role: .translator,
                                        status: status,
                                        reason: reason,
                                        supportsCloudProcessing: true,
                                        modelIdentifier: modelIdentifier)
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
    guard consentChecker.hasConsent(for: .aliyun) else {
      completion(.failure(AISubtitleError(code: "aliyun_cloud_consent_required",
                                          message: "Allow cloud processing before uploading subtitle text.")))
      return
    }
    let configured = credentialProvider.credentials()
    guard let accessKeyID = configured.machineTranslationAccessKeyID,
          let accessKeySecret = configured.machineTranslationAccessKeySecret,
          !accessKeyID.isEmpty, !accessKeySecret.isEmpty else {
      completion(.failure(AISubtitleError(code: "aliyun_machine_translation_credentials_required",
                                          message: "Configure Alibaba Cloud Machine Translation AccessKey credentials.")))
      return
    }
    guard segments.allSatisfy({ $0.text.count < 5000 }) else {
      completion(.failure(AISubtitleError(code: "aliyun_translation_text_too_long",
                                          message: "An Alibaba Cloud translation request must contain fewer than 5,000 characters.")))
      return
    }
    let credentials = AISubtitleAliyunMachineTranslationCredentials(accessKeyID: accessKeyID,
                                                                     accessKeySecret: accessKeySecret)
    translateNext(index: 0,
                  segments: segments,
                  request: request,
                  credentials: credentials,
                  cues: [],
                  completion: completion)
  }

  private func translateNext(index: Int,
                             segments: [AISubtitleSegment],
                             request: AISubtitleProviderRequest,
                             credentials: AISubtitleAliyunMachineTranslationCredentials,
                             cues: [AISubtitleCue],
                             completion: @escaping (Result<[AISubtitleCue], AISubtitleError>) -> Void) {
    guard index < segments.count else {
      completion(.success(cues))
      return
    }
    let segment = segments[index]
    let object: [String: Any] = [
      "FormatType": "text",
      "SourceLanguage": request.sourceLanguage.map(AISubtitleAliyunLanguage.code) ?? "auto",
      "TargetLanguage": AISubtitleAliyunLanguage.code(for: request.targetLanguage),
      "SourceText": segment.text,
      "Scene": "general"
    ]
    let body: Data
    do {
      body = try JSONSerialization.data(withJSONObject: object)
    } catch {
      completion(.failure(AISubtitleError(code: "aliyun_translation_request_failed",
                                          message: error.localizedDescription)))
      return
    }
    let signedRequest = signerFactory().signedRequest(endpoint: endpoint,
                                                      body: body,
                                                      credentials: credentials)
    taskBag.send(using: transport, request: signedRequest) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let (response, data)):
        guard (200..<300).contains(response.statusCode) else {
          completion(.failure(self.serviceError(response: response, data: data)))
          return
        }
        do {
          let translated = try self.translatedText(from: data)
          var nextCues = cues
          nextCues.append(AISubtitleCue(id: segment.id,
                                        timeRange: segment.timeRange,
                                        text: translated,
                                        originalText: segment.text,
                                        language: request.targetLanguage))
          self.translateNext(index: index + 1,
                             segments: segments,
                             request: request,
                             credentials: credentials,
                             cues: nextCues,
                             completion: completion)
        } catch let error as AISubtitleError {
          completion(.failure(error))
        } catch {
          completion(.failure(AISubtitleError(code: "aliyun_translation_decode_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }

  func cancelAll() {
    taskBag.cancelAll()
  }

  private func translatedText(from data: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AISubtitleError(code: "aliyun_translation_decode_failed",
                            message: "Alibaba Cloud returned an invalid translation response.")
    }
    let envelope = (object["TranslateGeneralResponse"] as? [String: Any]) ?? object
    let code = (envelope["Code"] as? NSNumber)?.intValue
      ?? Int(envelope["Code"] as? String ?? "")
    if let code = code, code != 200 {
      throw AISubtitleError(code: "aliyun_translation_service_\(code)",
                            message: envelope["Message"] as? String ?? "Alibaba Cloud translation failed.")
    }
    guard let translated = (envelope["Data"] as? [String: Any])?["Translated"] as? String else {
      throw AISubtitleError(code: "aliyun_translation_output_missing",
                            message: "Alibaba Cloud returned no translated text.")
    }
    return translated
  }

  private func serviceError(response: HTTPURLResponse, data: Data) -> AISubtitleError {
    let envelope = try? JSONDecoder().decode(AliyunServiceErrorEnvelope.self, from: data)
    let code = envelope?.Code ?? envelope?.code
    return AISubtitleError(code: "aliyun_translation_http_\(response.statusCode)\(code.map { "_\($0)" } ?? "")",
                           message: envelope?.Message ?? envelope?.message
                             ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                           recoverable: response.statusCode == 408
                             || response.statusCode == 429
                             || response.statusCode >= 500)
  }
}
