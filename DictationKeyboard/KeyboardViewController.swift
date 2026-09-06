import UIKit

/// The keyboard.
///
/// Two things it must do, per App Store guideline 4.4.1, that are easy to skip
/// while chasing the interesting feature:
///
///   1. Type. A full QWERTY layout, working, as the primary function.
///   2. Keep working with Full Access off and with no network. Dictation degrades
///      to an explanation; typing does not degrade at all.
///
/// And one thing it must not do: launch any app other than Settings. That rules out
/// the workaround the Apple forums recommend — keyboard wakes the container app,
/// container app records, text comes back through the App Group — so the microphone
/// is opened here, inside the extension, or not at all.
final class KeyboardViewController: UIInputViewController {
    private var keyboardView: KeyboardView!
    private var statusStrip: StatusStrip!
    private var heightConstraint: NSLayoutConstraint?

    private let engine = DictationEngine(source: .keyboard)
    private var settings = AppSettings.default

    /// Length of the last dictated insertion, so Undo knows how far to delete.
    private var lastInsertionLength = 0

    /// Distinguishes a hold from a tap on the microphone key.
    private var micPressStartedAt: CFAbsoluteTime = 0
    private var isToggleSession = false
    private static let holdThreshold: TimeInterval = 0.35

    /// Double-tapping shift within this window locks it.
    private var lastShiftTapAt: CFAbsoluteTime = 0
    private static let doubleTapWindow: TimeInterval = 0.3

    /// Double-tapping space types ". ", as the system keyboard does.
    private var lastSpaceTapAt: CFAbsoluteTime = 0

    private var appearance: UIKeyboardAppearance {
        textDocumentProxy.keyboardAppearance ?? .default
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = SettingsStore.load()
        buildInterface()
        wireEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Settings may have changed in the container app since this instance was
        // created; the extension is long-lived and is not told about it.
        settings = SettingsStore.load()
        refreshAppearance()
        refreshIdleState()
        updateShiftForContext()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Never leave the microphone open behind a dismissed keyboard.
        engine.cancel()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeightConstraint()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshAppearance()
        updateShiftForContext()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // The extension is killed outright above roughly 48 MB. Nothing here is
        // worth dying for, so drop the dictation rather than the keyboard.
        engine.cancel()
        statusStrip.apply(mode: .error("Ran out of memory — try again", isRetryable: true))
    }

    // MARK: - Interface

    private func buildInterface() {
        let appearance = self.appearance

        statusStrip = StatusStrip(appearance: appearance)
        statusStrip.translatesAutoresizingMaskIntoConstraints = false
        statusStrip.onCancel = { [weak self] in self?.cancelDictation() }
        statusStrip.onRetry = { [weak self] in self?.retryDictation() }
        statusStrip.onUndo = { [weak self] in self?.undoLastInsertion() }

        keyboardView = KeyboardView(appearance: appearance) { [weak self] button in
            // `.allTouchEvents` is what Apple's own template uses: one target gives
            // tap-to-advance and hold-for-the-picker together, and reimplementing
            // either is worse than using the system method.
            button.addTarget(
                self,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.delegate = self

        view.backgroundColor = Palette.background(appearance)
        view.addSubview(statusStrip)
        view.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            statusStrip.topAnchor.constraint(equalTo: view.topAnchor),
            statusStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusStrip.heightAnchor.constraint(equalToConstant: Self.statusHeight),

            keyboardView.topAnchor.constraint(equalTo: statusStrip.bottomAnchor),
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private static let statusHeight: CGFloat = 36

    private func updateHeightConstraint() {
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let keyHeight = KeyboardLayout.keyHeight(forWidth: width)
        // Four rows, the gaps between them, the outer padding, and the status strip.
        let height = (keyHeight * 4) + (8 * 3) + 10
            + Self.statusHeight
            + CGFloat(settings.extraKeyboardHeight)

        if let heightConstraint {
            guard abs(heightConstraint.constant - height) > 0.5 else { return }
            heightConstraint.constant = height
        } else {
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            // Just below required: the host occasionally imposes its own height and
            // an unbreakable constraint would produce an unsatisfiable layout.
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    private func refreshAppearance() {
        let appearance = self.appearance
        view.backgroundColor = Palette.background(appearance)
        keyboardView.update(appearance: appearance)
        statusStrip.update(appearance: appearance)
    }

    /// The idle hint doubles as the explanation for why dictation is unavailable.
    /// Nothing here offers to open Settings — an extension may only launch Settings
    /// and even that is fragile, so the instructions are spelled out instead.
    private func refreshIdleState() {
        let canDictate: Bool
        let hint: String

        if !hasFullAccess {
            canDictate = false
            hint = "Dictation needs Full Access — Settings › General › Keyboard › Keyboards"
        } else if AudioRecorder.permission != .granted {
            canDictate = false
            hint = "Allow the microphone in the Dictation app to dictate"
        } else if !settings.isConfigured {
            canDictate = false
            hint = "Add your server address in the Dictation app"
        } else {
            canDictate = true
            hint = settings.micBehaviour == .holdToTalk
                ? "Hold the mic key and speak"
                : "Tap or hold the mic key and speak"
        }

        keyboardView.isMicrophoneEnabled = canDictate
        statusStrip.apply(mode: .idle(hint))
    }

    // MARK: - Dictation

    private func wireEngine() {
        engine.onLevel = { [weak self] level in
            self?.statusStrip.append(level: level)
        }

        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.keyboardView.isRecording = false
                if case .inserted = self.statusStrip.mode {} else { self.refreshIdleState() }
            case .listening:
                self.keyboardView.isRecording = true
                self.statusStrip.apply(mode: .listening)
            case .transcribing:
                self.keyboardView.isRecording = false
                self.statusStrip.apply(mode: .transcribing)
            case .failed(let error):
                self.keyboardView.isRecording = false
                self.statusStrip.apply(
                    mode: .error(
                        error.errorDescription ?? "Something went wrong",
                        isRetryable: error.isRetryable
                    )
                )
            }
        }

        engine.onPartial = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.statusStrip.apply(mode: .partial(text))
        }

        engine.onFinal = { [weak self] text in
            self?.insertDictated(text)
        }
    }

    private func startDictation() {
        guard keyboardView.isMicrophoneEnabled else {
            refreshIdleState()
            return
        }
        // Refreshed per dictation: the container app may have changed the cleanup
        // style or added vocabulary since the last one.
        settings = SettingsStore.load()
        engine.start(
            context: contextBeforeCursor(),
            hasFullAccess: hasFullAccess
        )
    }

    private func cancelDictation() {
        engine.cancel()
        refreshIdleState()
    }

    private func retryDictation() {
        engine.acknowledgeFailure()
        startDictation()
    }

    /// The text just before the cursor, for tense, casing and mid-sentence
    /// continuation. Truncated by the system and empty in some host apps — the
    /// cleanup prompt has to cope with getting nothing.
    private func contextBeforeCursor() -> String? {
        let context = textDocumentProxy.documentContextBeforeInput
        guard let context, !context.isEmpty else { return nil }
        return String(context.suffix(400))
    }

    // MARK: - Insertion

    private func insertDictated(_ text: String) {
        var output = text

        let before = textDocumentProxy.documentContextBeforeInput ?? ""

        if settings.autoCapitalise, shouldCapitaliseNext(after: before) {
            output = output.prefix(1).uppercased() + output.dropFirst()
        }

        // Don't run into the previous word.
        if let last = before.last,
           !last.isWhitespace,
           let first = output.first,
           !".,!?;:".contains(first) {
            output = " " + output
        }

        if settings.insertTrailingSpace {
            output += " "
        }

        textDocumentProxy.insertText(output)
        lastInsertionLength = output.count

        statusStrip.apply(mode: .inserted)
        updateShiftForContext()
    }

    /// Deletes exactly what was inserted. Only valid immediately afterwards — any
    /// typing in between and the offer is withdrawn.
    private func undoLastInsertion() {
        guard lastInsertionLength > 0 else { return }
        for _ in 0..<lastInsertionLength {
            textDocumentProxy.deleteBackward()
        }
        lastInsertionLength = 0
        refreshIdleState()
        updateShiftForContext()
    }

    // MARK: - Typing

    private func handleCharacter(_ value: String) {
        textDocumentProxy.insertText(value)
        // A one-shot shift falls back to lowercase after a single character.
        if keyboardView.shift == .on {
            keyboardView.set(shift: .off)
        }
        invalidateUndo()
    }

    private func handleSpace() {
        let now = CFAbsoluteTimeGetCurrent()
        let before = textDocumentProxy.documentContextBeforeInput ?? ""

        // Double-tap space types a full stop, but only after a word — otherwise
        // two spaces in a blank field would become ". ".
        if now - lastSpaceTapAt < Self.doubleTapWindow,
           before.hasSuffix(" "),
           before.dropLast().last?.isLetter == true || before.dropLast().last?.isNumber == true {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpaceTapAt = 0
        } else {
            textDocumentProxy.insertText(" ")
            lastSpaceTapAt = now
        }

        invalidateUndo()
        updateShiftForContext()
    }

    private func handleShift() {
        let now = CFAbsoluteTimeGetCurrent()
        let isDoubleTap = now - lastShiftTapAt < Self.doubleTapWindow
        lastShiftTapAt = now

        if isDoubleTap {
            keyboardView.set(shift: .locked)
            return
        }

        switch keyboardView.shift {
        case .off: keyboardView.set(shift: .on)
        case .on, .locked: keyboardView.set(shift: .off)
        }
    }

    /// Turns shift on at the start of a sentence, unless caps lock is on or the
    /// user turned auto-capitalisation off.
    private func updateShiftForContext() {
        guard settings.autoCapitalise, keyboardView.shift != .locked else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        keyboardView.set(shift: shouldCapitaliseNext(after: before) ? .on : .off)
    }

    private func shouldCapitaliseNext(after context: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let last = trimmed.last else { return true }
        // Only after a sentence-ending mark *and* whitespace, so "e.g." mid-sentence
        // does not trigger a capital.
        return ".!?".contains(last) && (context.last?.isWhitespace ?? false)
    }

    /// Any typing invalidates the Undo offer, since the deletion count no longer
    /// describes what is behind the cursor.
    private func invalidateUndo() {
        guard lastInsertionLength > 0 else { return }
        lastInsertionLength = 0
        refreshIdleState()
    }

    // MARK: - Feedback

    private func playFeedback() {
        if settings.keyClicks {
            UIDevice.current.playInputClick()
        }
        // Haptics in an extension require Full Access. Asking without it does
        // nothing, but checking keeps the intent explicit.
        if settings.haptics, hasFullAccess {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - KeyboardViewDelegate

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardView(_ view: KeyboardView, didPress key: Key) {
        playFeedback()

        switch key {
        case .character(let value):
            handleCharacter(value)
        case .space:
            handleSpace()
        case .return:
            textDocumentProxy.insertText("\n")
            invalidateUndo()
            updateShiftForContext()
        case .backspace:
            textDocumentProxy.deleteBackward()
            invalidateUndo()
            updateShiftForContext()
        case .shift:
            handleShift()
        case .plane(let plane):
            view.set(plane: plane)
        case .nextKeyboard:
            break // Wired straight to `handleInputModeList(from:with:)`.
        case .microphone:
            break // Handled by the touch-down/up pair below.
        }
    }

    func keyboardViewDidBeginBackspaceRepeat(_ view: KeyboardView) {
        playFeedback()
    }

    func keyboardViewDidRepeatBackspace(_ view: KeyboardView) {
        textDocumentProxy.deleteBackward()
        invalidateUndo()
    }

    func keyboardViewMicrophoneTouchDown(_ view: KeyboardView) {
        playFeedback()

        if engine.isBusy {
            // Second press ends a toggled recording, or abandons a slow transcript.
            if engine.state == .listening {
                engine.stop()
            } else {
                engine.cancel()
                refreshIdleState()
            }
            isToggleSession = false
            return
        }

        micPressStartedAt = CFAbsoluteTimeGetCurrent()
        isToggleSession = false
        startDictation()
    }

    func keyboardViewMicrophoneTouchUp(_ view: KeyboardView, inside: Bool) {
        guard engine.state == .listening, !isToggleSession else { return }

        // Sliding off the key before releasing throws the dictation away. It is the
        // only cancel gesture available while your thumb is already down.
        guard inside else {
            engine.cancel()
            refreshIdleState()
            return
        }

        let held = CFAbsoluteTimeGetCurrent() - micPressStartedAt

        switch settings.micBehaviour {
        case .holdToTalk:
            engine.stop()
        case .tapToToggle:
            isToggleSession = true
        case .automatic:
            if held >= Self.holdThreshold {
                engine.stop()
            } else {
                // Too quick to have been a hold: leave it running and wait for the
                // second tap.
                isToggleSession = true
            }
        }
    }
}

// MARK: - UIInputViewAudioFeedback

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
