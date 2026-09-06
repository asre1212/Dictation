import UIKit

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didPress key: Key)
    /// Held down long enough to be a hold rather than a tap.
    func keyboardViewDidBeginBackspaceRepeat(_ view: KeyboardView)
    func keyboardViewDidRepeatBackspace(_ view: KeyboardView)
    func keyboardViewMicrophoneTouchDown(_ view: KeyboardView)
    func keyboardViewMicrophoneTouchUp(_ view: KeyboardView, inside: Bool)
}

/// The key grid.
///
/// Rebuilt whenever the plane or shift state changes. That is cheap at this size
/// and avoids the bookkeeping of mutating a live view tree, which matters because
/// the extension's memory ceiling punishes retained state far more than it
/// punishes a few extra allocations.
final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private(set) var plane: KeyboardPlane = .letters
    private(set) var shift: ShiftState = .off

    private var appearance: UIKeyboardAppearance
    private var rowsStack = UIStackView()
    private var buttons: [KeyButton] = []
    private weak var micButton: KeyButton?
    private weak var shiftButton: KeyButton?

    /// The globe key. The controller wires this to `handleInputModeList(from:with:)`
    /// directly — that one system method gives tap-to-advance and
    /// hold-for-the-picker together, and reimplementing either is worse.
    private(set) weak var nextKeyboardButton: KeyButton?

    /// Drawn on the microphone key. Reflects what the engine is doing.
    var isRecording = false {
        didSet { updateMicAppearance() }
    }

    /// When Full Access is off the microphone cannot reach the network, so the key
    /// is shown disabled rather than failing on every press.
    var isMicrophoneEnabled = true {
        didSet { updateMicAppearance() }
    }

    /// - Parameter onNextKeyboardButtonCreated: called every time the globe key is
    ///   built, which is on construction and again on every plane change. Taken at
    ///   init rather than set afterwards because the first build happens here, and a
    ///   globe key that missed its wiring is a rejected app.
    private let onNextKeyboardButtonCreated: (UIButton) -> Void

    init(
        appearance: UIKeyboardAppearance,
        onNextKeyboardButtonCreated: @escaping (UIButton) -> Void
    ) {
        self.appearance = appearance
        self.onNextKeyboardButtonCreated = onNextKeyboardButtonCreated
        super.init(frame: .zero)
        backgroundColor = Palette.background(appearance)
        buildStack()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Configuration

    func update(appearance: UIKeyboardAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        backgroundColor = Palette.background(appearance)
        buttons.forEach { $0.update(appearance: appearance) }
        updateMicAppearance()
        updateShiftAppearance()
    }

    func set(plane: KeyboardPlane) {
        guard plane != self.plane else { return }
        self.plane = plane
        // Leaving the letter plane drops a one-shot shift; caps lock survives.
        if plane != .letters, shift == .on { shift = .off }
        rebuild()
    }

    func set(shift: ShiftState) {
        guard shift != self.shift else { return }
        let wasUppercase = self.shift.isUppercase
        self.shift = shift
        if plane == .letters, wasUppercase != shift.isUppercase {
            relabelLetters()
        }
        updateShiftAppearance()
    }

    // MARK: - Layout

    private func buildStack() {
        rowsStack.axis = .vertical
        rowsStack.distribution = .fillEqually
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func rebuild() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        buttons.removeAll(keepingCapacity: true)

        for row in KeyboardLayout.rows(for: plane, shift: shift) {
            rowsStack.addArrangedSubview(makeRow(row))
        }

        updateMicAppearance()
        updateShiftAppearance()
    }

    private func makeRow(_ keys: [Key]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.spacing = 5
        stack.alignment = .fill

        let buttons = keys.map(makeButton(for:))
        buttons.forEach(stack.addArrangedSubview)

        // Every key's width is pinned to one unit-width key, so letters are all
        // identical and function keys scale against them. The reference has to be
        // chosen before any constraint is made — rows that open with a wide key
        // (shift, "123") would otherwise leave that first key unconstrained.
        guard let reference = buttons.first(where: { $0.key.widthWeight == 1 }) else {
            // No unit-width key in this row. Nothing to scale against, so divide
            // the space evenly rather than let the keys collapse.
            stack.distribution = .fillEqually
            return stack
        }

        for button in buttons where button !== reference {
            button.widthAnchor.constraint(
                equalTo: reference.widthAnchor,
                multiplier: button.key.widthWeight
            ).isActive = true
        }

        return stack
    }

    private func makeButton(for key: Key) -> KeyButton {
        let button = KeyButton(key: key, appearance: appearance)
        buttons.append(button)

        switch key {
        case .microphone:
            micButton = button
            button.addTarget(self, action: #selector(micTouchDown), for: .touchDown)
            button.addTarget(self, action: #selector(micTouchUpInside), for: .touchUpInside)
            button.addTarget(self, action: #selector(micTouchUpOutside), for: [.touchUpOutside, .touchCancel])

        case .backspace:
            button.onRepeat = { [weak self] in
                guard let self else { return }
                self.delegate?.keyboardViewDidRepeatBackspace(self)
            }
            button.addTarget(self, action: #selector(backspaceTouchDown(_:)), for: .touchDown)
            button.addTarget(
                self,
                action: #selector(backspaceTouchUp(_:)),
                for: [.touchUpInside, .touchUpOutside, .touchCancel]
            )

        case .shift:
            shiftButton = button
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        case .nextKeyboard:
            nextKeyboardButton = button
            onNextKeyboardButtonCreated(button)

        default:
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        }

        return button
    }

    private func relabelLetters() {
        for button in buttons {
            guard case .character(let value) = button.key,
                  value.count == 1,
                  value.rangeOfCharacter(from: .letters) != nil
            else { continue }
            button.update(label: shift.isUppercase ? value.uppercased() : value.lowercased())
        }
    }

    private func updateShiftAppearance() {
        shiftButton?.setActive(shift.isUppercase)
        shiftButton?.update(label: shift == .locked ? "⇪" : "⇧")
    }

    private func updateMicAppearance() {
        guard let micButton else { return }
        micButton.update(label: isRecording ? "◼︎" : "mic")
        micButton.isEnabled = isMicrophoneEnabled
        micButton.alpha = isMicrophoneEnabled ? 1 : 0.4
        micButton.setTitleColor(
            isRecording ? Palette.recording : Palette.text(appearance),
            for: .normal
        )
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: KeyButton) {
        delegate?.keyboardView(self, didPress: sender.key)
    }

    @objc private func backspaceTouchDown(_ sender: KeyButton) {
        delegate?.keyboardView(self, didPress: .backspace)
        delegate?.keyboardViewDidBeginBackspaceRepeat(self)
        sender.beginRepeat()
    }

    @objc private func backspaceTouchUp(_ sender: KeyButton) {
        sender.cancelRepeat()
    }

    @objc private func micTouchDown() {
        delegate?.keyboardViewMicrophoneTouchDown(self)
    }

    @objc private func micTouchUpInside() {
        delegate?.keyboardViewMicrophoneTouchUp(self, inside: true)
    }

    @objc private func micTouchUpOutside() {
        delegate?.keyboardViewMicrophoneTouchUp(self, inside: false)
    }

}
