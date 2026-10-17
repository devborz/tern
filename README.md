# Tern

A native macOS terminal (Swift, SwiftUI + AppKit, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))
that treats commands as structured execution units: for every command it knows the text, the working
directory, the start time, the exit code and the duration.

```
❯ git status
On branch main
✓ 0 · 84 ms ⧉
❯ cd src
✓ 0 · 3 ms
❯ make
make: *** No targets specified and no makefile found.  Stop.
✕ 2 · 12 ms ⧉
```

The status is set in a font a little smaller than the terminal's (Settings → Text → Status line size). When a
command printed something, the ⧉ button next to it copies that command's output (so does ⌘-clicking the
status line, and Copy Output in the ⌘Y history).

## Building and running

Requirements: macOS 14+, Xcode 26+ (the project was created in Xcode 27).

1. Open `Tern.xcodeproj`, choose the **Tern** scheme and press Run.
   On the first build Xcode asks to allow SwiftTerm's build-tool plugin — click **Trust & Enable**.
2. From the command line:

```bash
xcodebuild -project Tern.xcodeproj -scheme Tern -skipPackagePluginValidation build
```

Tests (including end-to-end ones with a real `zsh -l` on a PTY):

```bash
xcodebuild -project Tern.xcodeproj -scheme Tern -skipPackagePluginValidation -destination 'platform=macOS,arch=arm64' test
```

The app is not sandboxed: the shell needs ordinary access to the system.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N | new window (in the home directory) |
| ⌘T, “+” in the tab bar | new tab (in the current tab's directory) |
| ⌘W | close the tab (asks first if a program is running in it) |
| ⌘⇧[ / ⌘⇧] | previous / next tab |
| ⌘Y | the tab's command history (substring search) |
| ⌘↑ / ⌘↓ | previous / next command in the scrollback |
| ⌘= / ⌘− / ⌘0 | bigger / smaller / default font size (this tab only) |
| ⌘K | clear the screen and the scrollback |
| ⌘F, ⌘G / ⌘⇧G, ⌘E | find in the scrollback, next / previous match, use selection for find |
| ⌘, | settings |
| ⌘⌫ / ⌘⌦ | erase the command line / to the end of the line |
| ⌘← / ⌘→ | to the start / end of the line |
| ⌥⌫ / ⌥⌦ | erase the word before / after the cursor |
| ⌥← / ⌥→ | one word back / forward |

The line-editing keys are sent to the shell as `^U`, `^K`, `^A`, `^E`, `ESC DEL`, `ESC d`, `ESC b`, `ESC f`
(like Natural Text Editing in iTerm2, and like Ghostty), so they work in zsh, bash and other readline programs.
Programs that turned on the kitty keyboard protocol get the keys themselves.

Tabs are native `NSWindow` tabs: they can be dragged, pulled out into a window of their own and merged
through the Window menu. On quit, Tern remembers the windows, their tabs and working directories, and opens
them again at the next launch (without the scrollback). Quitting, or closing a tab with a program running in
it, asks for confirmation first.

When a command took 10 seconds or more and its window is not in front, Tern posts a notification (clicking it
brings the window back); this can be turned off in Settings → Shell.

## Architecture

```
Tern/
├── App/               TernApp (SwiftUI: menus, Settings scene), AppDelegate,
│                      WindowManager (windows, tabs, restoring them), CommandNotifier
├── Windows/           TerminalWindowController — one NSWindow = one tab = one session
├── Session/           TerminalSession — owns the shell and everything that outlives any view
│                      SessionTerminalView — SwiftTerm's TerminalView (emulator + renderer),
│                      +Commands: ⌘↑/⌘↓ and command output from OSC 133 marks; TerminalPalette
├── PTY/               PTYProcess — forkpty, non-blocking I/O, resize, SIGHUP/SIGKILL, reaping
├── ShellIntegration/  ShellIntegrationParser (OSC 7 / OSC 133), ShellLaunch (env), ZshIntegration,
│                      zsh-autosuggestions.zsh (third-party, MIT)
├── Commands/          CommandExecution, CommandTracker, CommandStatusLine
├── Views/             TerminalHostView (NSViewRepresentable), CommandHistoryView,
│                      CommandStatusView + CopyOutputButton (the status over the status line)
├── Settings/          TerminalSettings (UserDefaults), SettingsView
└── Resources/         AppIcon.icon — the app icon (Icon Composer; actool builds it)
```

Data flow:

```
keyboard → SwiftTerm TerminalView → TerminalSession.send → PTYProcess.write → zsh
zsh → PTYProcess (main queue) → ShellIntegrationParser ─┬→ bytes  → TerminalView.feed
                                                        └→ events → CommandTracker / cwd / title
```

Key decisions:

- **The PTY is separate from the UI.** `PTYProcess` depends on neither SwiftUI nor SwiftTerm. Closing a
  session sends SIGHUP (zsh passes it on to its jobs), closes the PTY, and sends SIGKILL after 3 s; the child is
  always reaped. The master fd is marked `FD_CLOEXEC` so that another tab's shell never holds this PTY open.
- **The session owns the emulator.** The screen and the scrollback live in SwiftTerm's `TerminalView`, which
  `TerminalSession` owns; SwiftUI only embeds it, so rebuilding a view loses nothing.
- **Shell integration comes before the emulator.** The parser looks for OSC 7 and OSC 133 only, in the raw
  stream, without changing the bytes. Each event comes with its exact position in the stream, so the status
  line lands exactly between a command's output and the next prompt. Registering an OSC 133 handler of our
  own with SwiftTerm is not an option — it would turn off SwiftTerm's own handling of semantic prompts.
- **zsh integration through `ZDOTDIR`** (as in Ghostty and kitty): our `.zshenv` restores the user's
  `ZDOTDIR`, loads their `.zshenv`, and adds hooks with `add-zsh-hook`; PS1 is left alone.
  Protocol: `133;A` prompt, `133;C;cmdline_url=…` command start, `133;D;<code>` command end, `OSC 7` cwd.
  Every mark carries `aid=<session token>`, so marks from nested shells, ssh or a `cat`'ed file are ignored.
- **Command suggestions** (the rest of a command from history in gray, as in fish) come from a bundled
  [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) 0.7.1, MIT-licensed (see the file
  header). It is loaded at the first prompt, after the user's `.zshrc`; if the user already loaded the plugin,
  it is not loaded twice. Tab accepts a suggestion and completes as usual when there is none; a Tab the user
  has rebound is left alone. It can be turned off in Settings → Shell.
- **Command output comes from SwiftTerm's marks; no copy is kept.** SwiftTerm parses OSC 133 itself and
  marks every cell as prompt, input or output; the marks live in the scrollback and move with the text on
  reflow. A command's output is the rows between its command line and its status line. Once the output has
  been pushed out of the scrollback, there is nothing left to copy.
- **The status line is blank cells with an OSC 8 link `tern://command/<id>`,** and `CommandStatusView` draws
  the visible status over them: a terminal draws every row in one font, and the status is meant to be smaller.
  The link moves with the text through scrolling, reflow and scrollback trimming, so the view always finds its
  line; the layout is updated on every redraw, and synchronously on resize.
- **Durations** are measured with a monotonic clock and do not change when the system clock is adjusted.

## MVP limitations

- Command tracking and command suggestions work with zsh only (other shells run, without the integration).
- The command history is kept in memory, for the lifetime of the tab.
- The status text is not part of the buffer: it is not copied with selected text and not found by ⌘F.
  After `clear`/`reset` no status line is written.
