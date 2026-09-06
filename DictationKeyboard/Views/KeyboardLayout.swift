import CoreGraphics
import Foundation

/// One key on the keyboard.
public enum Key: Equatable {
    case character(String)
    case space
    case `return`
    case backspace
    case shift
    /// Switches to the numeric plane, or back to letters.
    case plane(KeyboardPlane)
    /// The globe. Mandatory: App Store guideline 4.4.1 requires a way to progress
    /// to the next keyboard.
    case nextKeyboard
    case microphone

    /// The glyph or word drawn on the key.
    var label: String {
        switch self {
        case .character(let value): return value
        case .space: return "space"
        case .return: return "return"
        case .backspace: return "⌫"
        case .shift: return "⇧"
        case .plane(.letters): return "ABC"
        case .plane(.numbers): return "123"
        case .plane(.symbols): return "#+="
        case .nextKeyboard: return "🌐"
        case .microphone: return "mic"
        }
    }

    /// Whether the key gets the darker "function key" treatment.
    var isFunctionKey: Bool {
        switch self {
        case .character, .space:
            return false
        default:
            return true
        }
    }

    /// Relative width. `1` is one letter key; the row layout divides the remaining
    /// space in proportion.
    var widthWeight: CGFloat {
        switch self {
        case .space: return 4
        case .shift, .backspace: return 1.5
        case .return: return 2
        case .plane: return 1.4
        default: return 1
        }
    }
}

/// Which set of keys is showing.
public enum KeyboardPlane: Equatable {
    case letters
    case numbers
    case symbols
}

/// Shift state. Caps lock is reached by double-tapping shift.
public enum ShiftState: Equatable {
    case off
    case on
    case locked

    var isUppercase: Bool { self != .off }
}

/// The static key arrangement.
///
/// A full QWERTY layout is not optional. Guideline 4.4.1 requires a keyboard
/// extension to "provide keyboard input functionality" and to remain usable without
/// Full Access — a microphone-only keyboard is rejected. It is also the single
/// largest piece of work in the extension, which is easy to underestimate.
public enum KeyboardLayout {
    public static func rows(for plane: KeyboardPlane, shift: ShiftState) -> [[Key]] {
        switch plane {
        case .letters:
            let letters = [
                "qwertyuiop",
                "asdfghjkl",
                "zxcvbnm",
            ].map { row in
                row.map { shift.isUppercase ? String($0).uppercased() : String($0) }
            }
            return [
                letters[0].map { Key.character($0) },
                letters[1].map { Key.character($0) },
                [.shift] + letters[2].map { Key.character($0) } + [.backspace],
                bottomRow(returningTo: .numbers),
            ]

        case .numbers:
            return [
                "1234567890".map { Key.character(String($0)) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map { Key.character($0) },
                [.plane(.symbols)] + [".", ",", "?", "!", "'"].map { Key.character($0) } + [.backspace],
                bottomRow(returningTo: .letters),
            ]

        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { Key.character($0) },
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map { Key.character($0) },
                [.plane(.numbers)] + [".", ",", "?", "!", "'"].map { Key.character($0) } + [.backspace],
                bottomRow(returningTo: .letters),
            ]
        }
    }

    /// - Parameter returningTo: the plane the leftmost key switches to.
    private static func bottomRow(returningTo plane: KeyboardPlane) -> [Key] {
        [.plane(plane), .nextKeyboard, .microphone, .space, .return]
    }

    /// Keyboard height for the given width, excluding the status strip.
    /// Roughly matches the system keyboard so the host app's layout does not jump.
    public static func keyHeight(forWidth width: CGFloat) -> CGFloat {
        width > 400 ? 46 : 42
    }
}
