import SwiftUI

// Shared, reusable UI building blocks for the dashboard.
//
// Everything in this file is theme-driven chrome with no business logic: fonts,
// the cut-corner card shape, the focus/active control chrome, the standard
// remote focus/tap targets, and the small library of panels and buttons that
// the zone views compose. Keeping them here (rather than re-deriving the same
// modifier chains inline) is what lets the feature views stay declarative and
// consistent — every control picks up the same focus ring suppression, the same
// highlight/accent treatment, and the same accessibility traits for free.

// MARK: - Fonts

extension Font {
    /// Display face (Rajdhani) for titles and large readouts.
    static func novaDisplay(_ size: CGFloat) -> Font {
        .custom("Rajdhani-Medium", size: size)
    }

    /// Monospaced face (Share Tech Mono, heaviest weight) for labels, values,
    /// and anything that benefits from fixed-width digits.
    static func novaMono(_ size: CGFloat) -> Font {
        .custom("ShareTechMono-Regular", size: size).weight(.black)
    }
}

// MARK: - Shapes

/// The signature card silhouette: a rectangle with the top-right corner sliced
/// off at 45°. Used for every panel and ribbon button so the whole UI shares
/// one corner language.
struct CutCornerShape: Shape {
    var cut: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Focus & tap targets

extension View {
    /// Applies the three-state (idle / active / focused) chrome shared by every
    /// rectangular control surface.
    func controlChrome(isFocused: Bool, isActive: Bool = false) -> some View {
        modifier(ControlChrome(isFocused: isFocused, isActive: isActive))
    }

    /// Binds a control to the dashboard focus state AND tags it with a matching
    /// scroll id. The dashboard wraps its controls in a horizontal ScrollView and
    /// calls `proxy.scrollTo(focus)` whenever focus moves, so every control that
    /// participates in remote focus travel must carry this id — that is what
    /// keeps the focused control (e.g. the panel heater beside the air
    /// conditioner) fully on screen as you swipe through a surface.
    func dashboardFocus(_ binding: FocusState<DashboardFocus?>.Binding, equals value: DashboardFocus) -> some View {
        focused(binding, equals: value).id(value)
    }

    /// A passive focusable surface: hit-testable, joins the focus graph and the
    /// scroll-to-focus machinery, and suppresses the default tvOS focus ring —
    /// but takes no Select action. Used for read-only panels (weather, network)
    /// that you can still swipe onto and have scrolled into view.
    func dashboardFocusTarget(
        _ focus: FocusState<DashboardFocus?>.Binding,
        equals value: DashboardFocus
    ) -> some View {
        contentShape(Rectangle())
            .focusable(true)
            .dashboardFocus(focus, equals: value)
            .focusEffectDisabled()
    }

    /// The standard interactive control: a passive focus target plus a Select
    /// action and the button accessibility trait. This is the single source of
    /// the remote-driven "focusable, no system ring, fires on Select" behaviour
    /// that every tappable control in the dashboard relies on.
    func dashboardTapTarget(
        _ focus: FocusState<DashboardFocus?>.Binding,
        equals value: DashboardFocus,
        perform action: @escaping () -> Void
    ) -> some View {
        dashboardFocusTarget(focus, equals: value)
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// Idle / active / focused chrome for a rectangular control: theme-driven
/// foreground, fill, and border. Focused wins over active; both thicken the
/// border. This is the one place control colour state is decided, so the whole
/// UI reads the focus highlight and the active accent identically.
struct ControlChrome: ViewModifier {
    @EnvironmentObject private var store: DashboardStore
    let isFocused: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .background(background)
            .overlay {
                Rectangle().stroke(border, lineWidth: isFocused || isActive ? 2 : 1)
            }
    }

    private var foreground: Color {
        if isFocused { return store.theme.titleOnHighlight }
        if isActive { return store.theme.titleOnAccent }
        return store.theme.text
    }

    private var background: Color {
        if isFocused { return store.theme.highlight.color }
        if isActive { return store.theme.accent.color }
        return store.theme.panelSoft.color.opacity(0.46)
    }

    private var border: Color {
        if isFocused { return store.theme.highlight.color }
        if isActive { return store.theme.accent.color }
        return store.theme.borderColor
    }
}

// MARK: - Panels

/// The standard bordered card: optional display-font title, themed translucent
/// fill, and the shared cut-corner outline. Every zone surface is wrapped in one
/// so spacing, padding, and the corner treatment stay uniform.
struct PanelFrame<Content: View>: View {
    @EnvironmentObject private var store: DashboardStore
    var title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.novaDisplay(27))
            }
            content
        }
        .padding(22)
        .background(store.theme.panel.color.opacity(0.74), in: CutCornerShape(cut: 18))
        .overlay {
            CutCornerShape(cut: 18)
                .stroke(store.theme.borderColor, lineWidth: 1)
        }
    }
}

/// Small labelled value tile (title above, value below) used in the weather and
/// network readout grids. Grows to fill the height it is given so grids stay
/// even.
struct ReadoutTile: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.novaMono(12))
                .foregroundStyle(store.theme.muted)
            Text(value)
                .font(.novaMono(24))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(store.theme.background.color.opacity(0.28))
        .overlay {
            Rectangle().stroke(store.theme.borderColor, lineWidth: 1)
        }
    }
}

/// Placeholder shown in a panel whose expected entity is missing from the
/// dashboard state (e.g. the aircon climate entity is absent). Surfaces the gap
/// rather than rendering an empty control.
struct EmptyStatePanel: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.novaDisplay(22))
                .foregroundStyle(store.theme.accent.color)
            Text(detail)
                .font(.novaMono(13))
                .foregroundStyle(store.theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(store.theme.panel.color.opacity(0.72))
        .overlay { Rectangle().stroke(store.theme.borderColor, lineWidth: 1) }
    }
}

// MARK: - Buttons

/// Icon-over-label control used throughout the lighting and climate surfaces.
///
/// Note: this button does NOT bind itself to the focus graph — the caller adds
/// `.dashboardFocus(focus, equals:)`. That split lets one `ControlButton`
/// definition serve every preset/mode button while each call site owns its
/// focus id.
struct ControlButton: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    let symbol: String
    let isFocused: Bool
    var isActive = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .bold))
            Text(title)
                .font(.novaMono(12))
                .lineLimit(1)
                .minimumScaleFactor(0.56)
        }
        // Fill the frame we're given so the chrome (border/bg) fills a square
        // slot instead of shrinking to content height and leaving a gap.
        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: .infinity)
        .controlChrome(isFocused: isFocused, isActive: isActive)
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}

/// A single-glyph control that binds its own focus id (used for the vertical
/// temperature steppers). Unlike `ControlButton` it carries the focus binding
/// itself via the shared tap target.
struct IconControlButton: View {
    let symbol: String
    var focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus
    let isFocused: Bool
    var isActive = false
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 32, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity)
            .controlChrome(isFocused: isFocused, isActive: isActive)
            .dashboardTapTarget(focus, equals: focusValue, perform: action)
    }
}

/// A zone/room title button in a ribbon column. Shows its title always and its
/// subtitle when focused or expanded; the whole chain it is part of (the focused
/// button plus every expanded ancestor) lights up in the highlight colour, with
/// a thicker border on the focused one so the cursor is unambiguous even though
/// the chain shares a colour.
struct RibbonTitleButton: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    let subtitle: String
    var focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus
    let isFocused: Bool
    let isExpanded: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: compact ? 5 : 7) {
            Text(title)
                .font(.novaDisplay(compact ? 24 : 30))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            if isFocused || isExpanded {
                Text(subtitle)
                    .font(.novaMono(compact ? 12 : 14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)
                    .opacity(0.86)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 18)
        .foregroundStyle(titleColor)
        .background(backgroundColor, in: CutCornerShape(cut: 16))
        .overlay {
            // Focused button gets a thicker border so the cursor is clear even
            // though every in-path button shares the highlight colour.
            CutCornerShape(cut: 16)
                .stroke(lineColor, lineWidth: isFocused ? 3 : 1)
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(store.theme.highlight.color)
                .frame(width: isFocused || isExpanded ? 94 : 42, height: 3)
        }
        .contentShape(CutCornerShape(cut: 16))
        .focusable(true)
        .dashboardFocus(focus, equals: focusValue)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }

    private var backgroundColor: Color {
        // Every button in the chosen chain — the focused one AND every expanded
        // ancestor (Lighting -> Home -> ...) — illuminates in the highlight colour.
        if isFocused || isExpanded { return store.theme.highlight.color }
        return store.theme.panelSoft.color.opacity(0.74)
    }

    private var titleColor: Color {
        if isFocused || isExpanded { return store.theme.titleOnHighlight }
        return store.theme.text
    }

    private var lineColor: Color {
        if isFocused || isExpanded { return store.theme.highlight.color }
        return store.theme.borderColor
    }
}

// MARK: - Vertical toggle

/// A tall two-state toggle: a vertical track with a sliding accent block and a
/// label at each end. The block rests at the `topLabel` end while
/// `isOn == indicatorAtTopWhenOn`, otherwise at the `bottomLabel` end.
///
/// This is the shared body of the aircon Recirculate/Fresh switch and the
/// Outside light On/Off toggle, which use identical chrome but disagree on which
/// end means "on" — hence `indicatorAtTopWhenOn`. The caller sizes the width via
/// an outer `.frame`.
struct VerticalToggleSwitch: View {
    @EnvironmentObject private var store: DashboardStore
    let topLabel: String
    let bottomLabel: String
    let isOn: Bool
    /// When true the accent block sits at the TOP end while `isOn`.
    var indicatorAtTopWhenOn: Bool = false
    let isFocused: Bool
    var isEnabled: Bool = true
    var focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus
    let action: () -> Void

    private var indicatorAlignment: Alignment {
        let onAlignment: Alignment = indicatorAtTopWhenOn ? .top : .bottom
        let offAlignment: Alignment = indicatorAtTopWhenOn ? .bottom : .top
        return isOn ? onAlignment : offAlignment
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(topLabel)
            ZStack(alignment: indicatorAlignment) {
                Rectangle()
                    .fill(store.theme.panel.color.opacity(0.68))
                    .overlay { Rectangle().stroke(store.theme.borderColor, lineWidth: 1) }
                Rectangle()
                    .fill(store.theme.accent.color)
                    .frame(height: 46)
                    .padding(4)
            }
            .frame(width: 40, height: 112)
            Text(bottomLabel)
        }
        .font(.novaMono(14))
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .controlChrome(isFocused: isFocused, isActive: isOn)
        .opacity(isEnabled ? 1 : 0.48)
        .dashboardTapTarget(focus, equals: focusValue) {
            guard isEnabled else { return }
            action()
        }
    }
}
