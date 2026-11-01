import AppKit
import ImageIO

enum ScreenshotMarkupTool: String, CaseIterable, Identifiable, Sendable {
  case select = "Select"
  case pen = "Draw"
  case arrow = "Arrow"
  case box = "Box"
  case redact = "Redact"
  case text = "Text"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .select: return "cursorarrow"
    case .pen: return "pencil.tip"
    case .arrow: return "arrow.up.right"
    case .box: return "rectangle"
    case .redact: return "rectangle.fill"
    case .text: return "textformat"
    }
  }
}

enum ScreenshotMarkupColor: String, CaseIterable, Identifiable, Sendable {
  case coral = "Red"
  case blue = "Blue"
  case yellow = "Yellow"
  case white = "White"
  var id: String { rawValue }
  var nsColor: NSColor {
    switch self {
    case .coral: return NSColor(srgbRed: 1, green: 0.25, blue: 0.3, alpha: 1)
    case .blue: return NSColor(srgbRed: 0.16, green: 0.58, blue: 1, alpha: 1)
    case .yellow: return NSColor(srgbRed: 1, green: 0.82, blue: 0.15, alpha: 1)
    case .white: return .white
    }
  }
}

// Coordinates are normalized to the image, so resizing the editor never changes an edit.
enum ScreenshotStroke: String, CaseIterable, Identifiable, Sendable {
  case fine = "Fine"
  case regular = "Regular"
  case bold = "Bold"
  var id: String { rawValue }
  var factor: CGFloat { self == .fine ? 0.002 : self == .bold ? 0.008 : 0.004 }
}
enum ScreenshotTextSize: String, CaseIterable, Identifiable, Sendable {
  case small = "Small"
  case medium = "Medium"
  case large = "Large"
  var id: String { rawValue }
  var factor: CGFloat { self == .small ? 0.025 : self == .large ? 0.05 : 0.035 }
}

struct ScreenshotMarkup: Identifiable, Equatable, Sendable {
  let id: UUID
  let tool: ScreenshotMarkupTool
  var color: ScreenshotMarkupColor
  var points: [CGPoint]
  var text: String
  var stroke: ScreenshotStroke = .regular
  var textSize: ScreenshotTextSize = .medium
  init(
    tool: ScreenshotMarkupTool, color: ScreenshotMarkupColor, points: [CGPoint], text: String = ""
  ) {
    id = UUID()
    self.tool = tool
    self.color = color
    self.points = points
    self.text = text
  }
}

enum ScreenshotMarkupRenderer {
  static func source(_ png: Data) throws -> NSImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CocoaError(.fileReadCorruptFile) }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }

  static func imageRect(image: CGSize, bounds: CGRect) -> CGRect {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }
    let scale = min(bounds.width / image.width, bounds.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
      y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
  }

  static func draw(image: NSImage, marks: [ScreenshotMarkup], in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSBezierPath(rect: rect).addClip()
    image.draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    // Redactions are always opaque and remain above every annotation.
    for mark in marks.filter({ $0.tool != .redact }) + marks.filter({ $0.tool == .redact }) {
      draw(mark, in: rect)
    }
  }

  private static func draw(_ mark: ScreenshotMarkup, in rect: CGRect) {
    guard let first = mark.points.first else { return }
    func map(_ p: CGPoint) -> CGPoint {
      CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
    let start = map(first)
    let end = map(mark.points.last ?? first)
    let width = max(0.5, rect.width * mark.stroke.factor)
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    mark.color.nsColor.setStroke()
    mark.color.nsColor.setFill()
    switch mark.tool {
    case .select: break
    case .pen:
      if mark.points.count == 1 {
        NSBezierPath(
          ovalIn: CGRect(
            x: start.x - width / 2, y: start.y - width / 2,
            width: width, height: width)
        ).fill()
      } else {
        path.move(to: start)
        for point in mark.points.dropFirst() { path.line(to: map(point)) }
        path.stroke()
      }
    case .arrow:
      path.move(to: start)
      path.line(to: end)
      let angle = atan2(end.y - start.y, end.x - start.x)
      let head = min(hypot(end.x - start.x, end.y - start.y) * 0.35, width * 5)
      for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
        path.move(to: end)
        path.line(
          to: CGPoint(x: end.x - head * cos(angle + delta), y: end.y - head * sin(angle + delta)))
      }
      path.stroke()
    case .box, .redact:
      let box = CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y),
        width: abs(end.x - start.x), height: abs(end.y - start.y))
      if mark.tool == .redact {
        NSColor.black.setFill()
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: box.integral).fill()
        NSGraphicsContext.current?.shouldAntialias = true
      } else {
        let border = NSBezierPath(rect: box)
        border.lineWidth = width
        border.stroke()
      }
    case .text:
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      (mark.text as NSString).draw(
        in: CGRect(x: start.x, y: start.y, width: rect.maxX - start.x, height: rect.maxY - start.y),
        withAttributes: [
          .font: NSFont.systemFont(
            ofSize: max(1, rect.width * mark.textSize.factor), weight: .semibold),
          .foregroundColor: mark.color.nsColor, .paragraphStyle: paragraph,
        ])
    }
  }

  static func bounds(of mark: ScreenshotMarkup, in rect: CGRect) -> CGRect {
    guard let first = mark.points.first else { return .zero }
    if mark.tool == .text {
      let point = CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height)
      let available = CGSize(
        width: max(1, rect.maxX - point.x), height: max(1, rect.maxY - point.y))
      let size = (mark.text as NSString).boundingRect(
        with: available,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [
          .font: NSFont.systemFont(
            ofSize: max(1, rect.width * mark.textSize.factor), weight: .semibold)
        ]
      ).size
      return CGRect(
        origin: point,
        size: CGSize(
          width: min(available.width, ceil(size.width)),
          height: min(available.height, ceil(size.height))))
    }
    let xs = mark.points.map { rect.minX + $0.x * rect.width }
    let ys = mark.points.map { rect.minY + $0.y * rect.height }
    return CGRect(
      x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  static func hitTest(
    _ point: CGPoint, marks: [ScreenshotMarkup], imageRect: CGRect, tolerance: CGFloat = 6
  ) -> UUID? {
    // Match rendering order: redactions are on top, newest annotations first.
    let ordered = marks.filter { $0.tool != .redact } + marks.filter { $0.tool == .redact }
    for mark in ordered.reversed() {
      guard bounds(of: mark, in: imageRect).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
      else { continue }
      if mark.tool != .pen && mark.tool != .arrow { return mark.id }
      let points = mark.points.map {
        CGPoint(
          x: imageRect.minX + $0.x * imageRect.width, y: imageRect.minY + $0.y * imageRect.height)
      }
      if points.count == 1, let first = points.first,
        hypot(point.x - first.x, point.y - first.y) <= tolerance
      {
        return mark.id
      }
      for (a, b) in zip(points, points.dropFirst()) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let projection = min(
          1,
          max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.000001, dx * dx + dy * dy)))
        if hypot(point.x - a.x - projection * dx, point.y - a.y - projection * dy) <= tolerance {
          return mark.id
        }
      }
    }
    return nil
  }

  static func translated(_ mark: ScreenshotMarkup, by delta: CGPoint) -> ScreenshotMarkup {
    guard !mark.points.isEmpty else { return mark }
    let xs = mark.points.map(\.x)
    let ys = mark.points.map(\.y)
    let dx = min(1 - xs.max()!, max(-xs.min()!, delta.x))
    let dy = min(1 - ys.max()!, max(-ys.min()!, delta.y))
    var result = mark
    result.points = mark.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    return result
  }

  static func png(image: NSImage, marks: [ScreenshotMarkup]) throws -> Data {
    let width = Int(image.size.width)
    let height = Int(image.size.height)
    guard width > 0, height > 0,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(height))
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(image: image, marks: marks, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return png
  }
}
