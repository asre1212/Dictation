import UIKit

/// A rolling level meter shown while the microphone is live.
///
/// Its real job is reassurance: without a visible response to your voice there is
/// no way to tell a working microphone from a silently failing one, which — given
/// how the audio-session failures in this project present — is exactly the
/// distinction that matters.
final class WaveformView: UIView {
    private var levels: [CGFloat] = []
    private let barCount = 34
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3

    var tint: UIColor = Palette.recording {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        levels = Array(repeating: 0, count: barCount)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Appends one sample, 0...1, and scrolls the rest left.
    func append(level: Float) {
        levels.removeFirst()
        levels.append(CGFloat(max(0, min(1, level))))
        setNeedsDisplay()
    }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        var x = (rect.width - totalWidth) / 2
        let midY = rect.midY
        let maxHeight = rect.height

        context.setFillColor(tint.cgColor)

        for level in levels {
            // A floor so the meter reads as a live baseline rather than a dead line.
            let height = max(barWidth, level * maxHeight)
            let bar = CGRect(
                x: x,
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            context.addPath(
                UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).cgPath
            )
            context.fillPath()
            x += barWidth + barSpacing
        }
    }
}
