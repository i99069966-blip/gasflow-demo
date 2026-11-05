import Foundation
import SwiftUI

/// App language: follow the system, or Chinese / Japanese / English chosen in Settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, ja, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .zh: return "中文"
        case .ja: return "日本語"
        case .en: return "English"
        }
    }

    /// The concrete language code ("zh", "ja" or "en").
    var resolved: String {
        switch self {
        case .zh, .ja, .en: return rawValue
        case .system:
            for pref in Locale.preferredLanguages {
                let p = pref.lowercased()
                if p.hasPrefix("zh") { return "zh" }
                if p.hasPrefix("ja") { return "ja" }
                if p.hasPrefix("en") { return "en" }
            }
            return "en"
        }
    }
}

final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let key = "app.language"

    @Published var choice: AppLanguage {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            Lang.set(choice.resolved)
            resolved = choice.resolved
        }
    }
    /// Changes when the shown language changes (used to rebuild the UI).
    @Published private(set) var resolved: String

    private init() {
        let c = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
        choice = c
        resolved = c.resolved
        Lang.set(c.resolved)
    }
}

/// Current language code, readable from any thread.
enum Lang {
    private static let lock = NSLock()
    private static var code: String = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "")?.resolved
        ?? AppLanguage.system.resolved
    static var current: String {
        lock.lock(); defer { lock.unlock() }
        return code
    }
    static func set(_ c: String) {
        lock.lock(); code = c; lock.unlock()
    }
}

/// Translate a Chinese UI string into the current language (the Chinese text is the key).
/// Strings with format placeholders are translated first, then formatted by the caller.
func L(_ zh: String) -> String {
    switch Lang.current {
    case "ja": return Strings.table[zh]?.ja ?? zh
    case "en": return Strings.table[zh]?.en ?? zh
    default: return zh
    }
}
