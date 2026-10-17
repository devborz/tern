import Foundation

/// Finds shell-integration escape sequences (OSC 7 and OSC 133) in the raw
/// PTY output stream.
///
/// This is deliberately not a terminal parser: it only tracks enough state to
/// recognise `ESC ] <code> ; <payload> (BEL | ESC \)` across chunk boundaries.
/// The bytes themselves are not modified — the caller still feeds all of them
/// to the terminal emulator. Each event comes with the offset just past its
/// terminator, so the caller can act on it at exactly that point in the stream.
nonisolated struct ShellIntegrationParser {
    struct LocatedEvent: Equatable {
        let event: ShellEvent
        /// Offset in the parsed chunk just past the sequence's terminator.
        let endOffset: Int
    }

    /// The `aid` our shell script stamps on OSC 133 marks. Marks with another
    /// (or no) `aid` come from nested shells, ssh sessions or `cat`-ed files
    /// and are ignored. `nil` accepts every mark.
    let applicationID: String?
    /// OSC 7 reports from other hosts (e.g. a remote shell over ssh) are ignored.
    let localHostName: String

    private enum State {
        case ground
        case escape
        case oscCode
        case oscPayload
        case oscIgnored
        case oscEscape(ignored: Bool)
    }

    private var state = State.ground
    private var code = 0
    private var payload: [UInt8] = []

    private static let maxPayloadLength = 64 * 1024
    private static let trackedCodes: Set<Int> = [7, 133]

    init(applicationID: String?, localHostName: String = ShellIntegrationParser.currentHostName()) {
        self.applicationID = applicationID
        self.localHostName = localHostName
    }

    mutating func parse<Bytes: RandomAccessCollection>(_ bytes: Bytes) -> [LocatedEvent]
    where Bytes.Element == UInt8, Bytes.Index == Int {
        var events: [LocatedEvent] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            switch state {
            case .ground:
                if byte == 0x1B { state = .escape }
            case .escape:
                state = .ground
                if byte == UInt8(ascii: "]") {
                    state = .oscCode
                    code = 0
                } else if byte == 0x1B {
                    state = .escape
                }
            case .oscCode:
                if let digit = Self.digitValue(byte), code < 100_000 {
                    code = code * 10 + digit
                } else if byte == UInt8(ascii: ";") {
                    payload.removeAll(keepingCapacity: true)
                    state = Self.trackedCodes.contains(code) ? .oscPayload : .oscIgnored
                } else {
                    consumeIgnored(byte)
                }
            case .oscPayload:
                switch byte {
                case 0x07:
                    if let event = dispatch() {
                        events.append(LocatedEvent(event: event, endOffset: index - bytes.startIndex))
                    }
                    state = .ground
                case 0x1B:
                    state = .oscEscape(ignored: false)
                case 0x18, 0x1A:
                    state = .ground
                default:
                    if payload.count < Self.maxPayloadLength {
                        payload.append(byte)
                    } else {
                        state = .oscIgnored
                    }
                }
            case .oscIgnored:
                consumeIgnored(byte)
            case .oscEscape(let ignored):
                if byte == UInt8(ascii: "\\") {
                    if !ignored, let event = dispatch() {
                        events.append(LocatedEvent(event: event, endOffset: index - bytes.startIndex))
                    }
                    state = .ground
                } else {
                    // ESC without '\' aborts the string and starts a new sequence.
                    state = byte == UInt8(ascii: "]") ? .oscCode : .ground
                    code = 0
                }
            }
        }
        return events
    }

    /// Skips the body of an OSC we do not care about.
    private mutating func consumeIgnored(_ byte: UInt8) {
        switch byte {
        case 0x07, 0x18, 0x1A: state = .ground
        case 0x1B: state = .oscEscape(ignored: true)
        default: state = .oscIgnored
        }
    }

    private func dispatch() -> ShellEvent? {
        let text = String(decoding: payload, as: UTF8.self)
        switch code {
        case 7: return parseWorkingDirectory(text)
        case 133: return parseSemanticPrompt(text)
        default: return nil
        }
    }

    /// `file://<host>/<percent-encoded path>`
    private func parseWorkingDirectory(_ text: String) -> ShellEvent? {
        guard text.hasPrefix("file://") else { return nil }
        let rest = text.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = rest[..<slash]
        guard host.isEmpty
            || host.caseInsensitiveCompare("localhost") == .orderedSame
            || host.caseInsensitiveCompare(localHostName) == .orderedSame
        else { return nil }
        let path = String(rest[slash...])
        return .workingDirectoryChanged(URL(fileURLWithPath: path.removingPercentEncoding ?? path, isDirectory: true))
    }

    /// `<action>[;<param>...][;key=value...]`, e.g. `D;0;aid=xyz`.
    private func parseSemanticPrompt(_ text: String) -> ShellEvent? {
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let action = fields.first, action.count == 1 else { return nil }
        var parameters: [Substring] = []
        var options: [Substring: Substring] = [:]
        for field in fields.dropFirst() {
            if let equals = field.firstIndex(of: "=") {
                options[field[..<equals]] = field[field.index(after: equals)...]
            } else {
                parameters.append(field)
            }
        }
        if let applicationID, options["aid"].map(String.init) != applicationID {
            return nil
        }

        switch action {
        case "A":
            return .promptStarted
        case "B":
            return .commandInputStarted
        case "C":
            let commandLine = options["cmdline_url"].flatMap { String($0).removingPercentEncoding }
                ?? options["cmdline"].map(String.init)
            return .commandStarted(commandLine: commandLine)
        case "D":
            return .commandFinished(exitCode: parameters.first.flatMap { Int32($0) })
        default:
            return nil
        }
    }

    private static func digitValue(_ byte: UInt8) -> Int? {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? Int(byte - UInt8(ascii: "0")) : nil
    }

    /// The name zsh puts in `$HOST`, which is what our OSC 7 reports.
    static func currentHostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
