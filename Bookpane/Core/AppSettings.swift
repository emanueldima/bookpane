import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    private(set) var theme: AppTheme
    private let store: ThemeStore

    init(defaults: UserDefaults = .standard) {
        store = ThemeStore(defaults: defaults)
        theme = store.loadTheme()
    }

    func changeTheme(_ theme: AppTheme) {
        guard self.theme != theme else { return }
        store.saveTheme(theme)
        self.theme = theme
    }
}

enum AppTheme: String, CaseIterable, Sendable {
    case system
    case dark
    case light
}

// Keep preference storage outside the views and the per-book settings.
private struct ThemeStore {
    private let defaults: UserDefaults
    private static let key = "theme"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadTheme() -> AppTheme {
        guard let value = defaults.string(forKey: Self.key), let theme = AppTheme(rawValue: value) else { return .system }
        return theme
    }

    func saveTheme(_ theme: AppTheme) {
        defaults.set(theme.rawValue, forKey: Self.key)
    }
}
