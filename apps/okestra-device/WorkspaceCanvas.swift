import SwiftUI

struct WorkspaceCanvasBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // A static drawing, independent of the live video and performance updates.
    Canvas(opaque: true, rendersAsynchronously: true) { context, size in
      let dark = colorScheme == .dark
      context.fill(
        Path(CGRect(origin: .zero, size: size)),
        with: .color(
          dark
            ? Color(red: 0.085, green: 0.09, blue: 0.105)
            : Color(red: 0.968, green: 0.969, blue: 0.981)))

      let spacing: CGFloat = 22
      let radius: CGFloat = 1.05
      var dots = Path()
      for y in stride(from: spacing / 2, through: size.height, by: spacing) {
        for x in stride(from: spacing / 2, through: size.width, by: spacing) {
          dots.addEllipse(
            in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
      }
      context.fill(dots, with: .color(dark ? .white.opacity(0.28) : .black.opacity(0.24)))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
