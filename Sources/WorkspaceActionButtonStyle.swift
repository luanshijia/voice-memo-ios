import SwiftUI

/// Disabled actions share the same neutral appearance across workspace pages.
struct WorkspaceActionButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var filled = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .foregroundStyle(isEnabled ? (filled ? Color.white : tint) : Color.secondary)
            .background(filled ? (isEnabled ? tint : Color(uiColor: .tertiarySystemFill)) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
    }
}
