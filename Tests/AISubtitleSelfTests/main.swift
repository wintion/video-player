import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

func expectEventually(timeout: TimeInterval = 2,
                      _ condition: () -> Bool,
                      _ message: String) {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return }
    Thread.sleep(forTimeInterval: 0.01)
  }
  expect(condition(), message)
}

func waitWhileRunningMainLoop(_ semaphore: DispatchSemaphore,
                              timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if semaphore.wait(timeout: .now()) == .success { return true }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return semaphore.wait(timeout: .now()) == .success
}

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  .appendingPathComponent("ai-subtitle-tests-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

let english = AISubtitleLanguage("en")
let chinese = AISubtitleLanguage("zh-Hans")
expect(english.isEquivalent(to: AISubtitleLanguage("en-US")) &&
       chinese.isEquivalent(to: AISubtitleLanguage("zh-CN")) &&
       !chinese.isEquivalent(to: AISubtitleLanguage("zh-Hant")),
       "Language matching should ignore regions while preserving Chinese script conversion")
let media = AISubtitleMediaContext(url: URL(fileURLWithPath: "/tmp/movie.mp4"),
                                   isNetworkResource: false,
                                   fileSize: 123,
                                   fileModifiedAt: Date(timeIntervalSince1970: 100),
                                   audioTrackID: 1,
                                   sourceLanguage: english,
                                   targetLanguage: chinese)
let request = AISubtitleProviderRequest(sourceLanguage: english,
                                        targetLanguage: chinese,
                                        media: media)
let suggestionMediaURL = URL(fileURLWithPath: "/tmp/suggestion.mov")
expect(AISubtitleSuggestionPolicy.shouldSchedule(isEnabled: true,
                                                 mediaURL: suggestionMediaURL,
                                                 previouslySuggestedMediaURL: nil),
       "A subtitle suggestion should be scheduled once for eligible media")
expect(!AISubtitleSuggestionPolicy.shouldSchedule(isEnabled: false,
                                                  mediaURL: suggestionMediaURL,
                                                  previouslySuggestedMediaURL: nil)
       && !AISubtitleSuggestionPolicy.shouldSchedule(isEnabled: true,
                                                     mediaURL: suggestionMediaURL,
                                                     previouslySuggestedMediaURL: suggestionMediaURL),
       "Disabled or previously shown subtitle suggestions should not be rescheduled")
expect(AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                currentMediaURL: suggestionMediaURL,
                                                isPlaybackActive: true,
                                                hasAudioTracks: true,
                                                hasSubtitleTracks: false,
                                                hasExportableAISubtitles: false),
       "Active media with audio and no subtitles should offer AI subtitle generation")
expect(!AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                 currentMediaURL: suggestionMediaURL,
                                                 isPlaybackActive: true,
                                                 hasAudioTracks: true,
                                                 hasSubtitleTracks: true,
                                                 hasExportableAISubtitles: false),
       "Media with an existing subtitle track should not show the AI subtitle suggestion")
expect(!AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                 currentMediaURL: suggestionMediaURL,
                                                 isPlaybackActive: true,
                                                 hasAudioTracks: true,
                                                 hasSubtitleTracks: false,
                                                 hasExportableAISubtitles: true),
       "Media with reusable AI subtitle cache should not show a duplicate suggestion")
expect(!AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                 currentMediaURL: URL(fileURLWithPath: "/tmp/other.mov"),
                                                 isPlaybackActive: true,
                                                 hasAudioTracks: true,
                                                 hasSubtitleTracks: false,
                                                 hasExportableAISubtitles: false)
       && !AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                    currentMediaURL: suggestionMediaURL,
                                                    isPlaybackActive: false,
                                                    hasAudioTracks: true,
                                                    hasSubtitleTracks: false,
                                                    hasExportableAISubtitles: false)
       && !AISubtitleSuggestionPolicy.shouldPresent(scheduledMediaURL: suggestionMediaURL,
                                                    currentMediaURL: suggestionMediaURL,
                                                    isPlaybackActive: true,
                                                    hasAudioTracks: false,
                                                    hasSubtitleTracks: false,
                                                    hasExportableAISubtitles: false),
       "Stale, inactive, or silent media should not show the AI subtitle suggestion")
let noAssets = TestAssets(whisperBinaryURL: nil, whisperModelURL: nil)
expect(AISubtitleProviderID(preferenceIndex: 0) == .apple &&
       AISubtitleProviderID(preferenceIndex: 3) == .whisperCpp &&
       AISubtitleProviderID(preferenceIndex: 4) == nil,
       "Saved provider indices should map deterministically")
let swiftTaskBag = AISubtitleSwiftTaskBag()
let completedTaskIdentifier = swiftTaskBag.reserve()
let completedTaskSignal = DispatchSemaphore(value: 0)
let completedSwiftTask = Task {
  swiftTaskBag.remove(completedTaskIdentifier)
  completedTaskSignal.signal()
}
expect(completedTaskSignal.wait(timeout: .now() + 1) == .success,
       "The Swift task bag race test should complete its task")
swiftTaskBag.attach(completedSwiftTask, to: completedTaskIdentifier)
expect(swiftTaskBag.activeTaskCount == 0,
       "A Swift task completing before registration should not remain retained")
let applePlan = AISubtitleCapabilityDetector(
  platform: AISubtitlePlatform(majorVersion: 26, minorVersion: 5, patchVersion: 0, architecture: "arm64"),
  credentialChecker: TestCredentials(providers: [.openAI]),
  assetLocator: noAssets
).recommendedPlan(for: request)
expect(applePlan.transcriber == .apple && applePlan.translator == .apple,
       "Apple should be preferred on macOS 26")

let oldMac = AISubtitlePlatform(majorVersion: 15, minorVersion: 0, patchVersion: 0, architecture: "arm64")
let cloudPlan = AISubtitleCapabilityDetector(platform: oldMac,
                                             credentialChecker: TestCredentials(providers: [.aliyun]),
                                             assetLocator: noAssets)
  .recommendedPlan(for: request)
expect(cloudPlan.transcriber == .aliyun && cloudPlan.translator == .aliyun,
       "A configured cloud provider should be selected when Apple is unavailable")

let transcript = [
  AISubtitleSegment(id: "1", timeRange: AISubtitleTimeRange(start: 0, end: 2), text: " Hello "),
  AISubtitleSegment(id: "2", timeRange: AISubtitleTimeRange(start: 1.8, end: 3), text: "Hello"),
  AISubtitleSegment(id: "3", timeRange: AISubtitleTimeRange(start: 3.05, end: 4), text: "world")
]
let cues = AISubtitleTimelineAssembler().assemble(transcript, targetLanguage: english)
expect(cues.count == 1 && cues[0].text == "Hello world" && cues[0].timeRange.end == 4,
       "Timeline assembly should deduplicate overlap and merge adjacent text")
let punctuationCues = AISubtitleTimelineAssembler().assemble([
  AISubtitleSegment(id: "punctuation-1",
                    timeRange: AISubtitleTimeRange(start: 0, end: 1),
                    text: "Hello"),
  AISubtitleSegment(id: "punctuation-2",
                    timeRange: AISubtitleTimeRange(start: 1, end: 1.2),
                    text: ".")
], targetLanguage: english)
let punctuationSpacingCues = AISubtitleTimelineAssembler().assemble([
  AISubtitleSegment(id: "punctuation-spacing",
                    timeRange: AISubtitleTimeRange(start: 0, end: 1),
                    text: "Hello .")
], targetLanguage: english)
expect(punctuationCues.count == 1 && punctuationCues[0].text == "Hello."
       && punctuationSpacingCues.first?.text == "Hello.",
       "Timeline assembly should remove spaces before punctuation and merge standalone punctuation cues")
let writer = AISubtitleFileWriter()
expect(writer.string(for: cues, format: .webVTT).contains("00:00:00.000 --> 00:00:04.000\nHello world"),
       "WebVTT timestamps should be valid")
expect(writer.string(for: cues, format: .srt).contains("00:00:00,000 --> 00:00:04,000\nHello world"),
       "SRT timestamps should be valid")

let store = AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: tempRoot))
let key = AISubtitleCacheKey(media: media,
                             transcriberID: .apple,
                             translatorID: .apple,
                             transcriberModelIdentifier: "speech-v1",
                             translatorModelIdentifier: "translation-v1")
var secondAudioTrackMedia = media
secondAudioTrackMedia.audioTrackID = 2
secondAudioTrackMedia.audioStreamIndex = 1
let secondAudioTrackKey = AISubtitleCacheKey(media: secondAudioTrackMedia,
                                             transcriberID: .apple,
                                             translatorID: .apple,
                                             transcriberModelIdentifier: "speech-v1",
                                             translatorModelIdentifier: "translation-v1")
expect(secondAudioTrackKey.stableIdentifier != key.stableIdentifier,
       "Different audio tracks in the same media must use isolated subtitle caches")
let artifacts = try AISubtitleFilePipeline(cacheStore: store).prepare(transcript: transcript,
                                                                       targetLanguage: english,
                                                                       cacheKey: key)
expect(store.cachedVTT(for: key) == artifacts.translatedVTTURL,
       "Committed cache should be discoverable")
var preciseTimestampMedia = media
preciseTimestampMedia.fileModifiedAt = Date(timeIntervalSince1970: 100.123456789)
let preciseTimestampKey = AISubtitleCacheKey(media: preciseTimestampMedia,
                                             transcriberID: .apple,
                                             translatorID: .apple)
let preciseTimestampRoot = tempRoot.deletingLastPathComponent()
  .appendingPathComponent("ai-subtitle-precise-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: preciseTimestampRoot) }
let preciseTimestampStore = AISubtitleCacheStore(layout: AISubtitleCacheLayout(
  rootURL: preciseTimestampRoot))
let preciseTimestampArtifacts = try AISubtitleFilePipeline(cacheStore: preciseTimestampStore).prepare(
  transcript: transcript,
  targetLanguage: english,
  cacheKey: preciseTimestampKey)
expect(preciseTimestampStore.cachedVTT(for: preciseTimestampKey) == preciseTimestampArtifacts.translatedVTTURL,
       "Cache validation should tolerate JSON date precision below the millisecond cache-key granularity")
expect(AISubtitleCacheKey(media: media,
                          transcriberID: .apple,
                          translatorID: .apple,
                          transcriberModelIdentifier: "speech-v1",
                          translatorModelIdentifier: "translation-v1").stableIdentifier == key.stableIdentifier,
       "Cache identifiers should be deterministic")

var alternateMedia = media
alternateMedia.targetLanguage = english
let alternateKey = AISubtitleCacheKey(media: alternateMedia,
                                      transcriberID: .apple,
                                      translatorID: nil)
_ = try AISubtitleFilePipeline(cacheStore: store).prepare(transcript: transcript,
                                                        targetLanguage: english,
                                                        cacheKey: alternateKey)
let beforePrune = try store.usage()
let afterPrune = try store.prune(maximumBytes: 0, excluding: key)
expect(beforePrune.entryCount == 2 && afterPrune.entryCount == 1 && afterPrune.removedEntryCount == 1,
       "Cache pruning should evict inactive entries and preserve the active key")

let plannedRanges = AISubtitleChunkPlanner().ranges(covering: AISubtitleTimeRange(start: 10, end: 140))
expect(plannedRanges == [AISubtitleTimeRange(start: 10, end: 70),
                         AISubtitleTimeRange(start: 68.5, end: 128.5),
                         AISubtitleTimeRange(start: 127, end: 140)],
       "Chunk planning should use 60-second chunks with 1.5-second overlap")

let schedulerRoot = tempRoot.appendingPathComponent("scheduler", isDirectory: true)
let schedulerStore = AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: schedulerRoot))
var sameLanguageMedia = media
sameLanguageMedia.targetLanguage = english
let schedulerKey = AISubtitleCacheKey(media: sameLanguageMedia,
                                      transcriberID: .apple,
                                      translatorID: nil)
let extractor = TestExtractor()
let scheduler = AISubtitleScheduler(extractor: extractor,
                                    transcriber: TestTranscriber(),
                                    translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                    cacheStore: schedulerStore)
let completed = DispatchSemaphore(value: 0)
scheduler.start(media: sameLanguageMedia,
                mediaDuration: 130,
                cacheKey: schedulerKey,
                playbackPosition: 0,
                stateHandler: { if $0.phase == .maintaining { completed.signal() } },
                subtitleFileHandler: { _ in })
expect(completed.wait(timeout: .now() + 5) == .success && extractor.ranges.count == 3,
       "Scheduler should fill a five-minute-ahead window in planned chunks")
scheduler.cancel()

let endOfFileExtractor = TestExtractor()
let endOfFileScheduler = AISubtitleScheduler(
  extractor: endOfFileExtractor,
  transcriber: TestTranscriber(),
  translator: AISubtitlePassThroughTranslator(providerID: .apple),
  cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(
    rootURL: tempRoot.appendingPathComponent("end-of-file", isDirectory: true))))
let endOfFileCompleted = DispatchSemaphore(value: 0)
endOfFileScheduler.start(
  media: sameLanguageMedia,
  mediaDuration: 15,
  cacheKey: AISubtitleCacheKey(media: sameLanguageMedia,
                               transcriberID: .apple,
                               translatorID: nil,
                               transcriberModelIdentifier: "end-of-file-test"),
  playbackPosition: 15,
  stateHandler: { if $0.phase == .maintaining { endOfFileCompleted.signal() } },
  subtitleFileHandler: { _ in })
expect(endOfFileCompleted.wait(timeout: .now() + 5) == .success
       && endOfFileExtractor.ranges == [AISubtitleTimeRange(start: 0, end: 15)],
       "Starting generation at end of file should process the media from the beginning")
endOfFileScheduler.cancel()

let resumedExtractor = TestExtractor()
let resumedScheduler = AISubtitleScheduler(extractor: resumedExtractor,
                                           transcriber: TestTranscriber(),
                                           translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                           cacheStore: schedulerStore)
let resumed = DispatchSemaphore(value: 0)
resumedScheduler.start(media: sameLanguageMedia,
                       mediaDuration: 130,
                       cacheKey: schedulerKey,
                       playbackPosition: 0,
                       stateHandler: { if $0.phase == .maintaining { resumed.signal() } },
                       subtitleFileHandler: { _ in })
expect(resumed.wait(timeout: .now() + 5) == .success && resumedExtractor.ranges.isEmpty,
       "Scheduler should resume from a complete cache without extracting again")
resumedScheduler.cancel()

let seekRoot = tempRoot.appendingPathComponent("seek", isDirectory: true)
let seekExtractor = ControlledTestExtractor()
let seekScheduler = AISubtitleScheduler(extractor: seekExtractor,
                                        transcriber: TestTranscriber(),
                                        translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                        cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: seekRoot)),
                                        configuration: AISubtitleScheduler.Configuration(
                                          aheadDuration: 300,
                                          refillThreshold: 60,
                                          chunkPlanner: AISubtitleChunkPlanner(chunkDuration: 300,
                                                                                overlapDuration: 0)))
let seekKey = AISubtitleCacheKey(media: sameLanguageMedia,
                                 transcriberID: .apple,
                                 translatorID: nil,
                                 transcriberModelIdentifier: "seek-test")
let seekMaintaining = DispatchSemaphore(value: 0)
var seekMaintainingRange: AISubtitleTimeRange?
seekScheduler.start(media: sameLanguageMedia,
                    mediaDuration: 1_000,
                    cacheKey: seekKey,
                    playbackPosition: 0,
                    stateHandler: {
                      if $0.phase == .maintaining {
                        seekMaintainingRange = $0.coveredRange
                        seekMaintaining.signal()
                      }
                    },
                    subtitleFileHandler: { _ in })
guard let firstSeekExtraction = seekExtractor.next() else {
  expect(false, "Seek test should start extracting the initial playback window")
  fatalError()
}
expect(firstSeekExtraction.timeRange.start == 0,
       "The initial extraction should begin at the playback position")
try FileManager.default.createDirectory(at: firstSeekExtraction.outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try Data([0, 1, 2]).write(to: firstSeekExtraction.outputURL)
seekScheduler.updatePlaybackPosition(600)
firstSeekExtraction.succeed()
guard let postSeekExtraction = seekExtractor.next() else {
  expect(false, "Seek should enqueue the new playback window after the active chunk finishes")
  fatalError()
}
expect(postSeekExtraction.timeRange.start == 600,
       "Seek should prioritize the requested playback position instead of the old pending window")
postSeekExtraction.succeed()
expect(seekMaintaining.wait(timeout: .now() + 5) == .success
       && seekMaintainingRange == AISubtitleTimeRange(start: 600, end: 900),
       "Scheduler status should report the continuous cached range containing the seek position")
seekScheduler.cancel()

let cancelRoot = tempRoot.appendingPathComponent("cancel", isDirectory: true)
let cancelExtractor = ControlledTestExtractor()
let cancelScheduler = AISubtitleScheduler(extractor: cancelExtractor,
                                          transcriber: TestTranscriber(),
                                          translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                          cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: cancelRoot)))
let canceledState = DispatchSemaphore(value: 0)
var canceledSubtitleWasPublished = false
cancelScheduler.start(media: sameLanguageMedia,
                      mediaDuration: 300,
                      cacheKey: AISubtitleCacheKey(media: sameLanguageMedia,
                                                   transcriberID: .apple,
                                                   translatorID: nil,
                                                   transcriberModelIdentifier: "cancel-test"),
                      playbackPosition: 0,
                      stateHandler: { if $0.phase == .canceled { canceledState.signal() } },
                      subtitleFileHandler: { _ in canceledSubtitleWasPublished = true })
guard let canceledExtraction = cancelExtractor.next() else {
  expect(false, "Cancel test should have an active extraction")
  fatalError()
}
try FileManager.default.createDirectory(at: canceledExtraction.outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try Data([0, 1, 2]).write(to: canceledExtraction.outputURL)
cancelScheduler.cancel()
expect(canceledState.wait(timeout: .now() + 2) == .success,
       "Cancel should transition the scheduler before stale extraction completion")
canceledExtraction.succeed()
expectEventually({ !FileManager.default.fileExists(atPath: canceledExtraction.outputURL.path) },
                 "A chunk completing after cancel should be deleted")
Thread.sleep(forTimeInterval: 0.05)
expect(!canceledSubtitleWasPublished,
       "A stale completion after cancel must not publish a subtitle file")

let failureRoot = tempRoot.appendingPathComponent("failure-recovery", isDirectory: true)
let failureKey = AISubtitleCacheKey(media: sameLanguageMedia,
                                    transcriberID: .apple,
                                    translatorID: nil,
                                    transcriberModelIdentifier: "failure-recovery-test")
let failingExtractor = ControlledTestExtractor()
let failingScheduler = AISubtitleScheduler(extractor: failingExtractor,
                                           transcriber: TestTranscriber(),
                                           translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                           cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: failureRoot)))
let failedState = DispatchSemaphore(value: 0)
failingScheduler.start(media: sameLanguageMedia,
                       mediaDuration: 60,
                       cacheKey: failureKey,
                       playbackPosition: 0,
                       stateHandler: { if $0.phase == .failed { failedState.signal() } },
                       subtitleFileHandler: { _ in })
guard let failedExtraction = failingExtractor.next() else {
  expect(false, "Failure test should start extraction")
  fatalError()
}
failedExtraction.fail()
expect(failedState.wait(timeout: .now() + 2) == .success,
       "Extraction failure should enter a recoverable failed state")
failingScheduler.cancel()
let recoveryExtractor = TestExtractor()
let recoveryScheduler = AISubtitleScheduler(extractor: recoveryExtractor,
                                            transcriber: TestTranscriber(),
                                            translator: AISubtitlePassThroughTranslator(providerID: .apple),
                                            cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: failureRoot)))
let recoveredState = DispatchSemaphore(value: 0)
recoveryScheduler.start(media: sameLanguageMedia,
                        mediaDuration: 60,
                        cacheKey: failureKey,
                        playbackPosition: 0,
                        stateHandler: { if $0.phase == .maintaining { recoveredState.signal() } },
                        subtitleFileHandler: { _ in })
expect(recoveredState.wait(timeout: .now() + 2) == .success && recoveryExtractor.ranges.count == 1,
       "Starting a new job after failure should recover and fill the missing range")
recoveryScheduler.cancel()

let longVideoRoot = tempRoot.appendingPathComponent("long-video", isDirectory: true)
let longVideoExtractor = TestExtractor()
let longVideoScheduler = AISubtitleScheduler(
  extractor: longVideoExtractor,
  transcriber: TestTranscriber(),
  translator: AISubtitlePassThroughTranslator(providerID: .apple),
  cacheStore: AISubtitleCacheStore(layout: AISubtitleCacheLayout(rootURL: longVideoRoot))
)
let longVideoMaintaining = DispatchSemaphore(value: 0)
longVideoScheduler.start(media: sameLanguageMedia,
                         mediaDuration: 7_200,
                         cacheKey: AISubtitleCacheKey(media: sameLanguageMedia,
                                                      transcriberID: .apple,
                                                      translatorID: nil,
                                                      transcriberModelIdentifier: "long-video-test"),
                         playbackPosition: 0,
                         stateHandler: { if $0.phase == .maintaining { longVideoMaintaining.signal() } },
                         subtitleFileHandler: { _ in })
expect(longVideoMaintaining.wait(timeout: .now() + 5) == .success,
       "A long video should finish its initial ahead window")
expect(longVideoExtractor.ranges.count == 6 &&
       longVideoExtractor.ranges.last?.end == 300,
       "A two-hour video should only generate the first five-minute window")
longVideoScheduler.cancel()

let largeTranscript = (0..<10_000).map { index in
  let start = Double(index) * 2
  return AISubtitleSegment(id: "large-\(index)",
                           timeRange: AISubtitleTimeRange(start: start, end: start + 1),
                           text: "subtitle \(index)",
                           language: english)
}
let largeTimelineStarted = Date()
let largeCues = AISubtitleTimelineAssembler().assemble(largeTranscript, targetLanguage: english)
let largeVTT = AISubtitleFileWriter().string(for: largeCues, format: .webVTT)
expect(largeCues.count == 10_000 && largeVTT.contains("subtitle 9999"),
       "Large subtitle timelines should preserve every non-overlapping cue")
expect(Date().timeIntervalSince(largeTimelineStarted) < 5,
       "Assembling and serializing 10,000 cues should remain bounded")

let deniedTransport = TestHTTPTransport()
let deniedTranscriber = OpenAIAISubtitleTranscriber(apiKeyProvider: TestAPIKeys(values: [.openAI: "test-key"]),
                                                    consentChecker: TestConsent(providers: []),
                                                    transport: deniedTransport)
expect(deniedTranscriber.capability(for: request).status == .needsAuthorization,
       "Cloud transcription should require explicit consent")
let deniedAudioURL = tempRoot.appendingPathComponent("denied.wav")
try Data([0, 1, 2]).write(to: deniedAudioURL)
if #available(macOS 26.0, *) {
  let appleTranscriber = AppleAISubtitleTranscriber()
  let unsupportedSpeechRequest = AISubtitleProviderRequest(
    sourceLanguage: AISubtitleLanguage("zz-ZZ"),
    targetLanguage: english,
    media: media
  )
  let unsupportedSpeechProbeSignal = DispatchSemaphore(value: 0)
  var unsupportedSpeechCapability: AISubtitleProviderCapability?
  Task {
    unsupportedSpeechCapability = await appleTranscriber.probe(language: AISubtitleLanguage("zz-ZZ"))
    unsupportedSpeechProbeSignal.signal()
  }
  expect(waitWhileRunningMainLoop(unsupportedSpeechProbeSignal, timeout: 5)
         && unsupportedSpeechCapability?.status == .unavailable,
         "Apple Speech should report an unsupported spoken language without requesting assets")
  let unsupportedSpeechSignal = DispatchSemaphore(value: 0)
  var unsupportedSpeechError: AISubtitleError?
  appleTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                   timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                   format: .wav16kMono),
                               request: unsupportedSpeechRequest) {
    if case .failure(let error) = $0 { unsupportedSpeechError = error }
    unsupportedSpeechSignal.signal()
  }
  expect(waitWhileRunningMainLoop(unsupportedSpeechSignal, timeout: 5)
         && unsupportedSpeechError?.code == "apple_speech_language_unsupported"
         && unsupportedSpeechError?.recoverable == false,
         "Apple Speech should fail unsupported languages before reading audio")

  let appleTranslator = AppleAISubtitleTranslator()
  let unsupportedTranslationProbeSignal = DispatchSemaphore(value: 0)
  var unsupportedTranslationCapability: AISubtitleProviderCapability?
  Task {
    unsupportedTranslationCapability = await appleTranslator.probe(
      sourceLanguage: AISubtitleLanguage("zz-ZZ"),
      targetLanguage: english
    )
    unsupportedTranslationProbeSignal.signal()
  }
  expect(waitWhileRunningMainLoop(unsupportedTranslationProbeSignal, timeout: 15),
         "Apple Translation language availability should finish within 15 seconds")
  expect(unsupportedTranslationCapability?.status == .unavailable,
         "Apple Translation should report an unsupported language pair without requesting assets; got \(String(describing: unsupportedTranslationCapability?.status))")
  let unsupportedTranslationSignal = DispatchSemaphore(value: 0)
  var unsupportedTranslationError: AISubtitleError?
  appleTranslator.translate(transcript, request: unsupportedSpeechRequest) {
    if case .failure(let error) = $0 { unsupportedTranslationError = error }
    unsupportedTranslationSignal.signal()
  }
  expect(waitWhileRunningMainLoop(unsupportedTranslationSignal, timeout: 15)
         && unsupportedTranslationError?.code == "apple_translation_language_unsupported"
         && unsupportedTranslationError?.recoverable == false,
         "Apple Translation should distinguish unsupported pairs from downloadable assets")
}
var deniedError: AISubtitleError?
deniedTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                  timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                  format: .wav16kMono),
                              request: request) {
  if case .failure(let error) = $0 { deniedError = error }
}
expect(deniedError?.code == "openai_cloud_consent_required" && deniedTransport.requests.isEmpty,
       "Denied cloud work should fail before reading or uploading audio")
let deniedFallbackFactory = AISubtitleCloudProviderFactory(
  openAIAPIKeyProvider: TestAPIKeys(values: [.openAI: "test-key"]),
  consentChecker: TestConsent(providers: []),
  transport: deniedTransport
)
if case .failure(let fallbackError) = deniedFallbackFactory.makePair(providerID: .openAI,
                                                                     request: request) {
  expect(fallbackError.code == "openAI_transcriber_needsAuthorization" && deniedTransport.requests.isEmpty,
         "Automatic cloud fallback should remain blocked without explicit upload consent")
} else {
  expect(false, "A cloud fallback without upload consent must not be created")
}
let deniedAliyunTransport = TestHTTPTransport()
let deniedAliyunCredentials = TestAliyunCredentials(value: AISubtitleAliyunCredentials(
  dashScopeAPIKey: "dashscope-test-key",
  machineTranslationAccessKeyID: "id",
  machineTranslationAccessKeySecret: "secret"
))
let deniedAliyunTranscriber = AliyunAISubtitleTranscriber(
  credentialProvider: deniedAliyunCredentials,
  consentChecker: TestConsent(providers: []),
  publisher: UnavailableAISubtitleAliyunAudioPublisher(),
  transport: deniedAliyunTransport
)
expect(deniedAliyunTranscriber.capability(for: request).status == .needsAuthorization,
       "Aliyun transcription should require explicit consent before checking upload configuration")
var deniedAliyunTranscriptionError: AISubtitleError?
deniedAliyunTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                        timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                        format: .wav16kMono),
                                    request: request) {
  if case .failure(let error) = $0 { deniedAliyunTranscriptionError = error }
}
expect(deniedAliyunTranscriptionError?.code == "aliyun_cloud_consent_required"
       && deniedAliyunTransport.requests.isEmpty,
       "Denied Aliyun transcription should not publish audio or send HTTP requests")
let deniedAliyunTranslator = AliyunAISubtitleTranslator(
  credentialProvider: deniedAliyunCredentials,
  consentChecker: TestConsent(providers: []),
  transport: deniedAliyunTransport
)
expect(deniedAliyunTranslator.capability(for: request).status == .needsAuthorization,
       "Aliyun translation should require explicit consent before checking credentials")
var deniedAliyunTranslationError: AISubtitleError?
deniedAliyunTranslator.translate(transcript, request: request) {
  if case .failure(let error) = $0 { deniedAliyunTranslationError = error }
}
expect(deniedAliyunTranslationError?.code == "aliyun_cloud_consent_required"
       && deniedAliyunTransport.requests.isEmpty,
       "Denied Aliyun translation should not send subtitle text over HTTP")
let deniedAliyunFactory = AISubtitleCloudProviderFactory(
  aliyunCredentialProvider: deniedAliyunCredentials,
  consentChecker: TestConsent(providers: []),
  aliyunAudioPublisher: UnavailableAISubtitleAliyunAudioPublisher(),
  transport: deniedAliyunTransport
)
if case .failure(let fallbackError) = deniedAliyunFactory.makePair(providerID: .aliyun,
                                                                   request: request) {
  expect(fallbackError.code == "aliyun_transcriber_needsAuthorization"
         && deniedAliyunTransport.requests.isEmpty,
         "Automatic Aliyun fallback should remain blocked without explicit upload consent")
} else {
  expect(false, "An Aliyun fallback without upload consent must not be created")
}
let suspendedTransport = SuspendedTestHTTPTransport()
let cancelableOpenAI = OpenAIAISubtitleTranscriber(
  apiKeyProvider: TestAPIKeys(values: [.openAI: "test-key"]),
  consentChecker: TestConsent(providers: [.openAI]),
  transport: suspendedTransport
)
cancelableOpenAI.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                 timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                 format: .wav16kMono),
                             request: request) { _ in }
cancelableOpenAI.cancelAll()
expect(suspendedTransport.tasks.count == 1 && suspendedTransport.tasks[0].isCanceled,
       "Canceling a cloud provider should cancel an in-flight HTTP task")

let failingSessionConfiguration = URLSessionConfiguration.ephemeral
failingSessionConfiguration.protocolClasses = [FailingTestURLProtocol.self]
let failingURLSessionTransport = URLSessionAISubtitleHTTPTransport(
  session: URLSession(configuration: failingSessionConfiguration)
)
let networkFailureSignal = DispatchSemaphore(value: 0)
var mappedNetworkError: AISubtitleError?
failingURLSessionTransport.send(URLRequest(url: URL(string: "https://network-failure.test")!)) {
  if case .failure(let error) = $0 { mappedNetworkError = error }
  networkFailureSignal.signal()
}
expect(networkFailureSignal.wait(timeout: .now() + 2) == .success
       && mappedNetworkError?.code == "cloud_network_failed"
       && mappedNetworkError?.recoverable == true,
       "URLSession network failures should map to a recoverable cloud error")

let openAINetworkTransport = TestHTTPTransport { _ in
  .failure(AISubtitleError(code: "cloud_network_failed",
                           message: "The network connection is offline."))
}
let openAINetworkTranscriber = OpenAIAISubtitleTranscriber(
  apiKeyProvider: TestAPIKeys(values: [.openAI: "test-key"]),
  consentChecker: TestConsent(providers: [.openAI]),
  transport: openAINetworkTransport
)
var openAITranscriptionNetworkError: AISubtitleError?
openAINetworkTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                         timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                         format: .wav16kMono),
                                     request: request) {
  if case .failure(let error) = $0 { openAITranscriptionNetworkError = error }
}
expect(openAITranscriptionNetworkError?.code == "cloud_network_failed"
       && openAINetworkTransport.requests.count == 1,
       "OpenAI transcription should surface a recoverable network failure")
let openAINetworkTranslator = OpenAIAISubtitleTranslator(
  apiKeyProvider: TestAPIKeys(values: [.openAI: "test-key"]),
  consentChecker: TestConsent(providers: [.openAI]),
  transport: openAINetworkTransport
)
var openAITranslationNetworkError: AISubtitleError?
openAINetworkTranslator.translate(transcript, request: request) {
  if case .failure(let error) = $0 { openAITranslationNetworkError = error }
}
expect(openAITranslationNetworkError?.code == "cloud_network_failed"
       && openAINetworkTransport.requests.count == 2,
       "OpenAI translation should surface a recoverable network failure")
openAINetworkTranscriber.cancelAll()
openAINetworkTranslator.cancelAll()
expect(openAINetworkTransport.tasks.allSatisfy({ !$0.isCanceled }),
       "Completed OpenAI network failures should be released from cancellation tracking")

let signer = AISubtitleAliyunROASigner(date: Date(timeIntervalSince1970: 0), nonce: "fixed-nonce")
let signedRequest = signer.signedRequest(
  endpoint: URL(string: "https://mt.cn-hangzhou.aliyuncs.com/api/translate/web/general")!,
  body: Data("hello".utf8),
  credentials: AISubtitleAliyunMachineTranslationCredentials(accessKeyID: "id", accessKeySecret: "secret")
)
expect(signedRequest.value(forHTTPHeaderField: "Authorization") == "acs id:5TJqrdZZTaIdTQMEk+RiX+Njy80=",
       "Aliyun request signing should match the fixed vector")

let aliyunCredentials = TestAliyunCredentials(value: AISubtitleAliyunCredentials(
  dashScopeAPIKey: "dashscope-test-key",
  machineTranslationAccessKeyID: "id",
  machineTranslationAccessKeySecret: "secret"
))
let aliyunUploadNetworkTransport = TestHTTPTransport { _ in
  .failure(AISubtitleError(code: "cloud_network_failed",
                           message: "The network connection is offline."))
}
let aliyunUploadNetworkPublisher = DashScopeTemporaryAISubtitleAliyunAudioPublisher(
  credentialProvider: aliyunCredentials,
  transport: aliyunUploadNetworkTransport
)
var aliyunUploadNetworkError: AISubtitleError?
aliyunUploadNetworkPublisher.publish(AISubtitleAudioChunk(url: deniedAudioURL,
                                                          timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                          format: .wav16kMono)) {
  if case .failure(let error) = $0 { aliyunUploadNetworkError = error }
}
expect(aliyunUploadNetworkError?.code == "cloud_network_failed"
       && aliyunUploadNetworkTransport.requests.count == 1,
       "Aliyun temporary publishing should surface a network failure before audio upload")
aliyunUploadNetworkPublisher.cancelAll()
expect(aliyunUploadNetworkTransport.tasks.allSatisfy({ !$0.isCanceled }),
       "A completed Aliyun upload credential failure should be released from cancellation tracking")
let aliyunNetworkTransport = TestHTTPTransport { _ in
  .failure(AISubtitleError(code: "cloud_network_failed",
                           message: "The network connection is offline."))
}
let aliyunNetworkPublisher = TestAliyunAudioPublisher()
let aliyunNetworkTranscriber = AliyunAISubtitleTranscriber(
  credentialProvider: aliyunCredentials,
  consentChecker: TestConsent(providers: [.aliyun]),
  publisher: aliyunNetworkPublisher,
  transport: aliyunNetworkTransport,
  pollInterval: 0,
  delay: { _, work in work() }
)
var aliyunTranscriptionNetworkError: AISubtitleError?
aliyunNetworkTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                         timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                         format: .wav16kMono),
                                     request: request) {
  if case .failure(let error) = $0 { aliyunTranscriptionNetworkError = error }
}
expect(aliyunTranscriptionNetworkError?.code == "cloud_network_failed"
       && aliyunNetworkPublisher.publishCount == 1
       && aliyunNetworkPublisher.revokedURLs == [aliyunNetworkPublisher.publishedURL]
       && aliyunNetworkTransport.requests.count == 1,
       "Aliyun submission failure should surface the network error and revoke published audio")
let aliyunNetworkTranslator = AliyunAISubtitleTranslator(
  credentialProvider: aliyunCredentials,
  consentChecker: TestConsent(providers: [.aliyun]),
  transport: aliyunNetworkTransport
)
var aliyunTranslationNetworkError: AISubtitleError?
aliyunNetworkTranslator.translate(transcript, request: request) {
  if case .failure(let error) = $0 { aliyunTranslationNetworkError = error }
}
expect(aliyunTranslationNetworkError?.code == "cloud_network_failed"
       && aliyunNetworkTransport.requests.count == 2,
       "Aliyun translation should surface a recoverable network failure")
aliyunNetworkTranscriber.cancelAll()
aliyunNetworkTranslator.cancelAll()
expect(aliyunNetworkTransport.tasks.allSatisfy({ !$0.isCanceled }),
       "Completed Aliyun network failures should be released from cancellation tracking")
let uploadCredential = """
{"data":{"policy":"policy","signature":"signature","upload_dir":"dashscope-instant/test/path","upload_host":"https://upload.example","oss_access_key_id":"temporary-id","x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"}}
""".data(using: .utf8)!
let transcriptionResult = """
{"transcripts":[{"sentences":[{"begin_time":500,"end_time":2000,"text":" aliyun hello ","sentence_id":1}]}]}
""".data(using: .utf8)!
let aliyunTransport = TestHTTPTransport { request in
  switch request.url!.host {
  case "dashscope.aliyuncs.com" where request.url!.path == "/api/v1/uploads":
    return TestHTTPTransport.response(for: request, data: uploadCredential)
  case "upload.example":
    return TestHTTPTransport.response(for: request)
  case "dashscope.aliyuncs.com" where request.url!.path.contains("/tasks/"):
    return TestHTTPTransport.response(for: request,
                                      data: "{\"output\":{\"task_status\":\"SUCCEEDED\",\"results\":[{\"subtask_status\":\"SUCCEEDED\",\"transcription_url\":\"https://result.example/result.json\"}]}}".data(using: .utf8)!)
  case "dashscope.aliyuncs.com":
    return TestHTTPTransport.response(for: request,
                                      data: "{\"output\":{\"task_id\":\"task-1\"}}".data(using: .utf8)!)
  case "result.example":
    return TestHTTPTransport.response(for: request, data: transcriptionResult)
  default:
    return .failure(AISubtitleError(code: "unexpected_request", message: request.url!.absoluteString))
  }
}
let temporaryPublisher = DashScopeTemporaryAISubtitleAliyunAudioPublisher(
  credentialProvider: aliyunCredentials,
  transport: aliyunTransport
)
let aliyunTranscriber = AliyunAISubtitleTranscriber(
  credentialProvider: aliyunCredentials,
  consentChecker: TestConsent(providers: [.aliyun]),
  publisher: temporaryPublisher,
  transport: aliyunTransport,
  pollInterval: 0,
  delay: { _, work in work() }
)
var aliyunSegments: [AISubtitleSegment] = []
aliyunTranscriber.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                  timeRange: AISubtitleTimeRange(start: 100, end: 160),
                                                  format: .wav16kMono),
                              request: request) {
  if case .success(let segments) = $0 { aliyunSegments = segments }
}
let aliyunSubmitRequest = aliyunTransport.requests.first {
  $0.url?.path.contains("/audio/asr/transcription") == true
}
let aliyunUploadBody = aliyunTransport.requests.first { $0.url?.host == "upload.example" }?.httpBody
expect(aliyunSegments.first?.timeRange == AISubtitleTimeRange(start: 100.5, end: 102) &&
       aliyunSubmitRequest?.value(forHTTPHeaderField: "X-DashScope-OssResourceResolve") == "enable",
       "Aliyun temporary upload should feed an OSS URL into Paraformer")
expect(aliyunUploadBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("name=\"file\"") == true,
       "Aliyun temporary upload should send the WAV as multipart form data")
aliyunTranscriber.cancelAll()
expect(aliyunTransport.tasks.allSatisfy({ !$0.isCanceled }),
       "Completed Aliyun HTTP tasks should be released instead of retained for later cancellation")

let modelSource = tempRoot.appendingPathComponent("ggml-test.bin")
let modelDirectory = tempRoot.appendingPathComponent("models", isDirectory: true)
try Data(repeating: 0, count: 1_048_576).write(to: modelSource)
let modelManager = AISubtitleWhisperModelManager(modelsDirectoryURL: modelDirectory)
let model = try modelManager.importModel(from: modelSource,
                                         expectedSHA256: "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58")
let secondModelSource = tempRoot.appendingPathComponent("ggml-test-second.bin")
try Data(repeating: 1, count: 1_048_576).write(to: secondModelSource)
let secondModel = try modelManager.importModel(from: secondModelSource)
let modelDefaultsSuite = "ai-subtitle-model-test-\(UUID().uuidString)"
let modelDefaults = UserDefaults(suiteName: modelDefaultsSuite)!
defer { modelDefaults.removePersistentDomain(forName: modelDefaultsSuite) }
try modelManager.select(secondModel, userDefaults: modelDefaults)
expect(modelManager.selectedModel(userDefaults: modelDefaults)?.url.standardizedFileURL == secondModel.url.standardizedFileURL,
       "The selected whisper.cpp model should persist independently of inventory order")
let whisperJSON = """
{"result":{"language":"en"},"transcription":[{"offsets":{"from":500,"to":2000},"text":" local hello "}]}
""".data(using: .utf8)!
let whisperRunner = TestWhisperRunner(outputJSON: whisperJSON)
let missingModelWhisper = WhisperCppAISubtitleTranscriber(
  installation: AISubtitleWhisperInstallation(executableURL: tempRoot.appendingPathComponent("whisper-cli"),
                                               selectedModel: nil),
  runner: whisperRunner
)
expect(missingModelWhisper.capability(for: request).status == .needsDownload,
       "whisper.cpp should report a missing model before a local process is launched")
var missingModelError: AISubtitleError?
missingModelWhisper.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                                    timeRange: AISubtitleTimeRange(start: 0, end: 1),
                                                    format: .wav16kMono),
                                request: request) {
  if case .failure(let error) = $0 { missingModelError = error }
}
expect(missingModelError?.code == "whisper_assets_required" && whisperRunner.arguments.isEmpty,
       "whisper.cpp should fail without launching a process when no model is selected")
let whisper = WhisperCppAISubtitleTranscriber(
  installation: AISubtitleWhisperInstallation(executableURL: tempRoot.appendingPathComponent("whisper-cli"),
                                               selectedModel: model),
  runner: whisperRunner
)
var whisperSegments: [AISubtitleSegment] = []
whisper.transcribe(AISubtitleAudioChunk(url: deniedAudioURL,
                                       timeRange: AISubtitleTimeRange(start: 100, end: 160),
                                       format: .wav16kMono),
                   request: request) {
  if case .success(let segments) = $0 { whisperSegments = segments }
}
expect(whisperSegments.first?.timeRange == AISubtitleTimeRange(start: 100.5, end: 102) &&
       whisperRunner.arguments.contains("-oj"),
       "whisper.cpp JSON offsets should map to the media timeline")
whisper.cancelAll()
expect(whisperRunner.cancelCount == 1, "whisper.cpp cancellation should reach the process runner")
let realProcessRunner = AISubtitleWhisperProcessRunner(
  queue: DispatchQueue(label: "AISubtitleWhisperProcessCancellationTest")
)
let processCanceled = DispatchSemaphore(value: 0)
realProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"),
                      arguments: ["10"]) { _ in
  processCanceled.signal()
}
Thread.sleep(forTimeInterval: 0.05)
realProcessRunner.cancelAll()
expect(processCanceled.wait(timeout: .now() + 2) == .success,
       "Canceling whisper.cpp should terminate a real child process promptly")
try modelManager.remove(secondModel)
try modelManager.remove(model)
expect(modelManager.installedModels().isEmpty,
       "Managed whisper.cpp models should be removable")

print("AI subtitle self-tests passed")
