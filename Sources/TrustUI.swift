import AppKit
import SwiftUI

enum Bridge {
    static var python: String? {
        ["/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12",
         "/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.11"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func call(_ action: String, _ payload: [String: Any], admin: Bool = false) async throws -> [String: Any] {
        guard let python, let helper = Bundle.main.path(forResource: "backend", ofType: "py") else {
            throw NSError(domain: "TrustUI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("Не найден Python 3.12. Установите его командой brew install python@3.12.")])
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let input = Pipe(), output = Pipe()
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = output
                    let stdin: Data
                    if admin {
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        process.arguments = ["-"]
                        let command = [python, "-I", helper, action, String(decoding: data, as: UTF8.self)]
                            .map(quote).joined(separator: " ") + " || true"
                        // Preserve the bridge's JSON error for localization. Authorization errors still come from osascript.
                        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                        stdin = Data("do shell script \"\(escaped)\" with administrator privileges\n".utf8)
                    } else {
                        process.executableURL = URL(fileURLWithPath: python)
                        process.arguments = ["-I", helper, action]
                        stdin = data
                    }
                    try process.run()
                    input.fileHandleForWriting.write(stdin)
                    try input.fileHandleForWriting.close()
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
                    if let error = object?["error"] as? String {
                        let key = object?["errorKey"] as? String ?? error
                        let values = (object?["errorArguments"] as? [String] ?? []).map { $0 as CVarArg }
                        throw NSError(domain: "TrustUI", code: 2, userInfo: [NSLocalizedDescriptionKey:
                            Localization.text(key, arguments: values)])
                    }
                    guard process.terminationStatus == 0, let object else {
                        let message = String(decoding: result, as: UTF8.self)
                        throw NSError(domain: "TrustUI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                            message.contains("-128") ? L("Запрос прав администратора отменён.") :
                            (message.isEmpty ? L("Не удалось выполнить команду.") : message)])
                    }
                    continuation.resume(returning: object)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct EndpointProfile: Identifiable {
    var id: String { name }
    let name: String
    let endpoint: [String: Any]
}

@MainActor
final class TunnelModel: ObservableObject {
    @Published var language = Localization.language {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var section = "connection"
    @Published var invalidProfiles: [String] = []
    @Published var directory = UserDefaults.standard.string(forKey: "directory")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("trusttunnel").path
    @Published var profiles: [EndpointProfile] = []
    @Published var selectedProfile = ""
    @Published var hostname = ""
    @Published var addresses = ""
    @Published var username = ""
    @Published var password = ""
    @Published var transport = "http2"
    @Published var verifyCertificate = true
    @Published var antiDPI = false
    @Published var vpnMode = "general"
    @Published var killswitch = true
    @Published var dns = ""
    @Published var exclusions = ""
    @Published var loglevel = "info"
    @Published var busy = false
    @Published var loaded = false
    @Published var binaryAvailable = false
    @Published var running = false
    @Published var external: [Int] = []
    @Published var pid = 0
    @Published var started: Double = 0
    @Published var activeHostname = ""
    @Published var hadSession = false
    @Published var log = ""
    @Published var error: String?
    @Published var notice = ""
    @Published var statusError = ""
    private var endpoint: [String: Any] = [:]
    private var revision = ""
    private var savedEdits = Data()
    private var refreshing = false

    var payload: [String: Any] { ["directory": directory, "uid": Int(getuid())] }
    var hasExternal: Bool { !external.isEmpty }
    var dirty: Bool { loaded && serializedEdits != savedEdits }
    var canStart: Bool { loaded && binaryAvailable && !busy && !running && !hasExternal && statusError.isEmpty }
    var stateTitle: String {
        if !statusError.isEmpty { return L("Статус недоступен") }
        if running { return L("Клиент запущен") }
        if hasExternal { return L("Клиент запущен вне TrustUI") }
        return hadSession ? L("Клиент остановлен") : L("Клиент не запущен")
    }
    var noticeText: String {
        if !notice.isEmpty { return L(notice) }
        return invalidProfiles.isEmpty ? "" : L("Не удалось прочитать: %@", invalidProfiles.joined(separator: ", "))
    }
    var stateColor: Color { !statusError.isEmpty || hasExternal ? .orange : running ? .blue : .secondary }

    private func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var edits: [String: Any] {
        var server = endpoint
        server["hostname"] = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        server["addresses"] = lines(addresses)
        server["username"] = username
        server["password"] = password
        server["upstream_protocol"] = transport
        server["skip_verification"] = !verifyCertificate
        server["anti_dpi"] = antiDPI
        return ["endpoint": server, "vpn_mode": vpnMode, "killswitch_enabled": killswitch,
                "dns_upstreams": lines(dns), "exclusions": lines(exclusions), "loglevel": loglevel]
    }
    private var serializedEdits: Data {
        (try? JSONSerialization.data(withJSONObject: edits, options: [.sortedKeys])) ?? Data()
    }

    private func setEndpoint(_ value: [String: Any]) {
        endpoint = value
        hostname = value["hostname"] as? String ?? ""
        addresses = (value["addresses"] as? [String] ?? []).joined(separator: "\n")
        username = value["username"] as? String ?? ""
        password = value["password"] as? String ?? ""
        transport = value["upstream_protocol"] as? String ?? "http2"
        verifyCertificate = !(value["skip_verification"] as? Bool ?? false)
        antiDPI = value["anti_dpi"] as? Bool ?? false
    }

    func selectProfile(_ name: String) {
        guard let profile = profiles.first(where: { $0.name == name }) else { return }
        setEndpoint(profile.endpoint)
        notice = "Сервер выбран. Сохраните настройки, чтобы применить выбор."
    }

    func reload(reportError: Bool = true) async {
        busy = true
        defer { busy = false }
        binaryAvailable = FileManager.default.isExecutableFile(atPath:
            URL(fileURLWithPath: directory).appendingPathComponent("trusttunnel_client").path)
        do {
            let result = try await Bridge.call("load", payload)
            guard let config = result["config"] as? [String: Any] else { return }
            revision = result["revision"] as? String ?? ""
            profiles = (result["profiles"] as? [[String: Any]] ?? []).compactMap {
                guard let name = $0["name"] as? String, let endpoint = $0["endpoint"] as? [String: Any] else { return nil }
                return EndpointProfile(name: name, endpoint: endpoint)
            }
            selectedProfile = ""
            setEndpoint(config["endpoint"] as? [String: Any] ?? [:])
            vpnMode = config["vpn_mode"] as? String ?? "general"
            killswitch = config["killswitch_enabled"] as? Bool ?? true
            dns = (config["dns_upstreams"] as? [String] ?? []).joined(separator: "\n")
            exclusions = (config["exclusions"] as? [String] ?? []).joined(separator: "\n")
            loglevel = config["loglevel"] as? String ?? "info"
            savedEdits = serializedEdits
            loaded = true
            notice = ""
            invalidProfiles = result["invalidProfiles"] as? [String] ?? []
            UserDefaults.standard.set(directory, forKey: "directory")
        } catch {
            loaded = false
            if reportError { self.error = error.localizedDescription }
        }
    }

    private func persist() async throws {
        var request = payload
        request["revision"] = revision
        request["edits"] = edits
        let result = try await Bridge.call("save", request)
        revision = result["revision"] as? String ?? ""
        savedEdits = serializedEdits
        notice = running ? "Сохранено. Новые настройки применятся после перезапуска клиента."
                         : "Настройки сохранены. Резервная копия лежит рядом с TOML-файлом."
    }

    func save() async {
        busy = true
        defer { busy = false }
        do { try await persist() } catch { self.error = error.localizedDescription }
    }

    func connect() async {
        busy = true
        defer { busy = false }
        do {
            if dirty { try await persist() }
            _ = try await Bridge.call("start", payload, admin: true)
            notice = "Клиент работает в фоне. Закрытие окна не останавливает его."
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func disconnect() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await Bridge.call("stop", payload, admin: true)
            notice = "Клиент остановлен."
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let state = try await Bridge.call("status", payload)
            running = state["running"] as? Bool ?? false
            external = state["external"] as? [Int] ?? []
            pid = state["pid"] as? Int ?? 0
            started = state["started"] as? Double ?? 0
            activeHostname = state["hostname"] as? String ?? ""
            hadSession = state["hadSession"] as? Bool ?? false
            log = state["log"] as? String ?? ""
            statusError = ""
        } catch { statusError = error.localizedDescription }
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("Выберите папку с trusttunnel_client и trusttunnel_client.toml")
        panel.prompt = L("Выбрать")
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
            Task { await reload() }
        }
    }

    func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: directory).appendingPathComponent("trusttunnel_client.toml"))
    }
}

struct ContentView: View {
    @ObservedObject var model: TunnelModel
    @State private var discardAction: String?
    @State private var searchLog = ""
    @State private var followLog = true

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("TrustUI").font(.title2.bold())
                        Text("TrustTunnel CLI").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(selection: $model.section) {
                    Label(L("Подключение"), systemImage: "powerplug").tag("connection")
                    Label(L("Маршрутизация"), systemImage: "arrow.triangle.branch").tag("routing")
                    Label(L("Журнал"), systemImage: "text.alignleft").tag("logs")
                    Label(L("Приложение"), systemImage: "gearshape").tag("app")
                    Label(L("Инструкция"), systemImage: "book.closed").tag("help")
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Picker(L("Язык интерфейса"), selection: $model.language) {
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }.labelsHidden().pickerStyle(.segmented).help(L("Язык интерфейса"))
                    Label(model.stateTitle, systemImage: "circle.fill").font(.caption).foregroundStyle(model.stateColor)
                    Text(L("Обновление каждые 2 секунды")).font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                statusHeader
                Divider()
                if model.section == "help" {
                    GuideView(model: model) { reloadOrConfirm("reload") }
                } else if model.section == "logs" {
                    logsView
                } else {
                    Form {
                        switch model.section {
                        case "routing": routingForm
                        case "app": appForm
                        default: connectionForm
                        }
                    }.formStyle(.grouped).disabled(model.busy)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.dirty ? L("Есть несохранённые изменения") : L("Настройки из trusttunnel_client.toml"))
                            .font(.callout).foregroundStyle(model.dirty ? .orange : .secondary)
                        if !model.noticeText.isEmpty {
                            Text(model.noticeText).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.noticeText)
                        }
                    }
                    Spacer()
                    Button(L("Перечитать")) { reloadOrConfirm("reload") }.disabled(model.busy)
                    Button(L("Сохранить")) { Task { await model.save() } }
                        .keyboardShortcut("s").disabled(!model.dirty || model.busy)
                }.padding(16)
            }.frame(minWidth: 630, minHeight: 640)
        }
        .alert("TrustUI", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("Понятно"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(L("Отбросить несохранённые изменения?"), isPresented: Binding(
            get: { discardAction != nil }, set: { if !$0 { discardAction = nil } })) {
                Button(L("Отбросить изменения"), role: .destructive) {
                    let action = discardAction
                    discardAction = nil
                    if action == "directory" { model.chooseDirectory() } else { Task { await model.reload() } }
                }
                Button(L("Отмена"), role: .cancel) { discardAction = nil }
            }
    }

    private func reloadOrConfirm(_ action: String) {
        if model.dirty { discardAction = action }
        else if action == "directory" { model.chooseDirectory() }
        else { Task { await model.reload() } }
    }

    private var statusHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: model.running ? "network" : "power")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(model.stateColor)
                .frame(width: 52, height: 52).background(model.stateColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.stateTitle).font(.title3.bold())
                if model.running {
                    Text("\(model.activeHostname) · PID \(model.pid)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        Text(L("Запущен"))
                        Text(Date(timeIntervalSince1970: model.started), style: .relative)
                        Text(L("назад"))
                    }.font(.caption).foregroundStyle(.secondary)
                } else if model.hasExternal {
                    Text(L("Остановите прежний сеанс в терминале, чтобы запустить его здесь."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(!model.loaded || !model.binaryAvailable ? L("Откройте инструкцию, чтобы установить и настроить CLI.") :
                         model.statusError.isEmpty ? L("Выберите сервер и запустите клиент.") : model.statusError)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            if model.running {
                Button(L("Остановить")) { Task { await model.disconnect() } }.disabled(model.busy)
            } else {
                Button(model.dirty ? L("Сохранить и запустить") : L("Запустить")) { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent).disabled(!model.canStart)
            }
        }.padding(22)
    }

    private var connectionForm: some View {
        Group {
            Section(L("Сервер")) {
                Picker(L("Конфигурация"), selection: $model.selectedProfile) {
                    Text(L("Текущая / вручную")).tag("")
                    ForEach(model.profiles) { Text($0.name).tag($0.name) }
                }.onChange(of: model.selectedProfile) { _, value in model.selectProfile(value) }
                TextField(L("Имя сервера (TLS)"), text: $model.hostname)
                multiline(L("Адреса сервера"), text: $model.addresses, hint: L("Один host:port или IP:port на строку"), height: 52)
                TextField(L("Имя пользователя"), text: $model.username)
                SecureField(L("Пароль"), text: $model.password)
            }.disabled(!model.loaded)
            Section(L("Транспорт")) {
                Picker(L("Протокол"), selection: $model.transport) {
                    Text("HTTP/2").tag("http2")
                    Text("HTTP/3").tag("http3")
                }
                Toggle(L("Проверять сертификат сервера"), isOn: $model.verifyCertificate)
                if !model.verifyCertificate {
                    Label(L("В этом профиле проверка сертификата отключена."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Anti-DPI", isOn: $model.antiDPI)
            }.disabled(!model.loaded)
            Section {
                Text(L("Статус выше показывает работу процесса. Состояние соединения и причины ошибок смотрите в журнале CLI."))
                    .font(.callout).foregroundStyle(.secondary)
                if model.running {
                    Text(L("После изменения настроек остановите и снова запустите клиент.")).font(.callout)
                }
            }
        }
    }

    private var routingForm: some View {
        Group {
            Section(L("Режим VPN")) {
                Picker(L("Направлять через VPN"), selection: $model.vpnMode) {
                    Text(L("Всё, кроме списка ниже")).tag("general")
                    Text(L("Только список ниже")).tag("selective")
                }
                Toggle(L("Блокировать прямой доступ при потере VPN (kill switch)"), isOn: $model.killswitch)
                multiline(model.vpnMode == "general" ? L("Исключения из VPN") : L("Адреса для VPN"),
                          text: $model.exclusions, hint: L("Домен, *.example.com, IP или CIDR — по одному на строку"), height: 130)
            }
            Section("DNS") {
                multiline(L("DNS-серверы"), text: $model.dns,
                          hint: L("По одному на строку. Оставьте пустым, чтобы сохранить штатное поведение CLI."), height: 80)
            }
        }.disabled(!model.loaded)
    }

    private var appForm: some View {
        Group {
            Section(L("CLI-клиент")) {
                LabeledContent(L("Папка")) { Text(model.directory).textSelection(.enabled).font(.caption.monospaced()) }
                Button(L("Выбрать папку…")) { reloadOrConfirm("directory") }.disabled(model.running)
                if model.running {
                    Text(L("Для выбора другой папки сначала остановите клиент.")).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Нужны trusttunnel_client и trusttunnel_client.toml. Файлы серверов *.toml появятся в списке конфигураций."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Дополнительные параметры")) {
                Picker(L("Уровень журнала"), selection: $model.loglevel) {
                    ForEach(["error", "warn", "info", "debug", "trace"], id: \.self) { Text($0).tag($0) }
                }.disabled(!model.loaded)
                Button(L("Открыть TOML во внешнем редакторе")) { model.openConfig() }
                Text(L("После внешнего редактирования нажмите «Перечитать». При сохранении из формы неизвестные параметры остаются; комментарии сохраняются в резервной копии .bak рядом с конфигом."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Работа в фоне")) {
                Text(L("Клиент продолжает работать после закрытия окна и выхода из TrustUI. Для завершения сеанса используйте «Остановить». После перезагрузки компьютера запустите его заново."))
                Text(L("Пароль хранится в существующем TOML, резервных копиях и копии текущего сеанса. TrustUI создаёт свои файлы с доступом только для вашего пользователя. Журнал предыдущего запуска заменяется при следующем запуске."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func multiline(_ title: String, text: Binding<String>, hint: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(height: height)
                .padding(5).background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel(title)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private var filteredLog: String {
        if searchLog.isEmpty { return model.log }
        return model.log.components(separatedBy: .newlines).filter {
            $0.localizedCaseInsensitiveContains(searchLog)
        }.joined(separator: "\n")
    }

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Поиск в журнале"), text: $searchLog).textFieldStyle(.roundedBorder)
                Toggle(L("Следить"), isOn: $followLog).toggleStyle(.checkbox)
            }
            Text(L("Последние 48 КБ · имя пользователя и пароль текущего сеанса скрыты"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filteredLog.isEmpty ? L("Здесь появится вывод клиента, запущенного через TrustUI.") : L(filteredLog))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }.padding(12)
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: model.log) { if followLog { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }.padding(20).frame(maxHeight: .infinity)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TrustUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = TunnelModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("TrustUI", id: "main") {
            ContentView(model: model)
                .environment(\.locale, Locale(identifier: model.language))
                .task {
                    await model.reload(reportError: false)
                    if !model.loaded || !model.binaryAvailable { model.section = "help" }
                    await model.refresh()
                }
        }.defaultSize(width: 920, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(L("Открыть TrustUI")) { openWindow(id: "main") }.keyboardShortcut("0")
                }
                CommandGroup(replacing: .help) {
                    Button(L("Инструкция TrustUI")) {
                        model.section = "help"
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }.keyboardShortcut("?", modifiers: .command)
                }
            }
        MenuBarExtra {
            Text(model.stateTitle)
            if model.running { Text(model.activeHostname) }
            Divider()
            Button(L("Открыть TrustUI")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(L("Инструкция")) {
                model.section = "help"
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            if model.running {
                Button(L("Остановить клиент")) { Task { await model.disconnect() } }.disabled(model.busy)
            }
            Divider()
            Button(L("Завершить TrustUI")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.running ? "network" : "network.slash")
                .task {
                    while !Task.isCancelled {
                        await model.refresh()
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
        }
    }
}
