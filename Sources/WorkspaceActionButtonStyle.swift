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

/// Meeting toolbar only; other page geometry and styles remain unchanged.
struct MeetingActionButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var filled = false
    var pale = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isEnabled ? (filled ? Color.white : tint) : Color.secondary)
            .background(isEnabled && filled ? tint :
                (pale ? Color.blue.opacity(0.12) : Color(uiColor: .tertiarySystemFill)), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
    }
}
