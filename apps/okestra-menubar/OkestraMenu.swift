import AppKit
import Combine
import SwiftUI

private struct ProjectFile: Decodable {
    let name: String
    let services: [String: Service]
    struct Service: Decodable {}
}

@MainActor
final class Controller: ObservableObject {
    @Published var server = "Checking server…"
    @Published var projectStatus = "Choose a project folder"
    @Published var output = ""
    @Published var busy = false
    @Published var services: [String] = []
    @Published var connected = false
    @AppStorage("projectFolder") var projectFolder = ""

    private var executable: String? {
        ["/usr/local/bin/okestra", "/opt/homebrew/bin/okestra", "/usr/bin/okestra"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectFolder = url.path
            refresh()
        }
    }

    func refresh() {
        if !projectFolder.isEmpty {
            let manifest = URL(fileURLWithPath: projectFolder).appendingPathComponent("okestra.json")
            if let data = try? Data(contentsOf: manifest),
               let project = try? JSONDecoder().decode(ProjectFile.self, from: data) {
                services = project.services.keys.sorted()
            } else {
                services = []
                projectStatus = "No valid okestra.json in this folder"
            }
        }
        run(["status"], showOutput: false) { [weak self] text, code in
            if code != 0 { self?.server = "Server unavailable" }
            else if text.contains("docker_healthy: false") { self?.server = "Server connected · Docker unavailable" }
            else { self?.server = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("endpoint:") }) ?? "Server connected" }
        }
        guard !projectFolder.isEmpty, !services.isEmpty else { return }
        run(["project", "ps"], showOutput: false) { [weak self] text, code in
            self?.projectStatus = code == 0 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : "Project unavailable"
        }
        run(["connections"], showOutput: false) { [weak self] text, _ in
            guard let self else { return }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: self.projectFolder).appendingPathComponent("okestra.json")),
               let project = try? JSONDecoder().decode(ProjectFile.self, from: data) {
                self.connected = text.components(separatedBy: "\n").contains(where: { $0.hasPrefix(project.name + "\t") })
            }
        }
    }

    func action(_ arguments: [String]) {
        busy = true
        run(arguments, showOutput: true) { [weak self] _, _ in
            self?.busy = false
            self?.refresh()
        }
    }

    private func run(_ arguments: [String], showOutput: Bool, completion: @escaping @MainActor (String, Int32) -> Void) {
        guard let executable else {
            if showOutput { output = "Install the Okestra CLI first." }
            completion("Okestra CLI not installed", 1)
            return
        }
        let folder = projectFolder
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if !folder.isEmpty { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                await MainActor.run {
                    if showOutput { self.output = text }
                    completion(text, process.terminationStatus)
                }
            } catch {
                await MainActor.run {
                    if showOutput { self.output = error.localizedDescription }
                    completion(error.localizedDescription, 1)
                }
            }
        }
    }
}

struct OkestraMenu: View {
    @StateObject private var controller = Controller()
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Okestra").font(.headline)
                Spacer()
                Button("Refresh") { controller.refresh() }
            }
            Text(controller.server).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(controller.projectFolder.isEmpty ? "No project selected" : URL(fileURLWithPath: controller.projectFolder).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Choose…") { controller.chooseProject() }
            }
            Text(controller.projectStatus).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Up") { controller.action(["up"]) }
                Button("Down") { controller.action(["down"]) }
                Button(controller.connected ? "Refresh ports" : "Connect") { controller.action(["connect"]) }
                if controller.connected { Button("Disconnect") { controller.action(["disconnect"]) } }
            }
            .disabled(controller.busy || controller.services.isEmpty)
            if !controller.services.isEmpty {
                Divider()
                ForEach(controller.services, id: \.self) { service in
                    HStack {
                        Text(service)
                        Spacer()
                        Button("Logs") {
                            guard let data = try? Data(contentsOf: URL(fileURLWithPath: controller.projectFolder).appendingPathComponent("okestra.json")),
                                  let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return }
                            controller.action(["logs", "--tail", "100", "okestra-\(project.name)-\(service)"])
                        }
                        Button("Why") {
                            guard let data = try? Data(contentsOf: URL(fileURLWithPath: controller.projectFolder).appendingPathComponent("okestra.json")),
                                  let project = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return }
                            controller.action(["why", "okestra-\(project.name)-\(service)"])
                        }
                    }
                }
            }
            if !controller.output.isEmpty {
                Divider()
                ScrollView { Text(controller.output).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 180)
            }
            Divider()
            Button("Quit Okestra Menu") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 390)
        .onAppear { controller.refresh() }
        .onReceive(timer) { _ in if !controller.busy { controller.refresh() } }
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
