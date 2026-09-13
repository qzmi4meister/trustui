import Foundation

enum Localization {
    static var language: String {
        if let saved = UserDefaults.standard.string(forKey: "language"), ["ru", "en"].contains(saved) {
            return saved
        }
        return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
    }

    static func text(_ key: String, arguments: [CVarArg] = []) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}
