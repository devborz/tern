import SwiftTerm

/// The 16 ANSI colors, one set for light and one for dark appearance.
///
/// The xterm defaults SwiftTerm starts with are made for a black background:
/// yellow, cyan and white all but vanish on a light one. These keep every
/// color readable on its background, and bright black (what zsh-autosuggestions
/// and many prompts use for dimmed text) clearly dimmer than normal text.
enum TerminalPalette {
    static let light = colors([
        0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x8C959F, 0xA40E26, 0x1A7F37, 0x7D4E00, 0x218BFF, 0xA475F9, 0x3192AA, 0xAFB8C1,
    ])

    static let dark = colors([
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC,
    ])

    private static func colors(_ rgb: [Int]) -> [Color] {
        rgb.map { value in
            // SwiftTerm colors are 16 bits per channel.
            Color(
                red: UInt16((value >> 16) & 0xFF) * 257,
                green: UInt16((value >> 8) & 0xFF) * 257,
                blue: UInt16(value & 0xFF) * 257
            )
        }
    }
}
