import Foundation

/// Builds the command line and environment for a new shell session.
nonisolated enum ShellLaunch {
    static let defaultShell = "/bin/zsh"

    /// Variables injected by Xcode or launchd that must not leak into the
    /// user's shell, plus per-shell state the new shell recomputes itself.
    private static let strippedPrefixes = ["DYLD_", "__XCODE_", "__XPC_"]
    private static let strippedNames: Set<String> = [
        "OS_ACTIVITY_DT_MODE", "NSUnbufferedIO", "CFLOG_FORCE_STDERR",
        "PWD", "OLDPWD", "SHLVL", "_",
        "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    ]

    /// - Parameters:
    ///   - shell: Absolute path to the shell; started as a login shell (`-l`).
    ///   - integrationToken: Stamped by the integration script on its OSC 133
    ///     marks; see `ShellIntegrationParser.applicationID`.
    ///   - commandSuggestions: Turn on zsh-autosuggestions (zsh only).
    /// - Returns: The launch configuration and whether shell integration was set up.
    static func configuration(
        shell: String,
        workingDirectory: URL,
        size: PTYProcess.WindowSize,
        integrationToken: String,
        commandSuggestions: Bool
    ) -> (configuration: PTYProcess.Configuration, hasIntegration: Bool) {
        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter { key, _ in
            !strippedNames.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Tern"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if environment["LANG"] == nil {
            // Apps launched from Finder get no locale; without one zsh and
            // most tools fall back to ASCII and mangle Unicode.
            environment["LANG"] = preferredUTF8Locale()
        }

        var hasIntegration = false
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh", let zsh = ZshIntegration.installation {
            // Our .zshenv puts the user's ZDOTDIR back before loading their config.
            if let userZDOTDIR = inherited["ZDOTDIR"] {
                environment["TERN_ORIG_ZDOTDIR"] = userZDOTDIR
            }
            environment["ZDOTDIR"] = zsh.zdotdir.path
            environment["TERN_SHELL_INTEGRATION"] = zsh.script.path
            environment["TERN_SHELL_INTEGRATION_AID"] = integrationToken
            if commandSuggestions, let script = ZshIntegration.autosuggestionsScript {
                environment["TERN_AUTOSUGGEST"] = script.path
            }
            hasIntegration = true
        }

        let configuration = PTYProcess.Configuration(
            executable: shell,
            arguments: [shell, "-l"],
            environment: environment,
            workingDirectory: workingDirectory.path,
            size: size
        )
        return (configuration, hasIntegration)
    }

    /// `ll_CC.UTF-8` for the user's language and region when the system has
    /// that locale, `en_US.UTF-8` otherwise.
    static func preferredUTF8Locale() -> String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier,
           let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") {
                return candidate
            }
        }
        return "en_US.UTF-8"
    }
}
