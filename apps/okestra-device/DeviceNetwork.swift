import AppKit
import SwiftUI

@MainActor
final class DeviceNetworkController: ObservableObject {
  @Published private(set) var current: DeviceNetworkRate?
  @Published private(set) var history = DeviceNetworkHistory()
  @Published private(set) var status = "Connect a device"
  @Published private(set) var failure: String?
  private var estimator = DeviceNetworkEstimator()
  private var session: DeviceNetworkSession?
  private var generation = UUID()
  private var connection: (cli: String, directory: String, serial: String)?
  func start(cli: String, directory: String, serial: String) {
    stop()
    connection = (cli, directory, serial)
    status = "Starting network readings…"
    guard
      let helper = Bundle.main.url(forResource: "okestra-network-monitor-v1", withExtension: "jar")
    else {
      status = "Network readings unavailable"
      failure = "Network monitor component is missing. Reinstall Okestra Device."
      return
    }
    let stamp = generation
    let reader = DeviceNetworkSession(cli: cli, directory: directory, serial: serial)
    session = reader
    Task { [weak self] in
      do {
        try await Task.detached(priority: .utility) {
          try reader.stream(helper: helper) { [weak self] value in
            DispatchQueue.main.async {
              guard let self, self.generation == stamp else { return }
              let rate = self.estimator.observe(value)
              self.current = rate
              self.history.append(rate)
              self.status = rate == nil ? "Measuring…" : "Live device traffic · 60 s"
              self.failure = nil
            }
          }
        }.value
      } catch {
        guard let self, self.generation == stamp else { return }
        self.current = nil
        self.history.reset()
        self.status = "Network readings unavailable"
        self.failure = error.localizedDescription
      }
    }
  }
  func retry() {
    if let connection {
      start(cli: connection.cli, directory: connection.directory, serial: connection.serial)
    }
  }
  func stop() {
    generation = UUID()
    session?.stop()
    session = nil
    connection = nil
    estimator.reset()
    history.reset()
    current = nil
    failure = nil
    status = "Connect a device"
  }
}

struct DeviceNetworkSidebar: View {
  @ObservedObject var monitor: DeviceNetworkController
  @State private var expanded = true
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          expanded.toggle()
        } label: {
          HStack {
            Text("Network").font(.system(size: 12, weight: .semibold))
            Spacer()
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Network traffic")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        if monitor.failure != nil {
          Button {
            monitor.retry()
          } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 10))
          }
          .buttonStyle(.plain).help("Retry network readings").accessibilityLabel(
            "Retry network readings")
        }
      }
      if expanded {
        NetworkDuplexGraph(history: monitor.history, current: monitor.current).padding(.top, 14)
        Text(monitor.status).font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 7)
          .help(
            monitor.failure
              ?? "Live device-wide traffic reported by Android, including local traffic such as Wi-Fi mirroring. This is not a bandwidth test."
          )
      }
    }
  }
}

struct NetworkDuplexGraph: View {
  let history: DeviceNetworkHistory
  let current: DeviceNetworkRate?
  private let upload = Color.blue
  private let download = Color.green
  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let center = size.height / 2
      let halfHeight = max(1, center - 30)
      let width = max(1, size.width - 18)
      let ceiling = history.ceilingMbps
      for offset in [-0.5, 0.5] {
        var guide = Path()
        let y = center + halfHeight * offset
        guide.move(to: CGPoint(x: 9, y: y))
        guide.addLine(to: CGPoint(x: size.width - 9, y: y))
        context.stroke(guide, with: .color(.primary.opacity(0.04)), lineWidth: 0.5)
      }
      var baseline = Path()
      baseline.move(to: CGPoint(x: 9, y: center))
      baseline.addLine(to: CGPoint(x: size.width - 9, y: center))
      context.stroke(baseline, with: .color(.primary.opacity(0.16)), lineWidth: 0.5)
      func draw(uploading: Bool, color: Color) {
        var points: [CGPoint] = []
        func flush() {
          guard let first = points.first, let last = points.last else { return }
          var line = Path()
          line.move(to: first)
          for point in points.dropFirst() { line.addLine(to: point) }
          var area = line
          area.addLine(to: CGPoint(x: last.x, y: center))
          area.addLine(to: CGPoint(x: first.x, y: center))
          area.closeSubpath()
          context.fill(
            area,
            with: .linearGradient(
              Gradient(colors: [color.opacity(0.20), color.opacity(0.025)]),
              startPoint: CGPoint(x: 0, y: uploading ? center - halfHeight : center + halfHeight),
              endPoint: CGPoint(x: 0, y: center)))
          context.stroke(
            line, with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
          points.removeAll(keepingCapacity: true)
        }
        for (index, sample) in history.samples.enumerated() {
          guard let sample else {
            flush()
            continue
          }
          let rate = uploading ? sample.uploadMbps : sample.downloadMbps
          points.append(
            CGPoint(
              x: 9 + Double(index) / Double(max(1, history.samples.count - 1)) * width,
              y: DuplexNetworkGeometry.y(
                rate: rate, ceiling: ceiling, center: center, halfHeight: halfHeight,
                upload: uploading)))
        }
        flush()
      }
      draw(uploading: true, color: upload)
      draw(uploading: false, color: download)
    }
    .frame(height: 128)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    .overlay(alignment: .top) {
      reading("Upload", symbol: "arrow.up", value: current?.uploadMbps, color: upload).padding(9)
    }
    .overlay(alignment: .bottom) {
      reading("Download", symbol: "arrow.down", value: current?.downloadMbps, color: download)
        .padding(9)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Device network traffic. Upload above the center line, download below.")
    .accessibilityValue(
      "Upload \(formatted(current?.uploadMbps)), download \(formatted(current?.downloadMbps))")
  }
  private func formatted(_ value: Double?) -> String {
    value.map { String(format: "%.2f Mbps", $0) } ?? "—"
  }
  private func reading(_ title: String, symbol: String, value: Double?, color: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(color)
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer()
      Text(formatted(value)).font(.system(size: 10, weight: .medium)).monospacedDigit()
    }
  }
}
