import AppKit

/// App-wide preferences. Changes are broadcast via `Settings.didChange`.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("EasyMarkdownSettingsDidChange")

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String { rawValue.capitalized }
    }

    /// (id, title) — ids must match the theme names in preview.js / preview.css.
    static let previewThemes: [(id: String, title: String)] = [
        ("github", "GitHub"),
        ("paper", "Paper"),
        ("nord", "Nord"),
        ("solarized", "Solarized"),
        ("gruvbox", "Gruvbox"),
        ("tokyo-night", "Tokyo Night"),
    ]

    static let codeThemes: [(id: String, title: String)] = [
        ("auto", "Match Preview Theme"),
        ("github", "GitHub"),
        ("atom-one", "Atom One"),
        ("tokyo-night", "Tokyo Night"),
        ("solarized", "Solarized"),
        ("gruvbox", "Gruvbox"),
        ("stackoverflow", "Stack Overflow"),
        ("nord", "Nord"),
        ("monokai", "Monokai"),
        ("dracula", "Dracula"),
    ]

    private let defaults = UserDefaults.standard

    /// Most recently opened or saved files, newest first.
    var recentFiles: [URL] {
        (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteRecent(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = [path] + (defaults.stringArray(forKey: "recentFiles") ?? []).filter { $0 != path }
        defaults.set(Array(paths.prefix(20)), forKey: "recentFiles")
    }

    var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance"); applyAppearance(); changed() }
    }

    var previewTheme: String {
        get { defaults.string(forKey: "previewTheme") ?? "github" }
        set { defaults.set(newValue, forKey: "previewTheme"); changed() }
    }

    var codeTheme: String {
        get { defaults.string(forKey: "codeTheme") ?? "auto" }
        set { defaults.set(newValue, forKey: "codeTheme"); changed() }
    }

    var scrollSync: Bool {
        get { defaults.object(forKey: "scrollSync") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "scrollSync"); changed() }
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
