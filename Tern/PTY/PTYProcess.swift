import Darwin
import Foundation

/// A child process running on a pseudo-terminal.
///
/// Owns the PTY master descriptor and the whole process lifecycle: spawning,
/// non-blocking I/O, window size, termination and reaping. It knows nothing
/// about terminal emulation or UI — output is delivered as raw bytes on the
/// main queue, in order, followed by a single exit notification.
///
/// All descriptor work happens on a private serial queue, so the public
/// methods may be called from any thread.
nonisolated final class PTYProcess: @unchecked Sendable {
    struct WindowSize: Equatable, Sendable {
        var columns: Int
        var rows: Int
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0
    }

    struct Configuration: Sendable {
        var executable: String
        /// Full argv, including argv[0].
        var arguments: [String]
        var environment: [String: String]
        var workingDirectory: String
        var size: WindowSize
    }

    enum SpawnError: LocalizedError {
        case executableNotFound(String)
        case forkFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let path): "Shell not found or not executable: \(path)"
            case .forkFailed(let code): "Could not start shell: \(String(cString: strerror(code)))"
            }
        }
    }

    let pid: pid_t

    private let fd: Int32
    private let queue = DispatchQueue(label: "dev.tern.pty", qos: .userInteractive)
    private let onOutput: @MainActor ([UInt8]) -> Void
    private let onExit: @MainActor (Int32) -> Void

    // State below is confined to `queue`.
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var pendingWrite: [UInt8] = []
    private var chunksInFlight = 0
    private var isReadSuspended = false
    private var isClosed = false
    private var reachedEndOfFile = false
    private var exitStatus: Int32?
    private var didReportExit = false
    /// Keeps the object alive until the child is reaped, even if its owner
    /// lets go first, so closing a tab can never leave a zombie behind.
    private var keepAlive: PTYProcess?

    /// Chunks handed to the main queue but not yet consumed. Reading pauses
    /// above this, which makes a flooding program block on its own writes
    /// instead of growing our memory and starving the UI.
    private static let maxChunksInFlight = 4
    private static let killTimeout: TimeInterval = 3
    /// How long to wait for the last output after the shell exits before
    /// reporting the exit anyway (a background job may keep the PTY open).
    private static let drainTimeout: TimeInterval = 0.25

    init(
        configuration: Configuration,
        onOutput: @escaping @MainActor ([UInt8]) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw SpawnError.executableNotFound(configuration.executable)
        }
        let (pid, fd) = try Self.spawn(configuration)
        self.pid = pid
        self.fd = fd
        self.onOutput = onOutput
        self.onExit = onExit
        keepAlive = self
        queue.async { self.startMonitoring() }
    }

    /// Sends input (keystrokes, pastes) to the program.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async {
            guard !self.isClosed else { return }
            self.pendingWrite.append(contentsOf: bytes)
            self.flushWrites()
        }
    }

    /// Updates the PTY window size; the kernel then sends SIGWINCH to the
    /// foreground process group.
    func resize(_ size: WindowSize) {
        queue.async {
            guard !self.isClosed else { return }
            var ws = winsize(
                ws_row: UInt16(clamping: size.rows),
                ws_col: UInt16(clamping: size.columns),
                ws_xpixel: UInt16(clamping: size.pixelWidth),
                ws_ypixel: UInt16(clamping: size.pixelHeight)
            )
            _ = ioctl(self.fd, TIOCSWINSZ, &ws)
        }
    }

    /// The process group the terminal's input goes to: the shell's own while
    /// it waits at the prompt, a job's while that job runs in the foreground.
    /// `nil` once the PTY is closed.
    var foregroundProcessGroup: pid_t? {
        queue.sync {
            guard !isClosed else { return nil }
            let group = tcgetpgrp(fd)
            return group > 0 ? group : nil
        }
    }

    /// Hangs up the terminal: sends SIGHUP (which zsh forwards to its jobs),
    /// closes the PTY, and escalates to SIGKILL if the shell is still alive
    /// after a timeout. The exit callback still fires once the child is reaped.
    func terminate() {
        queue.async {
            if self.exitStatus == nil {
                kill(self.pid, SIGHUP)
                self.queue.asyncAfter(deadline: .now() + Self.killTimeout) {
                    if self.exitStatus == nil { kill(self.pid, SIGKILL) }
                }
            }
            self.closeDescriptor()
        }
    }

    // MARK: - Spawning

    /// Forks a child on a new PTY and execs the program in it.
    ///
    /// Everything the child needs is prepared before `forkpty`, because only
    /// async-signal-safe calls are allowed between fork and exec.
    private static func spawn(_ configuration: Configuration) throws -> (pid_t, Int32) {
        let argv = CStringArray(configuration.arguments)
        let envp = CStringArray(configuration.environment.map { "\($0.key)=\($0.value)" })
        let executable = strdup(configuration.executable)
        let directory = strdup(configuration.workingDirectory)
        defer {
            argv.deallocate()
            envp.deallocate()
            free(executable)
            free(directory)
        }

        var size = winsize(
            ws_row: UInt16(clamping: configuration.size.rows),
            ws_col: UInt16(clamping: configuration.size.columns),
            ws_xpixel: UInt16(clamping: configuration.size.pixelWidth),
            ws_ypixel: UInt16(clamping: configuration.size.pixelHeight)
        )
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 {
            throw SpawnError.forkFailed(errno: errno)
        }
        if pid == 0 {
            // Child. The app may ignore or block signals (e.g. SIGPIPE), and
            // ignored dispositions survive exec — reset them so the shell
            // starts with a clean slate.
            for number in Int32(1)..<32 {
                signal(number, SIG_DFL)
            }
            var emptyMask = sigset_t()
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            _ = chdir(directory)
            execve(executable, argv.pointer, envp.pointer)
            _exit(127)
        }

        // Keep the master out of shells spawned later by other tabs: an
        // inherited copy would stop this PTY from hanging up when we close it.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        return (pid, master)
    }

    // MARK: - I/O (on `queue`)

    private func startMonitoring() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailableOutput() }
        read.setCancelHandler { [fd] in close(fd) }
        readSource = read
        read.activate()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reapChild() }
        exitSource = exit
        exit.activate()
        // The child may have exited before the source was registered.
        reapChild()
    }

    private func readAvailableOutput() {
        let count = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            deliver(Array(readBuffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // EOF (or EIO): every process holding the slave side is gone.
            reachedEndOfFile = true
            closeDescriptor()
            reportExitIfReady(force: false)
        }
    }

    private func deliver(_ chunk: [UInt8]) {
        chunksInFlight += 1
        if chunksInFlight >= Self.maxChunksInFlight, let readSource, !isReadSuspended {
            readSource.suspend()
            isReadSuspended = true
        }
        DispatchQueue.main.async { [onOutput] in
            MainActor.assumeIsolated { onOutput(chunk) }
            self.queue.async { self.chunkConsumed() }
        }
    }

    private func chunkConsumed() {
        chunksInFlight -= 1
        if isReadSuspended, chunksInFlight < Self.maxChunksInFlight, let readSource {
            readSource.resume()
            isReadSuspended = false
        }
    }

    private func flushWrites() {
        while !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingWrite.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                // The program is not reading its input (e.g. a huge paste).
                // Retry shortly instead of blocking anything.
                queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.flushWrites() }
                return
            } else {
                pendingWrite.removeAll()
                return
            }
        }
    }

    private func closeDescriptor() {
        guard !isClosed else { return }
        isClosed = true
        pendingWrite.removeAll()
        if let readSource {
            // A suspended source must be resumed before it can be cancelled.
            if isReadSuspended {
                readSource.resume()
                isReadSuspended = false
            }
            // The cancel handler closes the descriptor once the source is done with it.
            readSource.cancel()
        } else {
            close(fd)
        }
    }

    // MARK: - Exit (on `queue`)

    private func reapChild() {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        exitStatus = Self.shellExitCode(fromWaitStatus: status)
        exitSource?.cancel()
        exitSource = nil
        reportExitIfReady(force: false)
        queue.asyncAfter(deadline: .now() + Self.drainTimeout) { self.reportExitIfReady(force: true) }
    }

    private func reportExitIfReady(force: Bool) {
        guard let exitStatus, !didReportExit else { return }
        guard reachedEndOfFile || isClosed || force else { return }
        didReportExit = true
        closeDescriptor()
        // Queued after any output still in flight, so the exit is always last.
        DispatchQueue.main.async { [onExit] in
            MainActor.assumeIsolated { onExit(exitStatus) }
        }
        keepAlive = nil
    }

    /// Converts a `waitpid` status to the value a shell would put in `$?`.
    static func shellExitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }
}

/// A NULL-terminated array of C strings for `execve`.
nonisolated private struct CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[strings.count] = nil
    }

    func deallocate() {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
