import Darwin
import Foundation
import Testing
@testable import Tern

@Suite(.serialized)
struct PTYProcessTests {
    private func configuration(_ script: String) -> PTYProcess.Configuration {
        PTYProcess.Configuration(
            executable: "/bin/sh",
            arguments: ["sh", "-c", script],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            workingDirectory: "/tmp",
            size: .init(columns: 100, rows: 30)
        )
    }

    /// Collects what a process reports.
    private final class Recorder {
        var output: [UInt8] = []
        var exitCode: Int32?
        var outputAfterExit = false
    }

    @Test func deliversOutputThenExitStatus() async throws {
        let recorder = Recorder()
        _ = try PTYProcess(
            configuration: configuration("pwd; stty size; [ -t 0 ] && echo tty; exit 3"),
            onOutput: { bytes in
                recorder.output += bytes
                if recorder.exitCode != nil { recorder.outputAfterExit = true }
            },
            onExit: { recorder.exitCode = $0 }
        )
        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.exitCode == 3)
        #expect(!recorder.outputAfterExit)
        let text = String(decoding: recorder.output, as: UTF8.self)
        #expect(text.contains("/tmp"))
        #expect(text.contains("30 100"))
        #expect(text.contains("tty"))
    }

    @Test func terminateHangsUpTheProcess() async throws {
        let recorder = Recorder()
        let process = try PTYProcess(
            configuration: configuration("exec sleep 600"),
            onOutput: { _ in },
            onExit: { recorder.exitCode = $0 }
        )
        let pid = process.pid
        try await Task.sleep(for: .milliseconds(200))
        process.terminate()
        #expect(await eventually { recorder.exitCode != nil })
        #expect(recorder.exitCode == 128 + SIGHUP)
        #expect(!processIsAlive(pid))
    }

    @Test func missingExecutableThrows() {
        var config = configuration("true")
        config.executable = "/nonexistent/shell"
        #expect(throws: PTYProcess.SpawnError.self) {
            try PTYProcess(configuration: config, onOutput: { _ in }, onExit: { _ in })
        }
    }

    @Test func decodesWaitStatus() {
        #expect(PTYProcess.shellExitCode(fromWaitStatus: 0) == 0)
        #expect(PTYProcess.shellExitCode(fromWaitStatus: 2 << 8) == 2)
        #expect(PTYProcess.shellExitCode(fromWaitStatus: SIGINT) == 130)
    }
}
