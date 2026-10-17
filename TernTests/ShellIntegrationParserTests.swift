import Foundation
import Testing
@testable import Tern

struct ShellIntegrationParserTests {
    private func parse(_ chunks: [String], aid: String? = "tok", host: String = "mac.local") -> [ShellIntegrationParser.LocatedEvent] {
        var parser = ShellIntegrationParser(applicationID: aid, localHostName: host)
        return chunks.flatMap { parser.parse(Array($0.utf8)) }
    }

    @Test func parsesCommandLifecycle() {
        let events = parse([
            "\u{1B}]133;A;aid=tok\u{07}% ",
            "\u{1B}]133;C;aid=tok;cmdline_url=git%20status\u{07}On branch main\r\n",
            "\u{1B}]133;D;2;aid=tok\u{07}",
        ]).map(\.event)
        #expect(events == [
            .promptStarted,
            .commandStarted(commandLine: "git status"),
            .commandFinished(exitCode: 2),
        ])
    }

    @Test func reportsOffsetJustPastTerminator() {
        let text = "out\u{1B}]133;D;0;aid=tok\u{1B}\\% "
        let events = parse([text])
        let bytes = Array(text.utf8)
        #expect(events.count == 1)
        #expect(Array(bytes[events[0].endOffset...]) == Array("% ".utf8))
    }

    @Test func handlesSequencesSplitAcrossChunks() {
        let events = parse(["\u{1B}", "]13", "3;C;aid=tok;cmdline_url=ls%20-", "la\u{1B}", "\\"]).map(\.event)
        #expect(events == [.commandStarted(commandLine: "ls -la")])
    }

    @Test func decodesUnicodeCommandLine() {
        let events = parse(["\u{1B}]133;C;aid=tok;cmdline_url=echo%20%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82\u{07}"]).map(\.event)
        #expect(events == [.commandStarted(commandLine: "echo привет")])
    }

    @Test func ignoresMarksFromOtherShells() {
        let events = parse([
            "\u{1B}]133;D;0\u{07}",
            "\u{1B}]133;D;0;aid=other\u{07}",
            "\u{1B}]133;A;aid=tok\u{07}",
        ]).map(\.event)
        #expect(events == [.promptStarted])
    }

    @Test func parsesWorkingDirectory() {
        let events = parse([
            "\u{1B}]7;file://mac.local/Users/me/My%20Projects\u{07}",
            "\u{1B}]7;file://MAC.LOCAL/tmp\u{1B}\\",
            "\u{1B}]7;file:///private/var\u{07}",
        ]).map(\.event)
        #expect(events == [
            .workingDirectoryChanged(URL(fileURLWithPath: "/Users/me/My Projects", isDirectory: true)),
            .workingDirectoryChanged(URL(fileURLWithPath: "/tmp", isDirectory: true)),
            .workingDirectoryChanged(URL(fileURLWithPath: "/private/var", isDirectory: true)),
        ])
    }

    @Test func ignoresWorkingDirectoryOfRemoteHost() {
        #expect(parse(["\u{1B}]7;file://server.example.com/home/me\u{07}"]).isEmpty)
    }

    @Test func ignoresOtherSequencesAndPlainOutput() {
        let events = parse([
            "\u{1B}]0;window title\u{07}",
            "\u{1B}[31mred\u{1B}[0m",
            "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\",
            "плоский текст \u{07}",
            "\u{1B}]133;A;aid=tok\u{07}",
        ]).map(\.event)
        #expect(events == [.promptStarted])
    }

    @Test func abortedSequenceDoesNotSwallowTheNextOne() {
        // ESC inside an OSC (not followed by '\') aborts it.
        let events = parse(["\u{1B}]133;D;0;aid=tok\u{1B}[0m\u{1B}]133;A;aid=tok\u{07}"]).map(\.event)
        #expect(events == [.promptStarted])
    }
}
