import Foundation

enum Utility {
  static let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  static let binariesURL = cacheURL
  static let exeDirURL = cacheURL
  static let appSupportDirUrl = cacheURL
}

final class KeychainAccess {
  struct ServiceName: RawRepresentable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
  }

  static func read(username: String?, forService: ServiceName) throws -> (username: String, password: String) {
    throw NSError(domain: "ai-subtitle-self-test", code: 1)
  }

  static func write(username: String, password: String, forService: ServiceName) throws {}
  static func delete(username: String? = nil, forService: ServiceName) throws {}
}

final class FFmpegController {
  static func extractAudio(from sourceURL: URL,
                           streamIndex: Int,
                           startTime: TimeInterval,
                           duration: TimeInterval,
                           outputURL: URL) throws {}

  static func extractAudio(from sourceURL: URL,
                           streamIndex: Int,
                           startTime: TimeInterval,
                           duration: TimeInterval,
                           outputURL: URL,
                           shouldCancel: () -> Bool) throws {
    if shouldCancel() {
      throw AISubtitleError(code: "audio_extraction_canceled",
                            message: "Audio extraction was canceled.")
    }
  }
}

struct TestCredentials: AISubtitleCredentialChecking {
  var providers: Set<AISubtitleProviderID>
  func hasCredential(for providerID: AISubtitleProviderID) -> Bool { providers.contains(providerID) }
}

struct TestAssets: AISubtitleLocalAssetChecking {
  var whisperBinaryURL: URL?
  var whisperModelURL: URL?
}

final class TestExtractor: AISubtitleAudioExtracting {
  private(set) var ranges: [AISubtitleTimeRange] = []

  func extract(media: AISubtitleMediaContext,
               timeRange: AISubtitleTimeRange,
               outputURL: URL,
               completion: @escaping (Result<AISubtitleAudioChunk, AISubtitleError>) -> Void) {
    ranges.append(timeRange)
    completion(.success(AISubtitleAudioChunk(url: outputURL,
                                             timeRange: timeRange,
                                             format: .wav16kMono,
                                             audioTrackID: media.audioTrackID,
                                             audioStreamIndex: media.audioStreamIndex)))
  }
}

final class ControlledTestExtractor: AISubtitleAudioExtracting {
  struct PendingExtraction {
    var media: AISubtitleMediaContext
    var timeRange: AISubtitleTimeRange
    var outputURL: URL
    var completion: (Result<AISubtitleAudioChunk, AISubtitleError>) -> Void

    func succeed() {
      completion(.success(AISubtitleAudioChunk(url: outputURL,
                                               timeRange: timeRange,
                                               format: .wav16kMono,
                                               audioTrackID: media.audioTrackID,
                                               audioStreamIndex: media.audioStreamIndex)))
    }

    func fail(code: String = "controlled_failure") {
      completion(.failure(AISubtitleError(code: code,
                                          message: "Controlled extraction failure.")))
    }
  }

  private let lock = NSLock()
  private let available = DispatchSemaphore(value: 0)
  private var pending: [PendingExtraction] = []

  func extract(media: AISubtitleMediaContext,
               timeRange: AISubtitleTimeRange,
               outputURL: URL,
               completion: @escaping (Result<AISubtitleAudioChunk, AISubtitleError>) -> Void) {
    lock.lock()
    pending.append(PendingExtraction(media: media,
                                     timeRange: timeRange,
                                     outputURL: outputURL,
                                     completion: completion))
    lock.unlock()
    available.signal()
  }

  func next(timeout: DispatchTime = .now() + 2) -> PendingExtraction? {
    guard available.wait(timeout: timeout) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return pending.isEmpty ? nil : pending.removeFirst()
  }
}

final class TestTranscriber: AISubtitleTranscriber {
  let providerID = AISubtitleProviderID.apple
  let modelIdentifier = "self-test"

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    AISubtitleProviderCapability(providerID: .apple,
                                 role: .transcriber,
                                 status: .available,
                                 supportsCloudProcessing: false)
  }

  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    completion(.success([
      AISubtitleSegment(timeRange: chunk.timeRange,
                        text: "chunk \(Int(chunk.timeRange.start))",
                        language: request.sourceLanguage)
    ]))
  }
}

struct TestAPIKeys: AISubtitleAPIKeyProviding {
  var values: [AISubtitleProviderID: String]
  func apiKey(for providerID: AISubtitleProviderID) -> String? { values[providerID] }
}

struct TestConsent: AISubtitleCloudConsentChecking {
  var providers: Set<AISubtitleProviderID>
  func hasConsent(for providerID: AISubtitleProviderID) -> Bool { providers.contains(providerID) }
}

final class TestHTTPTask: AISubtitleHTTPTask {
  private(set) var isCanceled = false
  func cancel() { isCanceled = true }
}

final class TestHTTPTransport: AISubtitleHTTPTransport {
  typealias Handler = (URLRequest) -> Result<(HTTPURLResponse, Data), AISubtitleError>

  var handler: Handler?
  private(set) var requests: [URLRequest] = []
  private(set) var tasks: [TestHTTPTask] = []

  init(handler: Handler? = nil) {
    self.handler = handler
  }

  func send(_ request: URLRequest,
            completion: @escaping (Result<(HTTPURLResponse, Data), AISubtitleError>) -> Void) -> AISubtitleHTTPTask? {
    requests.append(request)
    let task = TestHTTPTask()
    tasks.append(task)
    completion(handler?(request)
      ?? .failure(AISubtitleError(code: "unexpected_network",
                                  message: "The self-test must not use the network.")))
    return task
  }

  static func response(for request: URLRequest,
                       statusCode: Int = 200,
                       data: Data = Data()) -> Result<(HTTPURLResponse, Data), AISubtitleError> {
    .success((HTTPURLResponse(url: request.url!,
                              statusCode: statusCode,
                              httpVersion: "HTTP/1.1",
                              headerFields: nil)!, data))
  }
}

final class SuspendedTestHTTPTransport: AISubtitleHTTPTransport {
  private(set) var requests: [URLRequest] = []
  private(set) var tasks: [TestHTTPTask] = []

  func send(_ request: URLRequest,
            completion: @escaping (Result<(HTTPURLResponse, Data), AISubtitleError>) -> Void) -> AISubtitleHTTPTask? {
    requests.append(request)
    let task = TestHTTPTask()
    tasks.append(task)
    return task
  }
}

final class FailingTestURLProtocol: URLProtocol {
  static var error = URLError(.notConnectedToInternet)

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: Self.error)
  }

  override func stopLoading() {}
}

struct TestAliyunCredentials: AISubtitleAliyunCredentialProviding {
  var value: AISubtitleAliyunCredentials
  func credentials() -> AISubtitleAliyunCredentials { value }
}

final class TestAliyunAudioPublisher: AISubtitleAliyunAudioPublishing {
  let isConfigured = true
  let publishedURL: URL
  private(set) var publishCount = 0
  private(set) var revokedURLs: [URL] = []

  init(publishedURL: URL = URL(string: "https://upload.example/audio.wav")!) {
    self.publishedURL = publishedURL
  }

  func publish(_ chunk: AISubtitleAudioChunk,
               completion: @escaping (Result<URL, AISubtitleError>) -> Void) {
    publishCount += 1
    completion(.success(publishedURL))
  }

  func revoke(_ publishedURL: URL) {
    revokedURLs.append(publishedURL)
  }
}

final class TestWhisperRunner: AISubtitleWhisperCommandRunning {
  var outputJSON: Data
  private(set) var arguments: [String] = []
  private(set) var cancelCount = 0

  init(outputJSON: Data) {
    self.outputJSON = outputJSON
  }

  func run(executableURL: URL,
           arguments: [String],
           completion: @escaping (Result<AISubtitleWhisperCommandResult, AISubtitleError>) -> Void) {
    self.arguments = arguments
    let outputIndex = arguments.firstIndex(of: "-of")!
    let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1]).appendingPathExtension("json")
    try! outputJSON.write(to: outputURL)
    completion(.success(AISubtitleWhisperCommandResult(terminationStatus: 0,
                                                       standardOutput: Data(),
                                                       standardError: Data())))
  }

  func cancelAll() {
    cancelCount += 1
  }
}
