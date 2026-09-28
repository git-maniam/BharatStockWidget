import AppKit
import BharatStockCore
import SwiftUI
import WidgetKit

/// Colour and background rules from spec §7.
///
/// Nothing here hard-codes a colour value. Everything resolves through a semantic system colour,
/// so Light, Dark and Increased Contrast follow the system with no extra code.
enum Appearance {
    /// Gain/loss colour. Always paired with a ▲/▼ glyph at the call site, so colour is never the
    /// sole carrier of meaning — which is what makes the display readable with deuteranopia.
    static func changeColor(_ value: Double?) -> Color {
        guard let value, value != 0 else { return .secondary }
        return value > 0 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
    }

    /// Colour for a row whose data is not current.
    static func stateColor(_ state: RowState) -> Color {
        switch state {
        case .fresh: .primary
        case .stale: .secondary
        case .error, .unavailable: Color(nsColor: .tertiaryLabelColor)
        }
    }

    static let separator = Color(nsColor: .separatorColor)
    static let faint = Color(nsColor: .quaternaryLabelColor)
}

/// Lets previews force accessibility states that are read-only in `EnvironmentValues`.
///
/// Without this, §7's "verify all four sizes in … Reduced Transparency" could only be checked by
/// changing a System Settings toggle by hand, which is not a thing a preview matrix can do.
struct AppearanceOverrides: Sendable, Equatable {
    var reduceTransparency: Bool?
    var reduceMotion: Bool?

    static let none = AppearanceOverrides()
}

extension EnvironmentValues {
    @Entry var appearanceOverrides = AppearanceOverrides.none
}

/// Applies the widget background per §7.
///
/// Supplying a fully transparent fill inside `containerBackground(for: .widget)` is what lets
/// macOS Tahoe's Liquid Glass treatment show through; painting an opaque rectangle instead would
/// defeat it. When the user has Reduce Transparency on, that treatment is inappropriate, so a
/// solid window background is substituted.
struct WidgetBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.appearanceOverrides) private var overrides

    private var reduceTransparency: Bool {
        overrides.reduceTransparency ?? systemReduceTransparency
    }

    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Color.clear
            }
        }
    }
}

extension View {
    func widgetBackgroundTreatment() -> some View {
        modifier(WidgetBackground())
    }

    /// Suppresses transitions when the user has asked for reduced motion (§7).
    @ViewBuilder
    func respectingReduceMotion(_ reduceMotion: Bool) -> some View {
        if reduceMotion {
            transaction { $0.animation = nil }
        } else {
            self
        }
    }
}

/// The sizes the widget offers.
///
/// Kept outside the `Widget` conformance because `Widget` is main-actor-isolated, and the preview
/// matrix needs this list from a nonisolated context.
enum WidgetSizes {
    /// §7: all four sizes. `.systemExtraLarge` is macOS-only, so it is guarded to keep the code
    /// portable if an iPadOS target is ever added.
    static let supported: [WidgetFamily] = {
        #if os(macOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }()

    static func describe(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "Small (3 rows)"
        case .systemMedium: "Medium (5 rows)"
        case .systemLarge: "Large (10 rows)"
        #if os(macOS)
        case .systemExtraLarge: "Extra Large (15 rows)"
        #endif
        default: "\(family)"
        }
    }
}

/// How much of the layout each widget family can afford.
struct RowLayout {
    /// §7's row counts.
    static func rowCount(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 5
        case .systemLarge: 10
        #if os(macOS)
        case .systemExtraLarge: 15
        #endif
        default: 5
        }
    }

    /// Small has room for a name and one number only.
    static func isCompact(_ family: WidgetFamily) -> Bool {
        family == .systemSmall
    }

    /// §7: at the largest Dynamic Type sizes, drop the change-% column rather than let the name
    /// truncate further — the name is what identifies the row.
    static func showsChangeColumn(
        family: WidgetFamily,
        typeSize: DynamicTypeSize,
        configured: Bool
    ) -> Bool {
        guard configured else { return false }
        if family == .systemSmall { return false }
        return !typeSize.isAccessibilitySize
    }
}
