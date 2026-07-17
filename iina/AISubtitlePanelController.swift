//
//  AISubtitlePanelController.swift
//  iina
//
//  Created by Codex on 2026/7/16.
//

import Cocoa
import SwiftUI
import Translation

extension Notification.Name {
  static let iinaAISubtitleStateDidChange = Notification.Name("IINAAISubtitleStateDidChange")
}

final class AISubtitlePanelController: NSWindowController {
  private enum Provider: Int, CaseIterable {
    case apple
    case openAI
    case aliyun
    case whisperCpp

    var providerID: AISubtitleProviderID {
      switch self {
      case .apple: return .apple
      case .openAI: return .openAI
      case .aliyun: return .aliyun
      case .whisperCpp: return .whisperCpp
      }
    }
  }

  private struct LanguageOption {
    var code: String?
    var fallbackTitle: String

    var title: String {
      guard let code = code else {
        return aiSubtitleLocalized("subencoding.auto", fallback: fallbackTitle)
      }
      let interfaceLanguage = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
      return Locale(identifier: interfaceLanguage).localizedString(forIdentifier: code) ?? fallbackTitle
    }
  }

  private static let sourceLanguages = [
    LanguageOption(code: nil, fallbackTitle: "Auto Detect"),
    LanguageOption(code: "zh-Hans", fallbackTitle: "Chinese (Simplified)"),
    LanguageOption(code: "zh-Hant", fallbackTitle: "Chinese (Traditional)"),
    LanguageOption(code: "en", fallbackTitle: "English"),
    LanguageOption(code: "ja", fallbackTitle: "Japanese"),
    LanguageOption(code: "ko", fallbackTitle: "Korean"),
    LanguageOption(code: "es", fallbackTitle: "Spanish"),
    LanguageOption(code: "fr", fallbackTitle: "French"),
    LanguageOption(code: "de", fallbackTitle: "German"),
    LanguageOption(code: "ru", fallbackTitle: "Russian"),
    LanguageOption(code: "pt", fallbackTitle: "Portuguese"),
    LanguageOption(code: "ar", fallbackTitle: "Arabic")
  ]
  private static let targetLanguages = sourceLanguages.dropFirst()

  private unowned let player: PlayerCore
  private let defaults = UserDefaults.standard
  private let providerControl = NSSegmentedControl(labels: ["Apple", "OpenAI", "Aliyun", "whisper.cpp"],
                                                   trackingMode: .selectOne,
                                                   target: nil,
                                                   action: nil)
  private let sourcePopup = NSPopUpButton()
  private let targetPopup = NSPopUpButton()
  private let appleFallbackPopup = NSPopUpButton()
  private let translatorPopup = NSPopUpButton()
  private let whisperModelPopup = NSPopUpButton()
  private let consentButton = NSButton(checkboxWithTitle: "Allow cloud upload for AI subtitles",
                                       target: nil,
                                       action: nil)
  private let openAIKeyField = NSSecureTextField()
  private let aliyunDashScopeField = NSSecureTextField()
  private let aliyunAccessKeyIDField = NSTextField()
  private let aliyunAccessKeySecretField = NSSecureTextField()
  private let cloudFieldsStack = NSStackView()
  private let appleAssetsStack = NSStackView()
  private let localAssetsStack = NSStackView()
  private let estimateLabel = NSTextField(labelWithString: "")
  private let cacheLimitPopup = NSPopUpButton()
  private let statusLabel = NSTextField(wrappingLabelWithString: "Idle")
  private let progressIndicator = NSProgressIndicator()
  private let generateButton = NSButton(title: aiSubtitleLocalized("ai_subtitle.generate", fallback: "Generate"), target: nil, action: nil)
  private let stopButton = NSButton(title: aiSubtitleLocalized("ai_subtitle.stop_short", fallback: "Stop"), target: nil, action: nil)
  private let exportButton = NSButton(title: aiSubtitleLocalized("ai_subtitle.export", fallback: "Export…"), target: nil, action: nil)
  private var appleTranslationPreparationWindow: NSWindow?

  init(player: PlayerCore) {
    self.player = player
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
    window.title = aiSubtitleLocalized("ai_subtitle.title", fallback: "AI Subtitles")
    window.isReleasedWhenClosed = false
    super.init(window: window)
    buildUI()
    restoreSelections()
    refreshControls(syncCloudConsent: true)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(stateDidChange(_:)),
                                           name: .iinaAISubtitleStateDidChange,
                                           object: player)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func present() {
    guard let window = window else { return }
    refreshControls(syncCloudConsent: true)
    if window.sheetParent != nil {
      window.makeKeyAndOrderFront(self)
    } else if let parent = player.currentWindow {
      parent.beginSheet(window)
    } else {
      showWindow(self)
    }
  }

  private func buildUI() {
    guard let contentView = window?.contentView else { return }
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 14
    root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
    root.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      root.topAnchor.constraint(equalTo: contentView.topAnchor),
      root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    ])

    let title = NSTextField(labelWithString: aiSubtitleLocalized("ai_subtitle.title", fallback: "AI Subtitles"))
    title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    root.addArrangedSubview(title)

    providerControl.segmentStyle = .rounded
    providerControl.selectedSegment = 0
    providerControl.target = self
    providerControl.action = #selector(providerChanged(_:))
    providerControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
    root.addArrangedSubview(providerControl)
    providerControl.widthAnchor.constraint(equalTo: root.widthAnchor,
                                           constant: -root.edgeInsets.left - root.edgeInsets.right).isActive = true

    configureLanguagePopup(sourcePopup, options: Self.sourceLanguages)
    configureLanguagePopup(targetPopup, options: Array(Self.targetLanguages))
    sourcePopup.target = self
    sourcePopup.action = #selector(selectionChanged(_:))
    targetPopup.target = self
    targetPopup.action = #selector(selectionChanged(_:))
    let languageGrid = NSGridView(views: [
      [NSTextField(labelWithString: aiSubtitleLocalized("ai_subtitle.spoken_language", fallback: "Spoken language")), sourcePopup],
      [NSTextField(labelWithString: aiSubtitleLocalized("ai_subtitle.subtitle_language", fallback: "Subtitle language")), targetPopup]
    ])
    languageGrid.rowSpacing = 10
    languageGrid.columnSpacing = 16
    languageGrid.column(at: 0).xPlacement = .trailing
    languageGrid.column(at: 1).xPlacement = .fill
    root.addArrangedSubview(languageGrid)
    languageGrid.widthAnchor.constraint(equalTo: providerControl.widthAnchor).isActive = true

    appleFallbackPopup.addItem(withTitle: aiSubtitleLocalized("ai_subtitle.fallback_ask", fallback: "Ask"))
    for providerID in [AISubtitleProviderID.openAI, .aliyun, .whisperCpp] {
      let item = NSMenuItem(title: providerID.displayName, action: nil, keyEquivalent: "")
      item.representedObject = providerID.rawValue
      appleFallbackPopup.menu?.addItem(item)
    }
    appleFallbackPopup.target = self
    appleFallbackPopup.action = #selector(providerChanged(_:))
    let fallbackRow = horizontalRow(label: aiSubtitleLocalized("ai_subtitle.apple_fallback", fallback: "If Apple is unavailable"),
                                    control: appleFallbackPopup)
    fallbackRow.identifier = NSUserInterfaceItemIdentifier("appleFallbackRow")
    root.addArrangedSubview(fallbackRow)

    translatorPopup.addItems(withTitles: ["Apple", "OpenAI", "Aliyun"])
    translatorPopup.target = self
    translatorPopup.action = #selector(providerChanged(_:))
    let translatorRow = horizontalRow(label: aiSubtitleLocalized("ai_subtitle.translate_with", fallback: "Translate with"), control: translatorPopup)
    translatorRow.identifier = NSUserInterfaceItemIdentifier("whisperTranslatorRow")
    root.addArrangedSubview(translatorRow)

    appleAssetsStack.orientation = .horizontal
    appleAssetsStack.spacing = 8
    let prepareAppleAssets = NSButton(title: aiSubtitleLocalized("ai_subtitle.prepare_apple_languages",
                                                                  fallback: "Prepare Apple Languages…"),
                                      target: self,
                                      action: #selector(prepareAppleLanguages(_:)))
    appleAssetsStack.addArrangedSubview(prepareAppleAssets)
    root.addArrangedSubview(appleAssetsStack)

    cloudFieldsStack.orientation = .vertical
    cloudFieldsStack.alignment = .leading
    cloudFieldsStack.spacing = 8
    openAIKeyField.placeholderString = "OpenAI API key (leave blank to keep saved key)"
    aliyunDashScopeField.placeholderString = "Model Studio API key"
    aliyunAccessKeyIDField.placeholderString = "Machine Translation AccessKey ID"
    aliyunAccessKeySecretField.placeholderString = "Machine Translation AccessKey Secret"
    [openAIKeyField, aliyunDashScopeField, aliyunAccessKeyIDField, aliyunAccessKeySecretField].forEach {
      $0.widthAnchor.constraint(equalToConstant: 496).isActive = true
      cloudFieldsStack.addArrangedSubview($0)
    }
    consentButton.target = self
    consentButton.action = #selector(consentChanged(_:))
    cloudFieldsStack.addArrangedSubview(consentButton)
    let removeCredentials = NSButton(title: aiSubtitleLocalized("ai_subtitle.remove_credentials",
                                                                 fallback: "Remove Saved Credentials…"),
                                     target: self,
                                     action: #selector(removeCloudCredentials(_:)))
    cloudFieldsStack.addArrangedSubview(removeCredentials)
    root.addArrangedSubview(cloudFieldsStack)

    localAssetsStack.orientation = .vertical
    localAssetsStack.spacing = 8
    let importExecutable = NSButton(title: "Import whisper-cli…",
                                    target: self,
                                    action: #selector(importWhisperExecutable(_:)))
    let importModel = NSButton(title: "Import Model…",
                               target: self,
                               action: #selector(importWhisperModel(_:)))
    whisperModelPopup.target = self
    whisperModelPopup.action = #selector(whisperModelChanged(_:))
    whisperModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    let deleteModel = NSButton(title: aiSubtitleLocalized("ai_subtitle.delete_model", fallback: "Delete Model…"),
                               target: self,
                               action: #selector(deleteWhisperModel(_:)))
    let importRow = NSStackView(views: [importExecutable, importModel])
    importRow.orientation = .horizontal
    importRow.spacing = 8
    let modelRow = NSStackView(views: [whisperModelPopup, deleteModel])
    modelRow.orientation = .horizontal
    modelRow.spacing = 8
    localAssetsStack.addArrangedSubview(importRow)
    localAssetsStack.addArrangedSubview(modelRow)
    root.addArrangedSubview(localAssetsStack)
    refreshWhisperModels()

    estimateLabel.textColor = .secondaryLabelColor
    estimateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                           weight: .regular)
    root.addArrangedSubview(estimateLabel)

    let cacheLimits: [(String, Int64)] = [
      ("512 MB", 512 * 1024 * 1024),
      ("1 GB", 1024 * 1024 * 1024),
      ("2 GB", 2 * 1024 * 1024 * 1024),
      ("5 GB", 5 * 1024 * 1024 * 1024),
      ("10 GB", 10 * 1024 * 1024 * 1024)
    ]
    for (title, bytes) in cacheLimits {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.representedObject = NSNumber(value: bytes)
      cacheLimitPopup.menu?.addItem(item)
    }
    let configuredLimit = AISubtitleCachePolicy().maximumBytes
    let selectedLimit = cacheLimitPopup.itemArray.firstIndex {
      ($0.representedObject as? NSNumber)?.int64Value == configuredLimit
    } ?? 2
    cacheLimitPopup.selectItem(at: selectedLimit)
    cacheLimitPopup.target = self
    cacheLimitPopup.action = #selector(cacheLimitChanged(_:))
    let clearCacheButton = NSButton(title: aiSubtitleLocalized("ai_subtitle.clear_inactive_cache", fallback: "Clear Inactive Cache"),
                                    target: self,
                                    action: #selector(clearCache(_:)))
    let cacheControls = NSStackView(views: [cacheLimitPopup, clearCacheButton])
    cacheControls.orientation = .horizontal
    cacheControls.spacing = 8
    root.addArrangedSubview(horizontalRow(label: aiSubtitleLocalized("ai_subtitle.cache_limit", fallback: "Cache limit"), control: cacheControls))

    let separator = NSBox()
    separator.boxType = .separator
    root.addArrangedSubview(separator)
    separator.widthAnchor.constraint(equalTo: providerControl.widthAnchor).isActive = true

    progressIndicator.style = .bar
    progressIndicator.isIndeterminate = true
    progressIndicator.isDisplayedWhenStopped = false
    progressIndicator.controlSize = .small
    root.addArrangedSubview(progressIndicator)
    progressIndicator.widthAnchor.constraint(equalTo: providerControl.widthAnchor).isActive = true

    statusLabel.maximumNumberOfLines = 2
    statusLabel.lineBreakMode = .byTruncatingTail
    root.addArrangedSubview(statusLabel)
    statusLabel.widthAnchor.constraint(equalTo: providerControl.widthAnchor).isActive = true

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8
    let closeButton = NSButton(title: aiSubtitleLocalized("ai_subtitle.close", fallback: "Close"), target: self, action: #selector(closePanel(_:)))
    generateButton.target = self
    generateButton.action = #selector(generate(_:))
    generateButton.keyEquivalent = "\r"
    stopButton.target = self
    stopButton.action = #selector(stop(_:))
    exportButton.target = self
    exportButton.action = #selector(export(_:))
    buttons.addArrangedSubview(closeButton)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    buttons.addArrangedSubview(spacer)
    buttons.addArrangedSubview(exportButton)
    buttons.addArrangedSubview(stopButton)
    buttons.addArrangedSubview(generateButton)
    root.addArrangedSubview(buttons)
    buttons.widthAnchor.constraint(equalTo: providerControl.widthAnchor).isActive = true
  }

  private func configureLanguagePopup(_ popup: NSPopUpButton, options: [LanguageOption]) {
    for option in options {
      let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
      item.representedObject = option.code
      popup.menu?.addItem(item)
    }
  }

  private func horizontalRow(label: String, control: NSView) -> NSStackView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 16
    let labelView = NSTextField(labelWithString: label)
    labelView.alignment = .right
    labelView.widthAnchor.constraint(equalToConstant: 150).isActive = true
    row.addArrangedSubview(labelView)
    row.addArrangedSubview(control)
    return row
  }

  private func restoreSelections() {
    let savedProvider: Int
    if defaults.object(forKey: "aiSubtitle.provider") != nil {
      savedProvider = defaults.integer(forKey: "aiSubtitle.provider")
    } else {
      switch player.recommendedAISubtitleProviderID {
      case .apple: savedProvider = Provider.apple.rawValue
      case .openAI: savedProvider = Provider.openAI.rawValue
      case .aliyun: savedProvider = Provider.aliyun.rawValue
      case .whisperCpp: savedProvider = Provider.whisperCpp.rawValue
      }
    }
    providerControl.selectedSegment = Provider(rawValue: savedProvider) == nil ? 0 : savedProvider
    let detectedSource = player.info.currentTrack(.audio)?.lang
    selectLanguage(detectedSource ?? defaults.string(forKey: "aiSubtitle.sourceLanguage"), in: sourcePopup)
    selectLanguage(defaults.string(forKey: "aiSubtitle.targetLanguage")
      ?? Locale.preferredLanguages.first,
                   in: targetPopup)
    translatorPopup.selectItem(at: min(max(defaults.integer(forKey: "aiSubtitle.whisperTranslator"), 0), 2))
    if let fallbackRawValue = defaults.string(forKey: "aiSubtitle.appleFallbackProvider"),
       let index = appleFallbackPopup.itemArray.firstIndex(where: {
         $0.representedObject as? String == fallbackRawValue
       }) {
      appleFallbackPopup.selectItem(at: index)
    } else {
      appleFallbackPopup.selectItem(at: 0)
    }
  }

  private func selectLanguage(_ code: String?, in popup: NSPopUpButton) {
    guard let code = code else {
      popup.selectItem(at: 0)
      return
    }
    let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
    let exact = popup.itemArray.firstIndex {
      ($0.representedObject as? String)?.lowercased() == normalized
    }
    let primary = popup.itemArray.firstIndex {
      guard let itemCode = $0.representedObject as? String else { return false }
      return itemCode.lowercased().split(separator: "-").first == normalized.split(separator: "-").first
    }
    popup.selectItem(at: exact ?? primary ?? 0)
  }

  @objc private func selectionChanged(_ sender: Any?) {
    refreshControls()
  }

  @objc private func providerChanged(_ sender: Any?) {
    refreshControls(syncCloudConsent: true)
  }

  @objc private func consentChanged(_ sender: Any?) {
    refreshControls()
  }

  private func refreshControls(syncCloudConsent: Bool = false) {
    let provider = selectedProvider
    let cloudProviderID = selectedCloudProviderID
    openAIKeyField.isHidden = cloudProviderID != .openAI
    aliyunDashScopeField.isHidden = cloudProviderID != .aliyun
    aliyunAccessKeyIDField.isHidden = cloudProviderID != .aliyun
    aliyunAccessKeySecretField.isHidden = cloudProviderID != .aliyun
    cloudFieldsStack.isHidden = cloudProviderID == nil
    appleAssetsStack.isHidden = provider != .apple
    localAssetsStack.isHidden = provider != .whisperCpp
    let translationRequired = selectedSourceLanguage.map {
      !$0.isEquivalent(to: selectedTargetLanguage)
    } ?? true
    let whisperTranslation = provider == .whisperCpp
      || (provider == .apple && selectedAppleFallbackProviderID == .whisperCpp)
    window?.contentView?.findView(withIdentifier: "appleFallbackRow")?.isHidden = provider != .apple
    window?.contentView?.findView(withIdentifier: "whisperTranslatorRow")?.isHidden = !whisperTranslation || !translationRequired

    if let cloudProviderID = cloudProviderID {
      if syncCloudConsent {
        let consent = UserDefaultsAISubtitleCloudConsentStore().hasConsent(for: cloudProviderID)
        consentButton.state = consent ? .on : .off
      }
      consentButton.title = cloudProviderID == .aliyun
        ? aiSubtitleLocalized("ai_subtitle.aliyun_upload_consent",
                              fallback: "Upload audio (kept up to 48h) and subtitle text to Aliyun")
        : aiSubtitleLocalized("ai_subtitle.openai_upload_consent",
                              fallback: "Allow uploading audio and subtitle text to OpenAI")
    }
    estimateLabel.stringValue = estimateText(for: provider)
    updateState(player.aiSubtitleState)
  }

  private func estimateText(for provider: Provider) -> String {
    let duration = player.info.videoDuration?.second ?? 0
    switch provider {
    case .apple:
      switch selectedAppleFallbackProviderID {
      case .openAI:
        let estimate = AISubtitleOpenAIPricing().transcriptionEstimate(duration: duration)
        return "On-device primary · OpenAI fallback up to \(estimate.currencyCode) \(decimalString(estimate.amount))"
      case .aliyun:
        let estimate = AISubtitleAliyunPricing().transcriptionEstimate(duration: duration)
        return "On-device primary · Aliyun fallback up to \(estimate.currencyCode) \(decimalString(estimate.amount))"
      case .whisperCpp:
        return "On-device primary · whisper.cpp fallback"
      case .apple, .none:
        return "On-device · no provider fee"
      }
    case .whisperCpp:
      let installation = AISubtitleWhisperInstallation.discover()
      let model = installation.selectedModel?.name ?? "model not installed"
      return "On-device · \(model)"
    case .openAI:
      let estimate = AISubtitleOpenAIPricing().transcriptionEstimate(duration: duration)
      return "Estimated transcription: \(estimate.currencyCode) \(decimalString(estimate.amount)) · translation additional"
    case .aliyun:
      let estimate = AISubtitleAliyunPricing().transcriptionEstimate(duration: duration)
      return "Estimated transcription: \(estimate.currencyCode) \(decimalString(estimate.amount)) · temporary audio storage included"
    }
  }

  private func decimalString(_ decimal: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 4
    return formatter.string(from: decimal as NSDecimalNumber) ?? "0"
  }

  @objc private func generate(_ sender: NSButton) {
    let provider = selectedProvider
    let sourceLanguage = selectedSourceLanguage
    let targetLanguage = selectedTargetLanguage
    defaults.set(provider.rawValue, forKey: "aiSubtitle.provider")
    defaults.set(sourceLanguage?.code, forKey: "aiSubtitle.sourceLanguage")
    defaults.set(targetLanguage.code, forKey: "aiSubtitle.targetLanguage")
    defaults.set(translatorPopup.indexOfSelectedItem, forKey: "aiSubtitle.whisperTranslator")
    defaults.set(selectedAppleFallbackProviderID?.rawValue, forKey: "aiSubtitle.appleFallbackProvider")

    do {
      let credentials = AISubtitleCloudCredentialStore()
      let cloudProviderID = selectedCloudProviderID
      if cloudProviderID == .openAI, !openAIKeyField.stringValue.isEmpty {
        try credentials.saveOpenAIAPIKey(openAIKeyField.stringValue)
        openAIKeyField.stringValue = ""
      }
      if cloudProviderID == .aliyun {
        if !aliyunDashScopeField.stringValue.isEmpty {
          try credentials.saveAliyunDashScopeAPIKey(aliyunDashScopeField.stringValue)
          aliyunDashScopeField.stringValue = ""
        }
        if !aliyunAccessKeyIDField.stringValue.isEmpty || !aliyunAccessKeySecretField.stringValue.isEmpty {
          guard !aliyunAccessKeyIDField.stringValue.isEmpty,
                !aliyunAccessKeySecretField.stringValue.isEmpty else {
            throw AISubtitleError(code: "aliyun_credentials_incomplete",
                                  message: "Enter both Machine Translation AccessKey fields.")
          }
          try credentials.saveAliyunMachineTranslation(accessKeyID: aliyunAccessKeyIDField.stringValue,
                                                        accessKeySecret: aliyunAccessKeySecretField.stringValue)
          aliyunAccessKeyIDField.stringValue = ""
          aliyunAccessKeySecretField.stringValue = ""
        }
      }
    } catch {
      statusLabel.stringValue = error.localizedDescription
      return
    }

    if let cloudProviderID = selectedCloudProviderID {
      UserDefaultsAISubtitleCloudConsentStore().setConsent(consentButton.state == .on,
                                                           for: cloudProviderID)
    }
    switch provider {
    case .apple:
      guard let sourceLanguage = sourceLanguage else {
        statusLabel.stringValue = "Choose the spoken language for Apple transcription."
        return
      }
      let fallbackTranslatorID: AISubtitleProviderID? = selectedAppleFallbackProviderID == .whisperCpp
        ? [.apple, .openAI, .aliyun][translatorPopup.indexOfSelectedItem]
        : nil
      player.startAppleAISubtitles(sourceLanguage: sourceLanguage,
                                   targetLanguage: targetLanguage,
                                   fallbackProviderID: selectedAppleFallbackProviderID,
                                   fallbackTranslatorProviderID: fallbackTranslatorID)
    case .openAI, .aliyun:
      player.startCloudAISubtitles(providerID: provider.providerID,
                                   sourceLanguage: sourceLanguage,
                                   targetLanguage: targetLanguage)
    case .whisperCpp:
      let translatorID: AISubtitleProviderID?
      if sourceLanguage?.isEquivalent(to: targetLanguage) == true {
        translatorID = nil
      } else {
        translatorID = [.apple, .openAI, .aliyun][translatorPopup.indexOfSelectedItem]
      }
      player.startWhisperAISubtitles(sourceLanguage: sourceLanguage,
                                     targetLanguage: targetLanguage,
                                     translatorProviderID: translatorID)
    }
    refreshControls()
  }

  @objc private func stop(_ sender: NSButton) {
    player.stopAISubtitles()
  }

  @objc private func export(_ sender: NSButton) {
    let menu = NSMenu()
    menu.addItem(withTitle: "WebVTT", action: #selector(exportWebVTT(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "SRT", action: #selector(exportSRT(_:)), keyEquivalent: "")
    menu.items.forEach { $0.target = self }
    menu.popUp(positioning: nil,
               at: NSPoint(x: 0, y: sender.bounds.height + 4),
               in: sender)
  }

  @objc private func exportWebVTT(_ sender: NSMenuItem) {
    dismissAndExport(format: .webVTT)
  }

  @objc private func exportSRT(_ sender: NSMenuItem) {
    dismissAndExport(format: .srt)
  }

  private func dismissAndExport(format: AISubtitleFileFormat) {
    guard let window = window else {
      player.exportAISubtitles(format: format)
      return
    }
    if let parent = window.sheetParent {
      parent.endSheet(window)
    } else {
      close()
    }
    DispatchQueue.main.async { [weak self] in
      self?.player.exportAISubtitles(format: format)
    }
  }

  @objc private func closePanel(_ sender: NSButton) {
    guard let window = window else { return }
    if let parent = window.sheetParent {
      parent.endSheet(window)
    } else {
      close()
    }
  }

  @objc private func importWhisperExecutable(_ sender: NSButton) {
    Utility.quickOpenPanel(title: "Choose whisper-cli",
                           chooseDir: false,
                           sheetWindow: window) { url in
      do {
        _ = try AISubtitleWhisperExecutableManager().importExecutable(from: url)
        self.statusLabel.stringValue = "whisper-cli imported."
        self.refreshControls()
      } catch {
        self.statusLabel.stringValue = error.localizedDescription
      }
    }
  }

  @objc private func prepareAppleLanguages(_ sender: NSButton) {
    guard #available(macOS 26.0, *),
          let sourceLanguage = selectedSourceLanguage else {
      statusLabel.stringValue = "Apple language preparation requires macOS 26 and a chosen spoken language."
      return
    }
    let targetLanguage = selectedTargetLanguage
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = aiSubtitleLocalized("ai_subtitle.apple_download_title",
                                            fallback: "Download Apple Language Resources?")
    alert.informativeText = aiSubtitleLocalized(
      "ai_subtitle.apple_download_message",
      fallback: "macOS may download on-device speech and translation resources for the selected languages."
    )
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.continue", fallback: "Continue"))
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.cancel", fallback: "Cancel"))
    guard let window = window else { return }
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.installAppleSpeechAssets(sourceLanguage: sourceLanguage,
                                     targetLanguage: targetLanguage)
    }
  }

  @available(macOS 26.0, *)
  private func installAppleSpeechAssets(sourceLanguage: AISubtitleLanguage,
                                        targetLanguage: AISubtitleLanguage) {
    progressIndicator.startAnimation(self)
    statusLabel.stringValue = "Preparing Apple speech resources…"
    AppleAISubtitleTranscriber().installAssets(language: sourceLanguage,
                                               progressHandler: { [weak self] progress in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.progressIndicator.isIndeterminate = false
        self.progressIndicator.observedProgress = progress
        self.progressIndicator.startAnimation(self)
        self.statusLabel.stringValue = "Downloading Apple speech resources…"
      }
    }, completion: { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.progressIndicator.observedProgress = nil
        self.progressIndicator.isIndeterminate = true
        switch result {
        case .failure(let error):
          self.progressIndicator.stopAnimation(self)
          self.statusLabel.stringValue = error.message
        case .success:
          if sourceLanguage.isEquivalent(to: targetLanguage) {
            self.progressIndicator.stopAnimation(self)
            self.statusLabel.stringValue = "Apple speech resources are ready."
          } else {
            self.presentAppleTranslationPreparation(sourceLanguage: sourceLanguage,
                                                    targetLanguage: targetLanguage)
          }
        }
      }
    })
  }

  @available(macOS 26.0, *)
  private func presentAppleTranslationPreparation(sourceLanguage: AISubtitleLanguage,
                                                  targetLanguage: AISubtitleLanguage) {
    guard let parent = window else { return }
    let preparationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                                     styleMask: [.titled],
                                     backing: .buffered,
                                     defer: false)
    preparationWindow.title = aiSubtitleLocalized("ai_subtitle.preparing_languages",
                                                  fallback: "Preparing Languages")
    let view = AppleTranslationPreparationView(sourceLanguage: sourceLanguage,
                                               targetLanguage: targetLanguage) { [weak self, weak preparationWindow] result in
      guard let self = self else { return }
      if let preparationWindow = preparationWindow, preparationWindow.sheetParent != nil {
        parent.endSheet(preparationWindow)
      }
      self.appleTranslationPreparationWindow = nil
      self.progressIndicator.stopAnimation(self)
      switch result {
      case .success:
        self.statusLabel.stringValue = "Apple speech and translation resources are ready."
      case .failure(let error):
        self.statusLabel.stringValue = error.message
      }
    }
    preparationWindow.contentView = NSHostingView(rootView: view)
    appleTranslationPreparationWindow = preparationWindow
    parent.beginSheet(preparationWindow)
  }

  @objc private func cacheLimitChanged(_ sender: NSPopUpButton) {
    let maximumBytes = (sender.selectedItem?.representedObject as? NSNumber)?.int64Value
      ?? AISubtitleCachePolicy.defaultMaximumBytes
    defaults.set(maximumBytes, forKey: AISubtitleCachePolicy.maximumBytesDefaultsKey)
    pruneCache(maximumBytes: maximumBytes)
  }

  @objc private func removeCloudCredentials(_ sender: NSButton) {
    guard let providerID = selectedCloudProviderID, let window = window else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = aiSubtitleLocalized("ai_subtitle.remove_credentials_title",
                                            fallback: "Remove Saved Cloud Credentials?")
    alert.informativeText = String(format: aiSubtitleLocalized("ai_subtitle.remove_credentials_message",
                                                               fallback: "Remove the saved credentials for %@ from Keychain?"),
                                   providerID.displayName)
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.remove", fallback: "Remove"))
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.cancel", fallback: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self = self else { return }
      do {
        try AISubtitleCloudCredentialStore().removeCredentials(for: providerID)
        UserDefaultsAISubtitleCloudConsentStore().setConsent(false, for: providerID)
        self.consentButton.state = .off
        self.statusLabel.stringValue = "Removed saved \(providerID.displayName) credentials."
      } catch {
        self.statusLabel.stringValue = error.localizedDescription
      }
    }
  }

  @objc private func clearCache(_ sender: NSButton) {
    pruneCache(maximumBytes: 0)
  }

  private func pruneCache(maximumBytes: Int64) {
    do {
      let result = try player.pruneAISubtitleCache(maximumBytes: maximumBytes)
      statusLabel.stringValue = result.removedEntryCount == 0
        ? "No inactive AI subtitle cache needed removal."
        : "Removed \(result.removedEntryCount) cached item(s), freeing \(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))."
    } catch {
      statusLabel.stringValue = error.localizedDescription
    }
  }

  @objc private func importWhisperModel(_ sender: NSButton) {
    Utility.quickOpenPanel(title: "Choose whisper.cpp Model",
                           chooseDir: false,
                           sheetWindow: window,
                           allowedFileTypes: ["bin"]) { url in
      self.progressIndicator.startAnimation(self)
      DispatchQueue.global(qos: .utility).async {
        let result = Result { try AISubtitleWhisperModelManager().importModel(from: url) }
        DispatchQueue.main.async {
          self.progressIndicator.stopAnimation(self)
          switch result {
          case .success(let model):
            try? AISubtitleWhisperModelManager().select(model)
            self.statusLabel.stringValue = "Imported \(model.name)."
          case .failure(let error):
            self.statusLabel.stringValue = error.localizedDescription
          }
          self.refreshControls()
        }
      }
    }
  }

  @objc private func whisperModelChanged(_ sender: NSPopUpButton) {
    guard let model = selectedWhisperModel else { return }
    do {
      try AISubtitleWhisperModelManager().select(model)
      statusLabel.stringValue = "Selected \(model.name)."
      refreshControls()
    } catch {
      statusLabel.stringValue = error.localizedDescription
    }
  }

  @objc private func deleteWhisperModel(_ sender: NSButton) {
    guard let model = selectedWhisperModel, let window = window else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = aiSubtitleLocalized("ai_subtitle.delete_model_title", fallback: "Delete whisper.cpp Model?")
    alert.informativeText = String(format: aiSubtitleLocalized("ai_subtitle.delete_model_message",
                                                               fallback: "Delete %@ from this Mac?"),
                                   model.name)
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.delete", fallback: "Delete"))
    alert.addButton(withTitle: aiSubtitleLocalized("ai_subtitle.cancel", fallback: "Cancel"))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self = self else { return }
      do {
        try AISubtitleWhisperModelManager().remove(model)
        self.statusLabel.stringValue = "Deleted \(model.name)."
        self.refreshWhisperModels()
        self.refreshControls()
      } catch {
        self.statusLabel.stringValue = error.localizedDescription
      }
    }
  }

  private func refreshWhisperModels() {
    let manager = AISubtitleWhisperModelManager()
    let models = manager.installedModels()
    whisperModelPopup.removeAllItems()
    guard !models.isEmpty else {
      whisperModelPopup.addItem(withTitle: aiSubtitleLocalized("ai_subtitle.no_model", fallback: "No model installed"))
      whisperModelPopup.isEnabled = false
      return
    }
    whisperModelPopup.isEnabled = true
    for model in models {
      let item = NSMenuItem(title: "\(model.name) · \(ByteCountFormatter.string(fromByteCount: Int64(model.fileSize), countStyle: .file))",
                            action: nil,
                            keyEquivalent: "")
      item.representedObject = model
      whisperModelPopup.menu?.addItem(item)
    }
    if let selected = manager.selectedModel(),
       let index = models.firstIndex(where: { $0.url.standardizedFileURL == selected.url.standardizedFileURL }) {
      whisperModelPopup.selectItem(at: index)
    }
  }

  private var selectedWhisperModel: AISubtitleWhisperModel? {
    whisperModelPopup.selectedItem?.representedObject as? AISubtitleWhisperModel
  }

  @objc private func stateDidChange(_ notification: Notification) {
    updateState(player.aiSubtitleState)
  }

  private func updateState(_ state: AISubtitleTaskState) {
    let isRunning = ![.idle, .completed, .failed, .canceled, .maintaining].contains(state.phase)
    if isRunning {
      progressIndicator.startAnimation(self)
    } else {
      progressIndicator.stopAnimation(self)
    }
    statusLabel.stringValue = state.error?.message
      ?? state.message
      ?? state.coveredRange.map { "\(state.phase.rawValue.capitalized) · cached through \(timeString($0.end))" }
      ?? state.phase.rawValue.capitalized
    generateButton.isEnabled = !isRunning
      && player.info.currentURL != nil
      && !player.info.audioTracks.isEmpty
    stopButton.isEnabled = isRunning || state.phase == .maintaining
    exportButton.isEnabled = player.hasExportableAISubtitles
  }

  private func timeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
  }

  private var selectedProvider: Provider {
    Provider(rawValue: providerControl.selectedSegment) ?? .apple
  }

  private var selectedSourceLanguage: AISubtitleLanguage? {
    (sourcePopup.selectedItem?.representedObject as? String).map(AISubtitleLanguage.init)
  }

  private var selectedTargetLanguage: AISubtitleLanguage {
    AISubtitleLanguage((targetPopup.selectedItem?.representedObject as? String) ?? "en")
  }

  private var selectedAppleFallbackProviderID: AISubtitleProviderID? {
    guard let rawValue = appleFallbackPopup.selectedItem?.representedObject as? String else { return nil }
    return AISubtitleProviderID(rawValue: rawValue)
  }

  private var selectedCloudProviderID: AISubtitleProviderID? {
    let providerID: AISubtitleProviderID?
    switch selectedProvider {
    case .openAI: providerID = .openAI
    case .aliyun: providerID = .aliyun
    case .apple:
      if selectedAppleFallbackProviderID == .whisperCpp,
         selectedSourceLanguage.map({ !$0.isEquivalent(to: selectedTargetLanguage) }) ?? true {
        providerID = [.apple, .openAI, .aliyun][translatorPopup.indexOfSelectedItem]
      } else {
        providerID = selectedAppleFallbackProviderID
      }
    case .whisperCpp:
      providerID = selectedSourceLanguage.map { $0.isEquivalent(to: selectedTargetLanguage) } == true
        ? nil
        : [.apple, .openAI, .aliyun][translatorPopup.indexOfSelectedItem]
    }
    return providerID?.isCloudProvider == true ? providerID : nil
  }
}

private extension NSView {
  func findView(withIdentifier identifier: String) -> NSView? {
    if self.identifier?.rawValue == identifier { return self }
    for child in subviews {
      if let found = child.findView(withIdentifier: identifier) { return found }
    }
    return nil
  }
}

@available(macOS 26.0, *)
private struct AppleTranslationPreparationView: View {
  let sourceLanguage: AISubtitleLanguage
  let targetLanguage: AISubtitleLanguage
  let completion: (Result<Void, AISubtitleError>) -> Void

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(aiSubtitleLocalized("ai_subtitle.preparing_translation",
                               fallback: "Preparing on-device translation resources…"))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .translationTask(source: Locale.Language(identifier: sourceLanguage.code),
                     target: Locale.Language(identifier: targetLanguage.code)) { session in
      do {
        try await session.prepareTranslation()
        await MainActor.run { completion(.success(())) }
      } catch {
        await MainActor.run {
          completion(.failure(AISubtitleError(code: "apple_translation_asset_installation_failed",
                                              message: error.localizedDescription)))
        }
      }
    }
  }
}
