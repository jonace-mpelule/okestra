import AppKit
import Combine
import SwiftUI

private struct ProjectFile: Decodable {
    let name: String
    let services: [String: Service]?
    let android: AndroidConfig?
    struct AndroidConfig: Decodable { let path: String; let avd: String; let framework: String? }
    struct Service: Decodable {
        let ports: [String]?
    }
}

private struct AndroidStatus: Decodable {
    let enabled: Bool
    let device: String
    let sessions: [String: String]
    let local_serial: String
}

struct ServiceRow: Identifiable {
    let name: String
    let status: String
    let image: String
    var id: String { name }
    var isRunning: Bool { status.hasPrefix("Up") }
}

@MainActor
final class Controller: ObservableObject {
    @Published var server = "Checking connection…"
    @Published var endpoint = ""
    @Published var serviceHealthy = false
    @Published var dockerHealthy = false
    @Published var projectStatus = "Choose a project folder to get started."
    @Published var projectName = ""
    @Published var services: [ServiceRow] = []
    @Published var connected = false
    @Published var hasPorts = false
    @Published var output = ""
    @Published var outputTitle = "Activity"
    @Published var busy = false
    @Published var refreshing = false
    @Published var hasAndroid = false
    @Published var androidStatus = "Checking Android…"
    @Published var androidDevice = "stopped"
    @Published var androidSession = "stopped"
    @Published var androidFramework = "flutter"
    @Published var androidSerial = ""
    @AppStorage("projectFolder") var projectFolder = ""

    private var executable: String? {
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/okestra").path, "/usr/local/bin/okestra", "/opt/homebrew/bin/okestra", "/usr/bin/okestra"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private var manifest: ProjectFile? {
        guard !projectFolder.isEmpty else { return nil }
        let url = URL(fileURLWithPath: projectFolder).appendingPathComponent("okestra.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectFile.self, from: data)
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder containing okestra.json"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectFolder = url.path
            refresh()
        }
    }

    func openProject() {
        guard !projectFolder.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: projectFolder))
    }

    func refresh() {
        guard !busy, !refreshing else { return }
        refreshing = true
        let folder = projectFolder
        let project = manifest
        projectName = project?.name ?? ""
        hasAndroid = project?.android != nil
        androidFramework = project?.android?.framework ?? "flutter"
        if hasAndroid {
            run(["android", "status", "--json"]) { [weak self] text, code in
                guard let self, self.projectFolder == folder else { return }
                guard code == 0, let data = text.data(using: .utf8), let result = try? JSONDecoder().decode(AndroidStatus.self, from: data) else {
                    self.androidStatus = "Android unavailable · run Check setup"; return
                }
                self.androidDevice = result.device
                self.androidSession = result.sessions[project?.name ?? ""] ?? "stopped"
                self.androidSerial = result.local_serial
                self.androidStatus = result.enabled ? "Device: \(result.device) · App: \(self.androidSession)" : "Enable Android on the server"
            }
        }
        hasPorts = project?.services?.values.contains { !($0.ports ?? []).isEmpty } ?? false
        if let project {
            services = (project.services ?? [:]).keys.sorted().map { ServiceRow(name: $0, status: "Checking…", image: "") }
            projectStatus = "Checking project services…"
        } else {
            services = []
            connected = false
            projectStatus = folder.isEmpty ? "Choose a project folder to get started." : "This folder needs a valid okestra.json file."
        }

        run(["status"]) { [weak self] text, code in
            guard let self, self.projectFolder == folder else { return }
            self.refreshing = false
            if code != 0 {
                self.server = self.executable == nil ? "CLI not installed" : "Server unavailable"
                self.endpoint = ""
                self.serviceHealthy = false
                self.dockerHealthy = false
            } else {
                let values = Self.fields(in: text)
                self.endpoint = values["Server"] ?? values["endpoint"] ?? ""
                self.serviceHealthy = values["Service"] == "Healthy" || values["service_healthy"] == "true"
                self.dockerHealthy = values["Docker"] == "Healthy" || values["docker_healthy"] == "true"
                self.server = self.serviceHealthy ? (self.dockerHealthy ? "Ready to use" : "Docker unavailable") : "Service unavailable"
            }
        }
        guard let project else { return }
        run(["project", "ps"]) { [weak self] text, code in
            guard let self, self.projectFolder == folder else { return }
            if code != 0 {
                self.projectStatus = "Could not load project services."
                self.services = (project.services ?? [:]).keys.sorted().map { ServiceRow(name: $0, status: "Unavailable", image: "") }
                return
            }
            let rows = text.split(separator: "\n").compactMap { line -> ServiceRow? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 2 else { return nil }
                return ServiceRow(name: fields[0], status: fields[1], image: fields.count > 2 ? fields[2] : "")
            }
            self.services = rows
            let running = rows.filter(\.isRunning).count
            self.projectStatus = "\(running) of \(rows.count) services running"
        }
        run(["connections"]) { [weak self] text, code in
            guard let self, self.projectFolder == folder else { return }
            self.connected = code == 0 && text.split(separator: "\n").contains { $0.hasPrefix(project.name + "\t") }
        }
    }

    func action(_ arguments: [String], title: String) {
        guard !busy else { return }
        busy = true
        outputTitle = title
        output = "Working…"
        run(arguments) { [weak self] text, code in
            guard let self else { return }
            self.busy = false
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.output = result.isEmpty ? (code == 0 ? "Completed successfully." : "The command failed without details.") : result
            self.outputTitle = code == 0 ? title : "\(title) failed"
            self.refresh()
        }
    }

    func serviceAction(_ command: String, service: String) {
        guard !projectName.isEmpty else { return }
        let container = "okestra-\(projectName)-\(service)"
        if command == "logs" {
            action(["logs", "--tail", "100", container], title: "Logs · \(service)")
        } else {
            action(["why", container], title: "Diagnosis · \(service)")
        }
    }

    private static func fields(in text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return values
    }

    private func run(_ arguments: [String], completion: @escaping @MainActor (String, Int32) -> Void) {
        guard let executable else {
            completion("Install the Okestra CLI to use the menu app.", 1)
            return
        }
        let folder = projectFolder
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            if !folder.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                await MainActor.run { completion(text, process.terminationStatus) }
            } catch {
                await MainActor.run { completion(error.localizedDescription, 1) }
            }
        }
    }
}

struct OkestraMenu: View {
    @StateObject private var controller = Controller()
    @Environment(\.colorScheme) private var colorScheme
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var dark: Bool { colorScheme == .dark }
    private var canvas: Color { dark ? Color(red: 0.085, green: 0.095, blue: 0.105) : Color(red: 0.965, green: 0.968, blue: 0.96) }
    private var card: Color { dark ? Color(red: 0.14, green: 0.15, blue: 0.16) : .white }
    private var border: Color { dark ? .white.opacity(0.10) : .black.opacity(0.07) }
    private var accent: Color { Color(red: 0.25, green: 0.57, blue: 0.44) }

    var body: some View {
        VStack(spacing: 0) {
            appBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    serverCard
                    projectCard
                    servicesCard
                    if controller.hasAndroid { androidCard }
                    if !controller.output.isEmpty { activityCard }
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 430, height: 580)
        .background(canvas)
        .onAppear { controller.refresh() }
        .onReceive(timer) { _ in controller.refresh() }
    }

    private var appBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(accent, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Okestra").font(.system(size: 15, weight: .semibold))
                Text("Remote development workspace").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Refresh status")
            .disabled(controller.refreshing || controller.busy)
            Menu {
                Button("Open project folder", systemImage: "folder") { controller.openProject() }
                    .disabled(controller.projectFolder.isEmpty)
                Button("Run diagnostics", systemImage: "stethoscope") {
                    controller.action(["doctor"], title: "Diagnostics")
                }
                .disabled(controller.busy)
                Divider()
                Button("Quit Okestra Menu") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("More options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(card)
        .overlay(alignment: .bottom) { border.frame(height: 1) }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SERVER", symbol: "server.rack")
            HStack(spacing: 8) {
                Circle().fill(controller.serviceHealthy && controller.dockerHealthy ? accent : .orange).frame(width: 8, height: 8)
                Text(controller.server).font(.system(size: 14, weight: .semibold))
                Spacer()
                if controller.refreshing { ProgressView().controlSize(.small) }
            }
            if !controller.endpoint.isEmpty {
                Text(controller.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                statusPill("Service", ready: controller.serviceHealthy)
                statusPill("Docker", ready: controller.dockerHealthy)
            }
        }
        .cardStyle(card, border: border)
    }

    private var projectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("PROJECT", symbol: "square.stack.3d.up")
                Spacer()
                Button(controller.projectFolder.isEmpty ? "Choose folder" : "Change folder") { controller.chooseProject() }
                    .font(.caption.weight(.medium))
            }
            Text(controller.projectName.isEmpty ? "No project selected" : controller.projectName)
                .font(.system(size: 17, weight: .semibold))
            Text(controller.projectStatus).font(.caption).foregroundStyle(.secondary)
            if !controller.projectName.isEmpty {
                Label(controller.hasPorts ? (controller.connected ? "Local ports connected" : "Local ports disconnected") : "No local ports configured",
                      systemImage: controller.connected ? "link" : "link.badge.minus")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(controller.connected ? accent : .secondary)
            }
            if !controller.projectFolder.isEmpty {
                Text(controller.projectFolder).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).help(controller.projectFolder)
            }
        }
        .cardStyle(card, border: border)
    }

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionHeader("SERVICES", symbol: "cube.box")
                Spacer()
                Text("\(controller.services.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)
            if controller.services.isEmpty {
                Text(controller.projectName.isEmpty ? "Select a project to see its services." : "No services available.")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ForEach(controller.services) { service in
                    HStack(spacing: 10) {
                        Circle().fill(service.isRunning ? accent : .orange).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name).font(.subheadline.weight(.medium))
                            Text(service.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if !service.image.isEmpty {
                                Text(service.image).font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("View logs", systemImage: "text.alignleft") { controller.serviceAction("logs", service: service.name) }
                            Button("Diagnose", systemImage: "stethoscope") { controller.serviceAction("why", service: service.name) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .disabled(controller.busy || service.status == "Not created")
                    }
                    .padding(.vertical, 7)
                    if service.id != controller.services.last?.id { Divider() }
                }
            }
        }
        .cardStyle(card, border: border)
    }

    private var androidCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Android", systemImage: "iphone").font(.subheadline.weight(.semibold))
            Text(controller.androidStatus).font(.caption).foregroundStyle(.secondary)
            if !controller.androidSerial.isEmpty {
                Text("Local ADB: \(controller.androidSerial)").font(.caption2).textSelection(.enabled)
            }
            HStack {
                Button("Start device") { controller.action(["android", "start"], title: "Start Android") }
                    .disabled(controller.androidDevice == "ready" || controller.androidDevice == "booting")
                Button("Open device") { controller.action(["android", "view"], title: "Android viewer") }
                    .disabled(controller.androidDevice != "ready")
                Button("Run app") { controller.action(["android", "run"], title: "Run app") }
                    .disabled(controller.androidDevice != "ready" || ["running","building","installing","starting","stopping","needs_rebuild"].contains(controller.androidSession))
            }
            HStack {
                Button("Reload") { controller.action(["android", "reload"], title: "Reload app") }
                Button(controller.androidFramework == "expo" ? "Rebuild" : "Restart") { controller.action(["android", "restart"], title: controller.androidFramework == "expo" ? "Rebuild Expo development client" : "Restart Flutter") }
                Menu("More") {
                    if controller.androidFramework == "expo" { Button("Open development menu") { controller.action(["android", "dev-menu"], title: "Expo development menu") } }
                    Button("Enable sync on save") { controller.action(["android", "watch"], title: "Watch app source") }
                    Button("Stop sync on save") { controller.action(["android", "unwatch"], title: "Stop watching source") }
                    Button("Sync logs") { controller.action(["android", "watch-logs"], title: "Source sync logs") }
                    Button("App logs") { controller.action(["android", "logs"], title: "App logs") }
                    Button("Device logs") { controller.action(["android", "device-logs"], title: "Android logs") }
                    Button("Check setup") { controller.action(["android", "doctor"], title: "Android diagnostics") }
                    Divider()
                    Button("Stop app") { controller.action(["android", "stop"], title: "Stop app") }
                    Button("Disconnect local device") { controller.action(["android", "disconnect"], title: "Disconnect Android") }
                    Button("Stop device") { controller.action(["android", "device-stop"], title: "Stop Android device") }
                }
            }
        }
        .disabled(controller.busy)
        .cardStyle(card, border: border)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionHeader(controller.outputTitle.uppercased(), symbol: "terminal")
                Spacer()
                Button("Clear") { controller.output = "" }.font(.caption)
            }
            ScrollView {
                Text(controller.output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
        .cardStyle(card, border: border)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { controller.action(["up"], title: "Start project") } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            Button { controller.action(["down"], title: "Stop project") } label: {
                Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                controller.action([controller.connected ? "disconnect" : "connect"], title: controller.connected ? "Disconnect ports" : "Connect ports")
            } label: {
                Label(controller.connected ? "Disconnect" : "Connect", systemImage: controller.connected ? "link.badge.minus" : "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!controller.hasPorts)
        }
        .controlSize(.regular)
        .disabled(controller.busy || controller.services.isEmpty)
        .padding(12)
        .background(card)
        .overlay(alignment: .top) { border.frame(height: 1) }
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }

    private func statusPill(_ title: String, ready: Bool) -> some View {
        Text("\(title) · \(ready ? "Healthy" : "Unavailable")")
            .font(.caption2.weight(.medium))
            .foregroundStyle(ready ? accent : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(ready ? accent.opacity(0.12) : border, in: Capsule())
    }
}

private extension View {
    func cardStyle(_ background: Color, border: Color) -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(border, lineWidth: 1))
    }
}

@main
struct OkestraMenuApp: App {
    var body: some Scene {
        MenuBarExtra("Okestra", systemImage: "shippingbox") {
            OkestraMenu()
        }
        .menuBarExtraStyle(.window)
    }
}
