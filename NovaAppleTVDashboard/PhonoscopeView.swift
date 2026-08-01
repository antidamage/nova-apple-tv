import SwiftUI

struct PhonoscopeView: View {
    @EnvironmentObject private var phonoscope: PhonoscopeStore
    @EnvironmentObject private var dashboard: DashboardStore
    @FocusState private var capturesRemote: Bool
    @FocusState private var housePartyButtonFocused: Bool
    @FocusState private var themeControlFocus: ThemeControl?
    @State private var showsHousePartyBar = false
    @State private var showsThemeBar = false
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if usesLetterboxedBackground {
                GeometryReader { geometry in
                    FluidBackgroundView(
                        theme: effectiveTheme,
                        baseURL: dashboard.activeBaseURL ?? AppConfig.dashboardBaseURL,
                        blobScale: 4,
                        blobSoftness: 0.45,
                        allowsDisplacementTexture: false
                    )
                    .overlay { PhonoscopeEdgeVignette() }
                    .frame(width: geometry.size.width, height: geometry.size.height / 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .ignoresSafeArea()
            }

            MetalPhonoscopeView(
                module: phonoscope.module,
                signal: phonoscope.signal,
                settings: activeSettings,
                driverInterpolatedSettings: phonoscope.driverInterpolatedSettingIDs,
                theme: effectiveTheme,
                paletteColors: phonoscope.activeColorTheme?.colors.mapValues(\.vector) ?? [:],
                quality: phonoscope.configuration?.quality ?? "auto",
                transitionDuration: phonoscope.settingTransitionSeconds,
                transitionPaused: phonoscope.themeInterpolationPaused,
                reloadGeneration: phonoscope.configuration?.moduleReloadGenerations[phonoscope.module?.id ?? ""] ?? 0,
                letterboxedBackground: usesLetterboxedBackground
            )
            .ignoresSafeArea()

            if phonoscope.configuration?.statusOverlay != false {
                statusOverlay
            }

            if let message = phonoscope.configuration?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                Text(message)
                    .font(.novaDisplay(52))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(effectiveTheme.clockText)
                    .opacity(visualiserOpacity("primaryText"))
                    .scaleEffect(phonoscope.messageScale, anchor: .center)
                    .lineLimit(3)
                    .frame(maxWidth: 1_280)
                    .padding(.horizontal, 80)
                    .allowsHitTesting(false)
            }

            if showsHousePartyBar {
                housePartyBar
            }

            if showsThemeBar {
                themeBar
            }

            // Keep a real focus target inside the full-screen surface. Without
            // one, tvOS may route Menu/Back to the application lifecycle before
            // the dashboard's parent handler can consume it.
            Color.clear
                .frame(width: 1, height: 1)
                .contentShape(Rectangle())
                .focusable(true)
                .focused($capturesRemote)
                .onTapGesture {
                    phonoscope.togglePlayback()
                }
        }
        .onExitCommand(perform: onBack)
        .onMoveCommand { direction in
            if showsHousePartyBar {
                if direction == .down {
                    hideHousePartyBar()
                }
                return
            }
            if showsThemeBar {
                if direction == .up {
                    hideThemeBar()
                }
                return
            }
            switch direction {
            case .left:
                phonoscope.skipSong(forward: false)
            case .right:
                phonoscope.skipSong(forward: true)
            case .up:
                showsHousePartyBar = true
                capturesRemote = false
                DispatchQueue.main.async {
                    housePartyButtonFocused = true
                }
            case .down:
                showsThemeBar = true
                capturesRemote = false
                DispatchQueue.main.async {
                    themeControlFocus = .pause
                }
            default:
                break
            }
        }
        .onAppear {
            showsHousePartyBar = false
            showsThemeBar = false
            phonoscope.setHousePartyEnabled(false, fallbackTheme: effectiveTheme)
            DispatchQueue.main.async {
                capturesRemote = true
            }
        }
        .onChange(of: housePartyButtonFocused) { wasFocused, isFocused in
            if showsHousePartyBar, wasFocused, !isFocused {
                hideHousePartyBar()
            }
        }
        .onChange(of: themeControlFocus) { previousFocus, nextFocus in
            if showsThemeBar, previousFocus != nil, nextFocus == nil {
                hideThemeBar()
            }
        }
        .task {
            phonoscope.enter(fallbackTheme: dashboard.theme)
        }
        .onDisappear {
            phonoscope.setHousePartyEnabled(false, fallbackTheme: effectiveTheme)
            phonoscope.leave()
        }
    }

    private var activeSettings: [String: Double] {
        guard let module = phonoscope.module else { return [:] }
        if !phonoscope.resolvedModuleSettings.isEmpty {
            return phonoscope.resolvedModuleSettings
        }
        var values = Dictionary(uniqueKeysWithValues: module.settings.map { ($0.id, $0.default) })
        let configured = phonoscope.configuration?.moduleSettings[module.id] ?? [:]
        values.merge(configured) { _, configured in configured }
        return values
    }

    private var effectiveTheme: DashboardTheme {
        phonoscope.visualizerTheme ?? dashboard.theme
    }

    private var usesLetterboxedBackground: Bool {
        phonoscope.module?.id == "particle-ripples"
    }

    private var housePartyBar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("HOUSE PARTY")
                    .font(.novaDisplay(32))
                    .foregroundStyle(Color(white: 0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .background(housePartyBarColor)
                    .focusable(true)
                    .focusEffectDisabled()
                    .focused($housePartyButtonFocused)
                    .onTapGesture {
                    phonoscope.setHousePartyEnabled(!phonoscope.housePartyEnabled, fallbackTheme: effectiveTheme)
                    hideHousePartyBar()
                    }
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(phonoscope.housePartyEnabled ? "On" : "Off")
                .frame(height: geometry.size.height * 0.1)
            }
        }
        .ignoresSafeArea()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var themeBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                themeControl(title: "PREVIOUS", symbol: "backward.fill", control: .previous) {
                    phonoscope.stepTheme(forward: false)
                }
                themeControl(
                    title: phonoscope.themeSwitchingPaused ? "RESUME" : "PAUSE",
                    symbol: phonoscope.themeSwitchingPaused ? "play.fill" : "pause.fill",
                    control: .pause
                ) {
                    phonoscope.toggleThemeSwitching()
                }
                themeControl(title: "NEXT", symbol: "forward.fill", control: .next) {
                    phonoscope.stepTheme(forward: true)
                }
            }
            .frame(width: 560, height: 92)
            .padding(.top, 34)
            .padding(.bottom, 18)
            .padding(.horizontal, 28)
            .background(themeBarCharcoal, in: CutCornerShape(cut: 18))
            .overlay {
                CutCornerShape(cut: 18).stroke(effectiveTheme.borderColor, lineWidth: 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func themeControl(
        title: String,
        symbol: String,
        control: ThemeControl,
        action: @escaping () -> Void
    ) -> some View {
        ControlButton(
            title: title,
            symbol: symbol,
            isFocused: themeControlFocus == control,
            isActive: control == .pause && phonoscope.themeSwitchingPaused,
            focusedBackground: themeBarCharcoal,
            focusedBorder: dashboard.theme.highlight.color,
            action: action
        )
        .focused($themeControlFocus, equals: control)
    }

    private var themeBarCharcoal: Color {
        Color(red: 0.105, green: 0.11, blue: 0.12)
    }

    private var housePartyBarColor: Color {
        Color(red: 0.105, green: 0.11, blue: 0.12)
    }

    private func hideHousePartyBar() {
        showsHousePartyBar = false
        housePartyButtonFocused = false
        DispatchQueue.main.async {
            capturesRemote = true
        }
    }

    private func hideThemeBar() {
        showsThemeBar = false
        themeControlFocus = nil
        DispatchQueue.main.async {
            capturesRemote = true
        }
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(phonoscope.track?.title.uppercased() ?? "PHONOSCOPE")
                        .font(.custom("Rajdhani-SemiBold", size: 28))
                    Text(trackDetail)
                        .font(.custom("ShareTechMono-Regular", size: 16))
                        .foregroundStyle(effectiveTheme.titleLight.color.opacity(0.72))
                    if !phonoscope.signal.lyricCurrent.isEmpty {
                        Text(phonoscope.signal.lyricCurrent)
                            .font(.custom("Rajdhani-Medium", size: 22))
                            .foregroundStyle(effectiveTheme.titleLight.color)
                            .lineLimit(1)
                            .padding(.top, 5)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(phonoscope.module?.name.uppercased() ?? "LOADING MODULE")
                    Text(phonoscope.status)
                        .foregroundStyle(effectiveTheme.titleLight.color.opacity(0.68))
                    if let error = phonoscope.errorMessage {
                        Text(error)
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                }
                .font(.custom("ShareTechMono-Regular", size: 14))
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 34)
        }
        .foregroundStyle(effectiveTheme.titleLight.color)
        .opacity(visualiserOpacity("secondaryText"))
        .allowsHitTesting(false)
    }

    private func visualiserOpacity(_ slot: String) -> Double {
        max(0, min(100, phonoscope.activeColorTheme?.colors[slot]?.opacity ?? 100)) / 100
    }

    private var trackDetail: String {
        guard let track = phonoscope.track else {
            return "AMBIENT CLOCK • WAITING FOR APPLE MUSIC"
        }
        let bpm = Int((phonoscope.analysis?.bpm ?? phonoscope.signal.bpm).rounded())
        let album = track.album.map { " • \($0)" } ?? ""
        return "\(track.artist)\(album) • \(bpm) BPM"
    }
}

private enum ThemeControl: Hashable {
    case previous
    case pause
    case next
}

private struct PhonoscopeEdgeVignette: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.96), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.82),
                    .init(color: .black.opacity(0.96), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.96), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.96), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}
