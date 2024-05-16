//
//  azooKeyMacInputController.swift
//  azooKeyMacInputController
//
//  Created by ensan on 2021/09/07.
//

import OSLog
import Cocoa
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

let applicationLogger: Logger = Logger(subsystem: "dev.ensan.inputmethod.azooKeyMac", category: "main")

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController {
    private var composingText: ComposingText = ComposingText()
    private var selectedCandidate: String?
    private var inputState: InputState = .none
    private var directMode = false
    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    private var englishConversionEnabled: Bool {
        Config.EnglishConversion().value
    }
    private var displayedTextInComposingMode: String?
    private var candidatesWindow: IMKCandidates {
        (
            NSApplication.shared.delegate as? AppDelegate
        )!.candidatesWindow
    }
    @MainActor private var kanaKanjiConverter: KanaKanjiConverter {
        (
            NSApplication.shared.delegate as? AppDelegate
        )!.kanaKanjiConverter
    }
    private var rawCandidates: ConversionResult?
    private let appMenu: NSMenu
    private let liveConversionToggleMenuItem: NSMenuItem
    private let englishConversionToggleMenuItem: NSMenuItem
    private var options: ConvertRequestOptions {
        .withDefaultDictionary(
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: self.englishConversionEnabled,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: self.azooKeyMemoryDir,
            metadata: .init(appVersionString: "1.0")
        )
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        // menu
        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem(title: "ライブ変換をOFF", action: #selector(self.toggleLiveConversion(_:)), keyEquivalent: "")
        self.englishConversionToggleMenuItem = NSMenuItem(title: "英単語変換をON", action: #selector(self.toggleEnglishConversion(_:)), keyEquivalent: "")
        self.appMenu.addItem(self.liveConversionToggleMenuItem)
        self.appMenu.addItem(self.englishConversionToggleMenuItem)
        self.appMenu.addItem(NSMenuItem(title: "詳細設定を開く", action: #selector(self.openConfigWindow(_:)), keyEquivalent: ""))
        self.appMenu.addItem(NSMenuItem(title: "View on GitHub", action: #selector(self.openGitHubRepository(_:)), keyEquivalent: ""))
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // MARK: this is required to move the window front of the spotlight panel
        self.candidatesWindow.perform(
            Selector(("setWindowLevel:")),
            with: Int(max(
                CGShieldingWindowLevel(),
                kCGPopUpMenuWindowLevel
            ))
        )
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateEnglishConversionToggleMenuItem(newValue: self.englishConversionEnabled)
        self.kanaKanjiConverter.sendToDicdataStore(.setRequestOptions(options))
        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.US")
        }
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.kanaKanjiConverter.stopComposition()
        self.kanaKanjiConverter.sendToDicdataStore(.setRequestOptions(options))
        self.kanaKanjiConverter.sendToDicdataStore(.closeKeyboard)
        self.candidatesWindow.hide()
        self.rawCandidates = nil
        self.displayedTextInComposingMode = nil
        self.composingText.stopComposition()
        if let client = sender as? IMKTextInput {
            client.insertText("", replacementRange: .notFound)
        }
        super.deactivateServer(sender)
    }

    @MainActor override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.US")
            self.directMode = value == "com.apple.inputmethod.Roman"
            if self.directMode {
                self.kanaKanjiConverter.sendToDicdataStore(.closeKeyboard)
            }
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    @objc private func toggleLiveConversion(_ sender: Any) {
        applicationLogger.info("\(#line): toggleLiveConversion")
        let config = Config.LiveConversion()
        config.value = !self.liveConversionEnabled
        self.updateLiveConversionToggleMenuItem(newValue: config.value)
    }

    private func updateLiveConversionToggleMenuItem(newValue: Bool) {
        self.liveConversionToggleMenuItem.title = if newValue {
            "ライブ変換をOFF"
        } else {
            "ライブ変換をON"
        }
    }

    @objc private func toggleEnglishConversion(_ sender: Any) {
        applicationLogger.info("\(#line): toggleEnglishConversion")
        let config = Config.EnglishConversion()
        config.value = !self.englishConversionEnabled
        self.updateEnglishConversionToggleMenuItem(newValue: config.value)
    }

    private func updateEnglishConversionToggleMenuItem(newValue: Bool) {
        self.englishConversionToggleMenuItem.title = if newValue {
            "英単語変換をOFF"
        } else {
            "英単語変換をON"
        }
    }

    @objc private func openGitHubRepository(_ sender: Any) {
        guard let url = URL(string: "https://github.com/ensan-hcl/azooKey-Desktop") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfigWindow(_ sender: Any) {
        (NSApplication.shared.delegate as? AppDelegate)!.openConfigWindow()
    }

    private func isPrintable(_ text: String) -> Bool {
        let printable: CharacterSet = [.alphanumerics, .symbols, .punctuationCharacters]
            .reduce(into: CharacterSet()) {
                $0.formUnion($1)
            }
        return CharacterSet(text.unicodeScalars).isSubset(of: printable)
    }

    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        // Check `event` safety
        guard let event else { return false }
        // get client to insert
        guard let client = sender as? IMKTextInput else {
            return false
        }
        // keyDown以外は無視
        if event.type != .keyDown {
            return false
        }
        // バックスラッシュは扱う
        if self.directMode, event.keyCode == 93, !event.modifierFlags.contains(.shift) {
            switch (Config.TypeBackSlash().value, event.modifierFlags.contains(.option)) {
            case (true, false), (false, true):
                client.insertText("\\", replacementRange: .notFound)

            case (true, true), (false, false):
                client.insertText("¥", replacementRange: .notFound)
            }
            return true
        } else if self.directMode, event.keyCode != 104 && event.keyCode != 102 {
            return false
        }
        // https://developer.mozilla.org/ja/docs/Web/API/UI_Events/Keyboard_event_code_values#mac_%E3%81%A7%E3%81%AE%E3%82%B3%E3%83%BC%E3%83%89%E5%80%A4
        let clientAction = switch event.keyCode {
        case 36: // Enter
            self.inputState.event(event, userAction: .enter)
        case 48: // Tab
            self.inputState.event(event, userAction: .unknown)
        case 49: // Space
            self.inputState.event(event, userAction: .space)
        case 51: // Delete
            self.inputState.event(event, userAction: .delete)
        case 53: // Escape
            self.inputState.event(event, userAction: .unknown)
        case 93: // Yen
            switch (Config.TypeBackSlash().value, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option)) {
            case (_, true, _):
                self.inputState.event(event, userAction: .input(KeyMap.h2zMap("|")))
            case (true, false, false), (false, false, true):
                self.inputState.event(event, userAction: .input(KeyMap.h2zMap("\\")))
            case (true, false, true), (false, false, false):
                self.inputState.event(event, userAction: .input(KeyMap.h2zMap("¥")))
            }
        case 102: // Lang2/kVK_JIS_Eisu
            self.inputState.event(event, userAction: .英数)
        case 104: // Lang1/kVK_JIS_Kana
            self.inputState.event(event, userAction: .かな)
        case 123: // Left
            // uF702
            self.inputState.event(event, userAction: .navigation(.left))
        case 124: // Right
            // uF703
            self.inputState.event(event, userAction: .navigation(.right))
        case 125: // Down
            // uF701
            self.inputState.event(event, userAction: .navigation(.down))
        case 126: // Up
            // uF700
            self.inputState.event(event, userAction: .navigation(.up))
        default:
            if let text = event.characters, self.isPrintable(text) {
                self.inputState.event(event, userAction: .input(KeyMap.h2zMap(text)))
            } else {
                self.inputState.event(event, userAction: .unknown)
            }
        }
        return self.handleClientAction(clientAction, client: client)
    }

    func showCandidateWindow() {
        self.candidatesWindow.update()
        self.candidatesWindow.show()
    }

    @MainActor func handleClientAction(_ clientAction: ClientAction, client: IMKTextInput) -> Bool {
        // return only false
        switch clientAction {
        case .showCandidateWindow:
            self.showCandidateWindow()
        case .hideCandidateWindow:
            self.candidatesWindow.hide()
        case .selectInputMode(let mode):
            client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.US")
            switch mode {
            case .roman:
                client.selectMode("dev.ensan.inputmethod.azooKeyMac.Roman")
                self.kanaKanjiConverter.sendToDicdataStore(.closeKeyboard)
            case .japanese:
                client.selectMode("dev.ensan.inputmethod.azooKeyMac.Japanese")
            }
        case .appendToMarkedText(let string):
            self.candidatesWindow.hide()
            self.composingText.insertAtCursorPosition(string, inputStyle: .roman2kana)
            self.updateRawCandidate()
            // Live Conversion
            let text = if self.liveConversionEnabled, self.composingText.convertTarget.count > 1, let firstCandidate = self.rawCandidates?.mainResults.first {
                firstCandidate.text
            } else {
                self.composingText.convertTarget
            }
            self.updateMarkedTextInComposingMode(text: text, client: client)
        case .moveCursor(let value):
            _ = self.composingText.moveCursorFromCursorPosition(count: value)
            self.updateRawCandidate()
        case .moveCursorToStart:
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition)
            self.updateRawCandidate()
        case .commitMarkedText:
            let candidateString = self.displayedTextInComposingMode ?? self.composingText.convertTarget
            client.insertText(self.displayedTextInComposingMode ?? self.composingText.convertTarget, replacementRange: NSRange(location: NSNotFound, length: 0))
            if let candidate = self.rawCandidates?.mainResults.first(where: {$0.text == candidateString}) {
                self.update(with: candidate)
            }
            self.kanaKanjiConverter.stopComposition()
            self.composingText.stopComposition()
            self.candidatesWindow.hide()
            self.displayedTextInComposingMode = nil
        case .submitSelectedCandidate:
            let candidateString = self.selectedCandidate ?? self.composingText.convertTarget
            client.insertText(candidateString, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard let candidate = self.rawCandidates?.mainResults.first(where: {$0.text == candidateString}) else {
                self.kanaKanjiConverter.stopComposition()
                self.composingText.stopComposition()
                self.rawCandidates = nil
                return true
            }
            // アプリケーションサポートのディレクトリを準備しておく
            self.update(with: candidate)
            self.composingText.prefixComplete(correspondingCount: candidate.correspondingCount)

            self.selectedCandidate = nil
            if self.composingText.isEmpty {
                self.rawCandidates = nil
                self.kanaKanjiConverter.stopComposition()
                self.composingText.stopComposition()
                self.candidatesWindow.hide()
            } else {
                self.inputState = .selecting(rangeAdjusted: false)
                self.updateRawCandidate()
                client.setMarkedText(
                    NSAttributedString(string: self.composingText.convertTarget, attributes: [:]),
                    selectionRange: .notFound,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                self.showCandidateWindow()
            }
        case .removeLastMarkedText:
            self.candidatesWindow.hide()
            self.composingText.deleteBackwardFromCursorPosition(count: 1)
            self.updateMarkedTextInComposingMode(text: self.composingText.convertTarget, client: client)
            if self.composingText.isEmpty {
                self.inputState = .none
            }
        case .consume:
            return true
        case .fallthrough:
            return false
        case .forwardToCandidateWindow(let event):
            self.candidatesWindow.interpretKeyEvents([event])
        case .sequence(let actions):
            var found = false
            for action in actions {
                if self.handleClientAction(action, client: client) {
                    found = true
                }
            }
            return found
        }
        return true
    }

    @MainActor private func updateRawCandidate() {
        let prefixComposingText = self.composingText.prefixToCursorPosition()
        let result = self.kanaKanjiConverter.requestCandidates(prefixComposingText, options: options)
        self.rawCandidates = result
    }

    /// function to provide candidates
    /// - returns: `[String]`
    @MainActor override func candidates(_ sender: Any!) -> [Any]! {
        self.updateRawCandidate()
        return self.rawCandidates?.mainResults.map { $0.text } ?? []
    }

    /// selecting modeの場合はこの関数は使わない
    func updateMarkedTextInComposingMode(text: String, client: IMKTextInput) {
        self.displayedTextInComposingMode = text
        client.setMarkedText(
            NSAttributedString(string: text, attributes: [:]),
            selectionRange: .notFound,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// selecting modeでのみ利用する
    @MainActor
    func updateMarkedTextWithCandidate(_ candidateString: String) {
        guard let candidate = self.rawCandidates?.mainResults.first(where: {$0.text == candidateString}) else {
            return
        }
        var afterComposingText = self.composingText
        afterComposingText.prefixComplete(correspondingCount: candidate.correspondingCount)
        // これを使うことで文節単位変換の際に変換対象の文節の色が変わる
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        text.append(NSAttributedString(string: candidateString, attributes: highlight))
        text.append(NSAttributedString(string: afterComposingText.convertTarget, attributes: underline))
        self.client()?.setMarkedText(
            text,
            selectionRange: NSRange(location: candidateString.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
     }

    @MainActor override func candidateSelected(_ candidateString: NSAttributedString!) {
        self.updateMarkedTextWithCandidate(candidateString.string)
        self.selectedCandidate = candidateString.string
    }

    @MainActor override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        self.updateMarkedTextWithCandidate(candidateString.string)
        self.selectedCandidate = candidateString.string
    }

    @MainActor private func update(with candidate: Candidate) {
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
    }

    private var azooKeyMemoryDir: URL {
        if #available(macOS 13, *) {
            URL.applicationSupportDirectory
                .appending(path: "azooKey", directoryHint: .isDirectory)
                .appending(path: "memory", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("azooKey", isDirectory: true)
                .appendingPathComponent("memory", isDirectory: true)
        }
    }

    private func prepareApplicationSupportDirectory() {
        // create directory
        do {
            applicationLogger.info("\(#line, privacy: .public): Applicatiion Support Directory Path: \(self.azooKeyMemoryDir, privacy: .public)")
            try FileManager.default.createDirectory(at: self.azooKeyMemoryDir, withIntermediateDirectories: true)
        } catch {
            applicationLogger.error("\(#line, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
