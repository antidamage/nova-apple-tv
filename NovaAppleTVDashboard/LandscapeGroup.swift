import SwiftUI

struct LandscapeGroup<Content: View>: View {
    @EnvironmentObject private var store: DashboardStore
    let title: String
    @ViewBuilder let content: () -> Content
    /// The group's title runs up a strip at its left edge. It is a label: the group
    /// is always open and the strip cannot be focused or selected.
    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                store.theme.panelSoft.color
                Text(title.uppercased()).font(.novaDisplay(24))
                    .fixedSize().rotationEffect(.degrees(-90))
            }
            .frame(width: 56)
            .foregroundStyle(store.theme.muted)
            .overlay(Rectangle().stroke(store.theme.borderColor, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .background(store.theme.panel.color.opacity(0.8))
        .overlay(Rectangle().stroke(store.theme.borderColor, lineWidth: 1))
    }
}

/// Supported composition primitive. The TV's standard layout deliberately mounts
/// only the primary content. Other surfaces may opt into the advanced section.
struct AdvancedFold<Primary: View, Advanced: View>: View {
    @EnvironmentObject private var store: DashboardStore
    let enabled: Bool
    @Binding var isExpanded: Bool
    let focus: FocusState<DashboardFocus?>.Binding
    let focusValue: DashboardFocus
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let advanced: () -> Advanced
    var body: some View {
        VStack(spacing: 12) {
            primary()
            if enabled {
                ControlButton(title: "ADVANCED", symbol: isExpanded ? "chevron.up" : "chevron.down",
                              isFocused: focus.wrappedValue == focusValue, isActive: isExpanded) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { isExpanded.toggle() }
                }.dashboardFocus(focus, equals: focusValue)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                if isExpanded { advanced().transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
    }
}
