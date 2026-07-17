//
//  WhisperCppAISubtitleProvider.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import CryptoKit
import Foundation

struct AISubtitleWhisperModel: Codable, Hashable {
  var url: URL
  var name: String
  var fileSize: UInt64
  var modifiedAt: Date?

  var versionIdentifier: String {
    let modified = modifiedAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "-"
    return "\(name):\(fileSize):\(modified)"
  }
}

struct AISubtitleWhisperModelManager {
  static let selectedModelDefaultsKey = "aiSubtitle.whisperSelectedModel"

  var modelsDirectoryURL: URL
  var fileManager: FileManager

  init(modelsDirectoryURL: URL = Utility.appSupportDirUrl
         .appendingPathComponent("whisper.cpp", isDirectory: true)
         .appendingPathComponent("models", isDirectory: true),
       fileManager: FileManager = .default) {
    self.modelsDirectoryURL = modelsDirectoryURL
    self.fileManager = fileManager
  }

  func installedModels() -> [AISubtitleWhisperModel] {
    guard let urls = try? fileManager.contentsOfDirectory(at: modelsDirectoryURL,
                                                          includingPropertiesForKeys: [.fileSizeKey,
                                                                                       .contentModificationDateKey,
                                                                                       .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else {
      return []
    }
    return urls.compactMap(model(at:)).sorted {
      if $0.fileSize == $1.fileSize { return $0.name < $1.name }
      return $0.fileSize < $1.fileSize
    }
  }

  func selectedModel(userDefaults: UserDefaults = .standard) -> AISubtitleWhisperModel? {
    let models = installedModels()
    guard let selectedName = userDefaults.string(forKey: Self.selectedModelDefaultsKey) else {
      return models.first
    }
    return models.first(where: { $0.url.lastPathComponent == selectedName }) ?? models.first
  }

  func select(_ model: AISubtitleWhisperModel,
              userDefaults: UserDefaults = .standard) throws {
    let managedModel = installedModels().first {
      $0.url.standardizedFileURL == model.url.standardizedFileURL
    }
    guard managedModel != nil else {
      throw AISubtitleError(code: "whisper_model_select_outside_directory",
                            message: "Only an imported whisper.cpp model can be selected.",
                            recoverable: false)
    }
    userDefaults.set(model.url.lastPathComponent, forKey: Self.selectedModelDefaultsKey)
  }

  func importModel(from sourceURL: URL,
                   expectedSHA256: String? = nil) throws -> AISubtitleWhisperModel {
    guard let sourceModel = model(at: sourceURL), sourceModel.fileSize >= 1_048_576 else {
      throw AISubtitleError(code: "whisper_model_invalid",
                            message: "The selected whisper.cpp model is not a regular GGML model file.")
    }
    if let expectedSHA256 = expectedSHA256 {
      let actualSHA256 = try sha256(of: sourceURL)
      guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
        throw AISubtitleError(code: "whisper_model_checksum_mismatch",
                              message: "The whisper.cpp model checksum does not match.",
                              recoverable: false)
      }
    }
    try fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
    let destination = modelsDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent,
                                                                isDirectory: false)
    if sourceURL.standardizedFileURL != destination.standardizedFileURL {
      let temporary = modelsDirectoryURL.appendingPathComponent(".\(UUID().uuidString).tmp",
                                                                isDirectory: false)
      defer { try? fileManager.removeItem(at: temporary) }
      try fileManager.copyItem(at: sourceURL, to: temporary)
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
    }
    guard let imported = model(at: destination) else {
      throw AISubtitleError(code: "whisper_model_import_failed",
                            message: "The imported whisper.cpp model cannot be read.")
    }
    return imported
  }

  func remove(_ model: AISubtitleWhisperModel) throws {
    let modelsDirectory = modelsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
    let modelURL = model.url.resolvingSymlinksInPath().standardizedFileURL
    guard modelURL.deletingLastPathComponent() == modelsDirectory else {
      throw AISubtitleError(code: "whisper_model_remove_outside_directory",
                            message: "Only managed whisper.cpp models can be removed.",
                            recoverable: false)
    }
    try fileManager.removeItem(at: modelURL)
    if UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey) == model.url.lastPathComponent {
      UserDefaults.standard.removeObject(forKey: Self.selectedModelDefaultsKey)
    }
  }

  func sha256(of url: URL) throws -> String {
    guard let stream = InputStream(url: url) else {
      throw AISubtitleError(code: "whisper_model_checksum_failed",
                            message: "The whisper.cpp model cannot be opened.")
    }
    stream.open()
    defer { stream.close() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw AISubtitleError(code: "whisper_model_checksum_failed",
                              message: stream.streamError?.localizedDescription ?? "Failed reading the whisper.cpp model.")
      }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func model(at url: URL) -> AISubtitleWhisperModel? {
    let validExtension = url.pathExtension.lowercased() == "bin"
    let validName = url.lastPathComponent.lowercased().hasPrefix("ggml-")
      || url.lastPathComponent.lowercased().contains("whisper")
    guard validExtension && validName else { return nil }
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                         .contentModificationDateKey,
                                                         .isRegularFileKey]),
          values.isRegularFile == true,
          let size = values.fileSize,
          size > 0 else { return nil }
    return AISubtitleWhisperModel(url: url,
                                  name: url.deletingPathExtension().lastPathComponent,
                                  fileSize: UInt64(size),
                                  modifiedAt: values.contentModificationDate)
  }
}

struct AISubtitleWhisperExecutableManager {
  var executableURL: URL
  var fileManager: FileManager

  init(executableURL: URL = Utility.appSupportDirUrl
         .appendingPathComponent("whisper.cpp", isDirectory: true)
         .appendingPathComponent("bin", isDirectory: true)
         .appendingPathComponent("whisper-cli"),
       fileManager: FileManager = .default) {
    self.executableURL = executableURL
    self.fileManager = fileManager
  }

  func importExecutable(from sourceURL: URL) throws -> URL {
    guard fileManager.isExecutableFile(atPath: sourceURL.path) else {
      throw AISubtitleError(code: "whisper_executable_invalid",
                            message: "The selected whisper-cli file is not executable.")
    }
    try fileManager.createDirectory(at: executableURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    let temporary = executableURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.copyItem(at: sourceURL, to: temporary)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
    if fileManager.fileExists(atPath: executableURL.path) {
      _ = try fileManager.replaceItemAt(executableURL, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: executableURL)
    }
    return executableURL
  }
}

struct AISubtitleWhisperInstallation {
  var executableURL: URL?
  var selectedModel: AISubtitleWhisperModel?

  static func discover(assetLocator: AISubtitleLocalAssetChecking = AISubtitleLocalAssetLocator(),
                       modelManager: AISubtitleWhisperModelManager = AISubtitleWhisperModelManager()) -> AISubtitleWhisperInstallation {
    let installedModels = modelManager.installedModels()
    let selectedModel = assetLocator.whisperModelURL.flatMap { url in
      installedModels.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
    } ?? modelManager.selectedModel()
    return AISubtitleWhisperInstallation(executableURL: assetLocator.whisperBinaryURL,
                                         selectedModel: selectedModel)
  }
}

struct AISubtitleWhisperCommandResult {
  var terminationStatus: Int32
  var standardOutput: Data
  var standardError: Data
}

protocol AISubtitleWhisperCommandRunning: AnyObject {
  func run(executableURL: URL,
           arguments: [String],
           completion: @escaping (Result<AISubtitleWhisperCommandResult, AISubtitleError>) -> Void)
  func cancelAll()
}

final class AISubtitleWhisperProcessRunner: AISubtitleWhisperCommandRunning {
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var processes: [UUID: Process] = [:]
  private var canceled = false

  init(queue: DispatchQueue = DispatchQueue(label: "IINAAISubtitleWhisperProcess", qos: .utility)) {
    self.queue = queue
  }

  func run(executableURL: URL,
           arguments: [String],
           completion: @escaping (Result<AISubtitleWhisperCommandResult, AISubtitleError>) -> Void) {
    queue.async {
      let identifier = UUID()
      let process = Process()
      let standardOutput = Pipe()
      let standardError = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.standardOutput = standardOutput
      process.standardError = standardError
      self.lock.lock()
      let shouldStart = !self.canceled
      self.lock.unlock()
      guard shouldStart else {
        completion(.failure(AISubtitleError(code: "whisper_process_canceled",
                                            message: "whisper.cpp transcription was canceled.")))
        return
      }
      do {
        try process.run()
      } catch {
        completion(.failure(AISubtitleError(code: "whisper_process_launch_failed",
                                            message: error.localizedDescription)))
        return
      }
      self.lock.lock()
      if self.canceled {
        self.lock.unlock()
        if process.isRunning { process.terminate() }
      } else {
        self.processes[identifier] = process
        self.lock.unlock()
      }

      let readGroup = DispatchGroup()
      var outputData = Data()
      var errorData = Data()
      readGroup.enter()
      DispatchQueue.global(qos: .utility).async {
        outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
      }
      readGroup.enter()
      DispatchQueue.global(qos: .utility).async {
        errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
      }
      process.waitUntilExit()
      readGroup.wait()
      self.lock.lock()
      self.processes.removeValue(forKey: identifier)
      self.lock.unlock()
      completion(.success(AISubtitleWhisperCommandResult(terminationStatus: process.terminationStatus,
                                                         standardOutput: outputData,
                                                         standardError: errorData)))
    }
  }

  func cancelAll() {
    lock.lock()
    canceled = true
    let running = Array(processes.values)
    lock.unlock()
    for process in running where process.isRunning {
      process.terminate()
    }
  }
}

final class WhisperCppAISubtitleTranscriber: AISubtitleTranscriber, AISubtitleCancelableProvider {
  let providerID = AISubtitleProviderID.whisperCpp
  let modelIdentifier: String
  private let installation: AISubtitleWhisperInstallation
  private let runner: AISubtitleWhisperCommandRunning
  private let fileManager: FileManager

  init(installation: AISubtitleWhisperInstallation = .discover(),
       runner: AISubtitleWhisperCommandRunning = AISubtitleWhisperProcessRunner(),
       fileManager: FileManager = .default) {
    self.installation = installation
    self.runner = runner
    self.fileManager = fileManager
    self.modelIdentifier = installation.selectedModel.map { "whisper-cpp:\($0.versionIdentifier)" }
      ?? "whisper-cpp:unconfigured"
  }

  func capability(for request: AISubtitleProviderRequest) -> AISubtitleProviderCapability {
    let status: AISubtitleProviderStatus
    let reason: String?
    if installation.executableURL == nil {
      status = .needsDownload
      reason = "The whisper.cpp command-line executable is not installed."
    } else if installation.selectedModel == nil {
      status = .needsDownload
      reason = "No whisper.cpp model is installed."
    } else {
      status = .available
      reason = nil
    }
    return AISubtitleProviderCapability(providerID: providerID,
                                        role: .transcriber,
                                        status: status,
                                        reason: reason,
                                        supportsCloudProcessing: false,
                                        modelIdentifier: modelIdentifier)
  }

  func transcribe(_ chunk: AISubtitleAudioChunk,
                  request: AISubtitleProviderRequest,
                  completion: @escaping (Result<[AISubtitleSegment], AISubtitleError>) -> Void) {
    guard let executableURL = installation.executableURL,
          let model = installation.selectedModel else {
      completion(.failure(AISubtitleError(code: "whisper_assets_required",
                                          message: "Install the whisper.cpp executable and a model before transcription.")))
      return
    }
    let outputBaseURL = chunk.url.deletingLastPathComponent()
      .appendingPathComponent("whisper-\(UUID().uuidString)", isDirectory: false)
    let outputJSONURL = outputBaseURL.appendingPathExtension("json")
    var arguments = [
      "-m", model.url.path,
      "-f", chunk.url.path,
      "-oj",
      "-of", outputBaseURL.path,
      "-np"
    ]
    arguments.append(contentsOf: ["-l", whisperLanguageCode(request.sourceLanguage)])
    runner.run(executableURL: executableURL, arguments: arguments) { result in
      defer { try? self.fileManager.removeItem(at: outputJSONURL) }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let commandResult):
        guard commandResult.terminationStatus == 0 else {
          let errorText = String(data: commandResult.standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          completion(.failure(AISubtitleError(code: commandResult.terminationStatus == SIGTERM
                                                ? "whisper_process_canceled"
                                                : "whisper_process_failed",
                                              message: errorText?.isEmpty == false
                                                ? errorText!
                                                : "whisper.cpp exited with status \(commandResult.terminationStatus).")))
          return
        }
        do {
          let data = try Data(contentsOf: outputJSONURL)
          completion(.success(try self.decode(data,
                                              chunk: chunk,
                                              language: request.sourceLanguage)))
        } catch let error as AISubtitleError {
          completion(.failure(error))
        } catch {
          completion(.failure(AISubtitleError(code: "whisper_output_read_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }

  func cancelAll() {
    runner.cancelAll()
  }

  private func decode(_ data: Data,
                      chunk: AISubtitleAudioChunk,
                      language: AISubtitleLanguage?) throws -> [AISubtitleSegment] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AISubtitleError(code: "whisper_output_decode_failed",
                            message: "whisper.cpp returned invalid JSON.")
    }
    let entries: [(start: Double, end: Double, text: String)]
    if let transcription = root["transcription"] as? [[String: Any]] {
      entries = transcription.compactMap { item in
        guard let offsets = item["offsets"] as? [String: Any],
              let start = (offsets["from"] as? NSNumber)?.doubleValue,
              let end = (offsets["to"] as? NSNumber)?.doubleValue,
              let text = item["text"] as? String else { return nil }
        return (start / 1000, end / 1000, text)
      }
    } else if let segments = root["segments"] as? [[String: Any]] {
      entries = segments.compactMap { item in
        guard let start = (item["start"] as? NSNumber)?.doubleValue,
              let end = (item["end"] as? NSNumber)?.doubleValue,
              let text = item["text"] as? String else { return nil }
        return (start, end, text)
      }
    } else {
      throw AISubtitleError(code: "whisper_output_schema_unsupported",
                            message: "whisper.cpp returned an unsupported JSON schema.")
    }
    return entries.enumerated().compactMap { index, entry in
      let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, entry.start.isFinite, entry.end.isFinite, entry.end > entry.start else { return nil }
      let start = chunk.timeRange.start + max(0, entry.start)
      let end = min(chunk.timeRange.end, chunk.timeRange.start + entry.end)
      guard end > start else { return nil }
      return AISubtitleSegment(id: "whisper-\(Int(chunk.timeRange.start * 1000))-\(index)",
                               timeRange: AISubtitleTimeRange(start: start, end: end),
                               text: text,
                               language: language)
    }
  }

  private func whisperLanguageCode(_ language: AISubtitleLanguage?) -> String {
    guard let language = language else { return "auto" }
    let normalized = language.code.replacingOccurrences(of: "_", with: "-").lowercased()
    return normalized.split(separator: "-").first.map(String.init) ?? "auto"
  }
}
