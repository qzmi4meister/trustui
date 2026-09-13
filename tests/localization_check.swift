import Foundation

@main
struct LocalizationCheck {
    static func main() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "language")
        defer {
            if let original { defaults.set(original, forKey: "language") }
            else { defaults.removeObject(forKey: "language") }
        }
        defaults.set("en", forKey: "language")
        assert(L("Подключение") == "Connection")
        assert(L("Запрос прав администратора отменён.") == "Administrator authorization was cancelled.")
        assert(L("guide.title") == "From installation to connection")
        assert(L("Не удалось прочитать: %@", "test %.toml") == "Could not read: test %.toml")
        assert(L("В конфигурации отсутствует listener.") == "The configuration has no listener section.")
        defaults.set("ru", forKey: "language")
        assert(L("Подключение") == "Подключение")
        assert(L("guide.title") == "От установки до подключения")
        assert(L("Не удалось прочитать: %@", "test.toml") == "Не удалось прочитать: test.toml")
        assert(L("An unchanged CLI log line") == "An unchanged CLI log line")
        print("Native English/Russian localization and live switching passed")
    }
}
