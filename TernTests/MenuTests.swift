import AppKit
import Testing
@testable import Tern

struct MenuTests {
    /// Searches the menu and its submenus.
    private func item(_ title: String, in menu: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu?.items.first { $0.title == menu }?.submenu)
    }

    @Test(arguments: [
        ("File", "New Window", "n"),
        ("File", "New Tab", "t"),
        ("File", "Close", "w"),
        ("View", "Command History", "y"),
        ("View", "Bigger", "="),
        ("View", "Smaller", "-"),
        ("View", "Default Size", "0"),
        ("View", "Previous Command", "\u{F700}"),
        ("View", "Next Command", "\u{F701}"),
        ("Edit", "Copy", "c"),
        ("Edit", "Paste", "v"),
        ("Edit", "Clear Buffer", "k"),
        ("Edit", "Find…", "f"),
        ("Edit", "Find Next", "g"),
    ])
    func commandShortcutsExist(menu: String, title: String, key: String) throws {
        let item = try #require(item(title, in: menu), "\(menu) > \(title) is missing")
        #expect(item.keyEquivalent == key)
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test func closeClosesTheCurrentTab() throws {
        // ⌘W must close the key window (= the current tab), not the whole tab group.
        #expect(try #require(item("Close", in: "File")).action == #selector(NSWindow.performClose(_:)))
    }
}
