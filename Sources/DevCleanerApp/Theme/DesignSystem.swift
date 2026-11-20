import SwiftUI
import AppKit
import DevCleanerCore

/// Binds directly to the `SwiftUI.State<Value>` propertyWrapper struct rather than the `SwiftUIMacros.StateMacro` macro overload.
public typealias ViewState<Value> = SwiftUI.State<Value>

/// Translucent desktop-blending backdrop (`NSVisualEffectView`) so native SwiftUI `.glassEffect(...)` surfaces refract live light and depth.
public struct LiquidGlassWindowBackdrop: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .underWindowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

public enum DevCleanerTheme {
    public static func categoryColor(_ category: CleanupCategory) -> Color {
        switch category {
        case .projectArtifacts:
            return Color(red: 0.23, green: 0.55, blue: 0.96) // Cobalt Blue
        case .packageCaches:
            return Color(red: 0.62, green: 0.39, blue: 0.95) // Violet
        case .xcodeClutter:
            return Color(red: 0.12, green: 0.74, blue: 0.80) // Cyan Teal
        case .containersAndAI:
            return Color(red: 0.94, green: 0.51, blue: 0.22) // Warm Coral Orange
        }
    }

    public static func ecosystemColor(_ ecosystem: Ecosystem) -> Color {
        .secondary
    }

    public static func tierColor(_ tier: SafetyTier) -> Color {
        switch tier {
        case .safeRebuildable:
            return .secondary
        case .cautionRedownload:
            return .secondary
        case .protectedManual:
            return .orange.opacity(0.85)
        }
    }

    public static func stalenessColor(_ bucket: StalenessBucket) -> Color {
        .secondary
    }

    public static let shieldBlue = Color.secondary
    public static let safeGreen = Color(red: 0.16, green: 0.72, blue: 0.42)
}

public struct SubtleTag: View {
    public let text: String
    public let systemImage: String?

    public init(text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .medium))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
