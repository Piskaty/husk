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
            return Color.primary.opacity(0.78)
        case .packageCaches:
            return Color.primary.opacity(0.50)
        case .xcodeClutter:
            return Color.primary.opacity(0.32)
        case .containersAndAI:
            return Color.primary.opacity(0.18)
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
