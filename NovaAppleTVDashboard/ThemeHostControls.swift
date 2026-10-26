import SwiftUI

// The theme button and the HOST button: the column left of the orb on the TV
// (`specs/theme-mode-selector.md`), the foot of the orb's sidebar on the phone.
//
// Adeline, 2026-10-23: "make the theme buttons into a single cycling icon like on
// the web dashboard", and for the host "a single button that shows a pop-up text
// entry modal" (`specs/host-settings.md`).

extension ThemeMode {
    static let cycleFocus = DashboardFocus.action(zone, "cycle")
    static let hostFocus = DashboardFocus.action(zone, "host")

    /// The web's order: follows config → auto → light → dark → follows config.
    static func next(after mode: String) -> String {
        let index = all.firstIndex(of: mode) ?? 0
        return all[(index + 1) % all.count]
    }

    /// SF Symbols standing in for the web's lucide Contrast / SunMoon / Sun / Moon.
    static func symbol(_ mode: String) -> String {
        switch mode {
        case "auto": return "sun.horizon"
        case "light": return "sun.max"
        case "dark": return "moon"
        default: return "circle.lefthalf.filled"
        }
    }

    static func title(_ mode: String) -> String {
        mode == followShared ? "SHARED" : mode.uppercased()
    }
}

struct ThemeHostControls: View {
    @EnvironmentObject private var store: DashboardStore
    let focus: FocusState<DashboardFocus?>.Binding
    /// Raised while the host editor is up, so the band's own input stands down.
    @Binding var editingHost: Bool
    var buttonSize: CGFloat = 120
    var spacing: CGFloat = 18
    var axis: Axis = .vertical
    @State private var draft = ""
    @State private var refused = false
    @State private var keepDraft = false

    private var mode: String { ThemeMode.mode(storeValue: store.themeOverride) }

    var body: some View {
        let layout = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            iconButton(symbol: ThemeMode.symbol(mode), caption: ThemeMode.title(mode),
                       focusValue: ThemeMode.cycleFocus) {
                store.setThemeOverride(ThemeMode.storeValue(ThemeMode.next(after: mode)))
            }
            .accessibilityLabel("Theme: " + ThemeMode.title(mode).lowercased())
            iconButton(symbol: "network", caption: "HOST", focusValue: ThemeMode.hostFocus) {
                // After a refusal, reopen on what was typed so it can be corrected.
                if !keepDraft { draft = HostSettings.stored }
                keepDraft = false
                editingHost = true
            }
            .accessibilityLabel("Dashboard host")
        }
        .alert("Dashboard host", isPresented: $editingHost) {
            TextField("http://nova.local", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Save") {
                // Raised after this alert has gone, or SwiftUI drops it.
                if HostSettings.save(draft) == .invalid {
                    keepDraft = true
                    DispatchQueue.main.async { refused = true }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("In use: " + AppConfig.dashboardBaseURL.absoluteString + ". Leave empty for http://nova.local.")
        }
        .alert("Not a host", isPresented: $refused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\"\(draft)\" is not an http or https address. The host was not changed.")
        }
    }

    /// The dashboard's own icon button, with what it stands for written under it.
    private func iconButton(symbol: String, caption: String, focusValue: DashboardFocus,
                            action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            IconControlButton(symbol: symbol, focus: focus, focusValue: focusValue,
                              isFocused: focus.wrappedValue == focusValue, action: action)
                .frame(width: buttonSize, height: buttonSize)
            Text(caption)
                .font(.novaMono(14))
                .foregroundStyle(store.theme.muted)
                .lineLimit(1)
        }
    }
}
