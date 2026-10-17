import AppKit
import SwiftTerm

/// User preferences, stored in `UserDefaults`.
///
/// The Settings window edits the defaults directly (via `@AppStorage`);
/// everything else reads a snapshot with `TerminalSettings.current` and
/// re-applies it when `UserDefaults.didChangeNotification` fires.
nonisolated struct TerminalSettings: Equatable {
    enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let fontWeight = "fontWeight"
        static let statusFontSizeOffset = "statusFontSizeOffset"
        static let shellPath = "shellPath"
        static let commandSuggestions = "commandSuggestions"
        static let notifyLongCommands = "notifyLongCommands"
        static let optionAsMeta = "optionAsMeta"
        static let cursorStyle = "cursorStyle"
        static let scrollbackLines = "scrollbackLines"
        static let appearance = "appearance"
        static let backgroundTranslucency = "backgroundTranslucency"
    }

    enum FontWeight: String, CaseIterable, Identifiable {
        case light, regular, medium, semibold, bold

        var id: Self { self }

        var title: String {
            switch self {
            case .light: "Light"
            case .regular: "Regular"
            case .medium: "Medium"
            case .semibold: "Semibold"
            case .bold: "Bold"
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        /// The same weight on `NSFontManager`'s 0–15 scale.
        var fontManagerWeight: Int {
            switch self {
            case .light: 3
            case .regular: 5
            case .medium: 6
            case .semibold: 8
            case .bold: 9
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// `nil` follows the system setting.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    static let defaultFontSize = 13.0
    static let defaultScrollbackLines = 10_000
    static let scrollbackRange = 100...1_000_000
    static let fontSizeRange = 8.0...36.0
    static let defaultStatusFontSizeOffset = -2.0
    static let statusFontSizeOffsetRange = -6.0...4.0
    static let backgroundTranslucencyRange = 0.0...1.0

    /// PostScript name; empty means the system monospaced font (SF Mono).
    var fontName = ""
    var fontSize = defaultFontSize
    var fontWeight = FontWeight.regular
    /// The status line's text size, in points relative to the terminal font.
    var statusFontSizeOffset = defaultStatusFontSizeOffset
    var shellPath = ShellLaunch.defaultShell
    /// Gray completions from history as you type (zsh-autosuggestions).
    var commandSuggestions = true
    /// A notification when a command of 10 s or more finishes out of sight.
    var notifyLongCommands = true
    /// ⌥ sends Esc+key (Meta) instead of typing the layout's ⌥ characters.
    var optionAsMeta = true
    var cursorStyle = CursorStyle.blinkBlock
    var scrollbackLines = defaultScrollbackLines
    var appearance = Appearance.system
    /// 0 is a solid window; above that the blurred desktop shows through the
    /// terminal background, more and more of it up to 1.
    var backgroundTranslucency = 0.0

    static var current: TerminalSettings {
        let defaults = UserDefaults.standard
        var settings = TerminalSettings()
        if let name = defaults.string(forKey: Key.fontName) {
            settings.fontName = name
        }
        if defaults.object(forKey: Key.fontSize) != nil {
            settings.fontSize = defaults.double(forKey: Key.fontSize).clamped(to: fontSizeRange)
        }
        if let raw = defaults.string(forKey: Key.fontWeight), let weight = FontWeight(rawValue: raw) {
            settings.fontWeight = weight
        }
        if defaults.object(forKey: Key.statusFontSizeOffset) != nil {
            settings.statusFontSizeOffset = defaults.double(forKey: Key.statusFontSizeOffset)
                .clamped(to: statusFontSizeOffsetRange)
        }
        if let shell = defaults.string(forKey: Key.shellPath), !shell.isEmpty {
            settings.shellPath = shell
        }
        if defaults.object(forKey: Key.commandSuggestions) != nil {
            settings.commandSuggestions = defaults.bool(forKey: Key.commandSuggestions)
        }
        if defaults.object(forKey: Key.notifyLongCommands) != nil {
            settings.notifyLongCommands = defaults.bool(forKey: Key.notifyLongCommands)
        }
        if defaults.object(forKey: Key.optionAsMeta) != nil {
            settings.optionAsMeta = defaults.bool(forKey: Key.optionAsMeta)
        }
        if let tag = defaults.string(forKey: Key.cursorStyle), let style = CursorStyle(tagName: tag) {
            settings.cursorStyle = style
        }
        if defaults.object(forKey: Key.scrollbackLines) != nil {
            settings.scrollbackLines = defaults.integer(forKey: Key.scrollbackLines).clamped(to: scrollbackRange)
        }
        if let raw = defaults.string(forKey: Key.appearance), let appearance = Appearance(rawValue: raw) {
            settings.appearance = appearance
        }
        if defaults.object(forKey: Key.backgroundTranslucency) != nil {
            settings.backgroundTranslucency = defaults.double(forKey: Key.backgroundTranslucency)
                .clamped(to: backgroundTranslucencyRange)
        }
        return settings
    }

    var isTranslucent: Bool {
        backgroundTranslucency > 0
    }

    var font: NSFont {
        let size = CGFloat(fontSize)
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) {
            // The family's face closest to the chosen weight; many monospaced
            // families only have Regular and Bold.
            guard let family = font.familyName else { return font }
            return NSFontManager.shared.font(
                withFamily: family, traits: [], weight: fontWeight.fontManagerWeight, size: size
            ) ?? font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: fontWeight.weight)
    }

    /// The configured shell if it is executable, the default otherwise.
    var resolvedShellPath: String {
        FileManager.default.isExecutableFile(atPath: shellPath) ? shellPath : ShellLaunch.defaultShell
    }
}

nonisolated private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
