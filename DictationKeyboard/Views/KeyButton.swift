import UIKit

/// A single key.
///
/// Draws itself in the host app's keyboard appearance (light or dark), because a
/// keyboard that ignores `keyboardAppearance` looks broken in Messages' dark mode.
final class KeyButton: UIButton {
    let key: Key
    private var appearance: UIKeyboardAppearance

    /// Fired repeatedly while backspace is held.
    var onRepeat: (() -> Void)?

    private var repeatTimer: Timer?

    init(key: Key, appearance: UIKeyboardAppearance) {
        self.key = key
        self.appearance = appearance
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { cancelRepeat() }

    // MARK: - Appearance

    private func configure() {
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
        setTitle(key.label, for: .normal)
        titleLabel?.font = Self.font(for: key)
        applyColours()
    }

    func update(appearance: UIKeyboardAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        applyColours()
    }

    func update(label: String) {
        guard title(for: .normal) != label else { return }
        setTitle(label, for: .normal)
    }

    /// Highlights shift when it is on, and locks it visually when caps-locked.
    func setActive(_ isActive: Bool) {
        backgroundColor = isActive ? Palette.activeKey(appearance) : baseColour
    }

    private var baseColour: UIColor {
        key.isFunctionKey ? Palette.functionKey(appearance) : Palette.key(appearance)
    }

    private func applyColours() {
        backgroundColor = baseColour
        setTitleColor(Palette.text(appearance), for: .normal)
        layer.shadowColor = UIColor.black.withAlphaComponent(0.35).cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = appearance == .dark ? 0 : 1
    }

    private static func font(for key: Key) -> UIFont {
        switch key {
        case .character:
            return .systemFont(ofSize: 22, weight: .regular)
        case .space:
            return .systemFont(ofSize: 15, weight: .regular)
        case .shift, .backspace, .nextKeyboard:
            return .systemFont(ofSize: 18, weight: .regular)
        default:
            return .systemFont(ofSize: 15, weight: .regular)
        }
    }

    // MARK: - Press feedback

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            backgroundColor = isHighlighted ? Palette.pressedKey(appearance) : baseColour
        }
    }

    // MARK: - Key repeat

    /// Starts backspace auto-repeat: a pause, then accelerating deletion, the way
    /// the system keyboard behaves.
    func beginRepeat() {
        cancelRepeat()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.startFastRepeat()
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    func cancelRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func startFastRepeat() {
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.onRepeat?()
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }
}

/// Keyboard colours for both host appearances.
enum Palette {
    static func background(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark
            ? UIColor(white: 0.13, alpha: 1)
            : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)
    }

    static func key(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    }

    static func functionKey(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(red: 0.68, green: 0.71, blue: 0.74, alpha: 1)
    }

    static func pressedKey(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark
            ? UIColor(white: 0.55, alpha: 1)
            : UIColor(red: 0.72, green: 0.75, blue: 0.78, alpha: 1)
    }

    static func activeKey(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark ? UIColor(white: 0.62, alpha: 1) : .white
    }

    static func text(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark ? .white : .black
    }

    static func secondaryText(_ appearance: UIKeyboardAppearance) -> UIColor {
        appearance == .dark
            ? UIColor(white: 1, alpha: 0.6)
            : UIColor(white: 0, alpha: 0.5)
    }

    /// The recording state. Deliberately loud — you need to know at a glance that
    /// the microphone is live.
    static let recording = UIColor(red: 0.90, green: 0.22, blue: 0.27, alpha: 1)
    static let accent = UIColor(red: 0.20, green: 0.48, blue: 0.95, alpha: 1)
}
