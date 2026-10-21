import AppKit
import Carbon.HIToolbox

/// One bindable action. Everything here is user-facing, so the order of the
/// cases is the order in the settings window.
enum ShortcutAction: String, CaseIterable {
    case snip
    case snipMarkup
    case record
    case scroll
    case shelf
    case history
    case pastePin

    var title: String {
        switch self {
        case .snip: return "截图"
        case .snipMarkup: return "截图并标注"
        case .record: return "录制 GIF"
        case .scroll: return "长截图"
        case .shelf: return "晾图绳"
        case .history: return "截图历史"
        case .pastePin: return "贴到屏幕"

        }
    }

    /// ⌃⌥ plus a letter, spelled out so it is obvious what is being replaced.
    var fallback: Shortcut {
        switch self {
        case .snip: return Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: Shortcut.defaultModifiers)
        case .snipMarkup: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: Shortcut.defaultModifiers)
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: Shortcut.defaultModifiers)
        case .scroll: return Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: Shortcut.defaultModifiers)
        case .shelf: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: Shortcut.defaultModifiers)
        case .history: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: Shortcut.defaultModifiers)
        case .pastePin: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: Shortcut.defaultModifiers)
        }
    }
}

/// A Carbon-style key binding: a virtual key code plus modifier flags.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// ⌃ + ⌥, which stays clear of most apps' shortcuts.
    static let defaultModifiers = UInt32(controlKey | optionKey)

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func modifierFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// "⌃⌥X" — the same order Apple uses.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Shortcut.keyName(keyCode)
    }

    var isUsable: Bool {
        // A bare letter would eat typing everywhere, and a modifier-only
        // combination cannot be registered at all.
        modifiers != 0
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "空格"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "键 \(keyCode)"
        }
    }
}

/// Bindings live in UserDefaults: "7:6144" is key code 7 with ⌃⌥.
enum ShortcutStore {
    private static let key = "shortcuts"

    static var bindings: [ShortcutAction: Shortcut] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        var result: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            if let raw = stored[action.rawValue], let shortcut = parse(raw) {
                result[action] = shortcut
            } else {
                result[action] = action.fallback
            }
        }
        return result
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut {
        bindings[action] ?? action.fallback
    }

    /// Returns false when another action already holds the combination.
    @discardableResult
    static func set(_ shortcut: Shortcut, for action: ShortcutAction) -> Bool {
        let current = bindings
        if current.contains(where: { $0.key != action && $0.value == shortcut }) { return false }
        var raw: [String: String] = [:]
        for (entry, value) in current { raw[entry.rawValue] = encode(value) }
        raw[action.rawValue] = encode(shortcut)
        UserDefaults.standard.set(raw, forKey: key)
        return true
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func action(for shortcut: Shortcut) -> ShortcutAction? {
        bindings.first { $0.value == shortcut }?.key
    }

    private static func encode(_ shortcut: Shortcut) -> String {
        "\(shortcut.keyCode):\(shortcut.modifiers)"
    }

    private static func parse(_ raw: String) -> Shortcut? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        return Shortcut(keyCode: code, modifiers: mods)
    }
}
