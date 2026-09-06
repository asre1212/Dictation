import UIKit

/// The strip above the keys: what the microphone is doing, the live transcript as
/// it firms up, and whatever recovery action is available right now.
///
/// One line of text is all the room there is, which is why `DictationError`
/// messages are written short.
final class StatusStrip: UIView {
    enum Mode: Equatable {
        /// Nothing happening. Shows the hint, or a "turn on Full Access" prompt.
        case idle(String)
        case listening
        case transcribing
        case partial(String)
        case error(String, isRetryable: Bool)
        /// Text was just inserted and can still be taken back.
        case inserted
    }

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onUndo: (() -> Void)?

    private let label = UILabel()
    private let waveform = WaveformView()
    private let actionButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var appearance: UIKeyboardAppearance
    private(set) var mode: Mode = .idle("")

    init(appearance: UIKeyboardAppearance) {
        self.appearance = appearance
        super.init(frame: .zero)
        build()
        apply(mode: .idle(""))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Building

    private func build() {
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.isHidden = true

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        actionButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.isHidden = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(label)
        addSubview(waveform)
        addSubview(spinner)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            waveform.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            waveform.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 22),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyColours()
    }

    func update(appearance: UIKeyboardAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        applyColours()
    }

    private func applyColours() {
        label.textColor = Palette.secondaryText(appearance)
        spinner.color = Palette.secondaryText(appearance)
        actionButton.setTitleColor(Palette.accent, for: .normal)
    }

    // MARK: - State

    func append(level: Float) {
        waveform.append(level: level)
    }

    func apply(mode: Mode) {
        self.mode = mode

        let showWaveform: Bool
        var showSpinner = false
        var action: String?

        switch mode {
        case .idle(let hint):
            label.text = hint
            label.textColor = Palette.secondaryText(appearance)
            showWaveform = false
            waveform.reset()

        case .listening:
            label.text = nil
            showWaveform = true
            action = "Cancel"

        case .transcribing:
            label.text = "  Transcribing…"
            label.textColor = Palette.secondaryText(appearance)
            showWaveform = false
            showSpinner = true
            action = "Cancel"

        case .partial(let text):
            // Head truncation keeps the newest words visible as they arrive.
            label.text = text
            label.textColor = Palette.text(appearance)
            showWaveform = false

        case .error(let message, let isRetryable):
            label.text = message
            label.textColor = Palette.recording
            showWaveform = false
            action = isRetryable ? "Retry" : nil

        case .inserted:
            label.text = nil
            showWaveform = false
            action = "Undo"
        }

        waveform.isHidden = !showWaveform
        label.isHidden = showWaveform
        showSpinner ? spinner.startAnimating() : spinner.stopAnimating()

        actionButton.setTitle(action, for: .normal)
        actionButton.isHidden = (action == nil)
    }

    @objc private func actionTapped() {
        switch mode {
        case .listening, .transcribing:
            onCancel?()
        case .error:
            onRetry?()
        case .inserted:
            onUndo?()
        default:
            break
        }
    }
}
