import SwiftUI

struct PhonoscopeView: View {
    @EnvironmentObject private var phonoscope: PhonoscopeStore
    @EnvironmentObject private var dashboard: DashboardStore
    @FocusState private var capturesRemote: Bool
    @FocusState private var housePartyButtonFocused: Bool
    @FocusState private var themeControlFocus: ThemeControl?
    @State private var showsHousePartyBar = false
    @State private var showsThemeBar = false
    @StateObject private var stream = PhonoscopeStreamClient()
    @State private var reporter = PhonoscopeNowPlayingReporter()
    @State private var rendererEndpoint: PhonoscopeRendererEndpoint?
    @State private var fallbackFramesPerSecond = 0.0
    let onBack: () -> Void

    /// True once the GPU renderer on iridium is actually delivering decoded
    /// frames. Until then the original Metal engine remains the functional
    /// fallback promised by the two-engine Phonoscope contract.
    private var usesStreamedRenderer: Bool {
        stream.hasPresentedFrame
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !usesStreamedRenderer {
                if usesLetterboxedBackground {
                    // Full-screen, with the band resolved in the fragment
                    // shader rather than by a SwiftUI frame and a gradient
                    // overlay. Height, width, vignette opacity and vignette
                    // size are driven parameters now — they change every frame,
                    // and re-running layout at 60 Hz to follow them is the
                    // wrong mechanism. The streamed engine has always resolved
                    // the band in-shader, so this also retires a divergence.
                    FluidBackgroundView(
                        theme: effectiveTheme,
                        baseURL: dashboard.activeBaseURL ?? AppConfig.dashboardBaseURL,
                        blobScale: 4,
                        blobSoftness: 0.45,
                        allowsDisplacementTexture: false,
                        animationSpeed: Float(activeSettings["fluid_speed"] ?? 1),
                        renderScale: 0.25,
                        band: backdropBand
                    )
                    .ignoresSafeArea()
                }

                MetalPhonoscopeView(
                    module: phonoscope.module,
                    signal: phonoscope.signal,
                    settings: activeSettings,
                    driverInterpolatedSettings: phonoscope.driverInterpolatedSettingIDs,
                    theme: effectiveTheme,
                    paletteColors: phonoscope.activeColorTheme?.colors.mapValues(\.vector) ?? [:],
                    transitionDuration: phonoscope.settingTransitionSeconds,
                    transitionPaused: phonoscope.themeInterpolationPaused,
                    reloadGeneration: phonoscope.configuration?.moduleReloadGenerations[phonoscope.module?.id ?? ""] ?? 0,
                    letterboxedBackground: usesLetterboxedBackground,
                    glowOverlay: phonoscope.glowOverlay,
                    centreImage: centreImageState,
                    measuredFramesPerSecond: $fallbackFramesPerSecond
                )
                .ignoresSafeArea()
                // Where the scene layer meets the backdrop on this engine: the
                // backdrop is the view behind, so the blend is a compositor
                // blend rather than arithmetic inside the composite pass.
                // Only meaningful when there IS a backdrop behind it.
                .blendMode(usesLetterboxedBackground
                    ? phonoscope.pictureFrame.sceneBlendMode.swiftUI
                    : .normal)
            }

            if usesStreamedRenderer {
                PhonoscopeStreamView(client: stream)
                    .ignoresSafeArea()
            }

            // The centre slot belongs to the picture, not to this client. The
            // GPU renderer rasterises the message with FreeType using Rajdhani
            // plus Apple Color Emoji and decodes the image with libpng, so both
            // are identical on the television, the macOS viewer and the browser
            // debug view. Drawing either locally as well would double it
            // whenever the stream is up, so this overlay is only for the local
            // Metal fallback path.
            //
            // Which of the two is showing is `phonoscope.centreSlot`, resolved
            // in the same order as `Simulation::submit` in nova-visualiser.
            //
            // Only the MESSAGE is here. The image half moved into the Metal pass
            // (`encodeCentreImagePass`), which runs the same three transitions
            // the streamed renderer does — a flip or a slide is a per-fragment
            // transform of the image plane, not something a SwiftUI transition
            // can approximate, and the two engines have to agree exactly.
            if !usesStreamedRenderer {
                // The glow overlay is the last pass over the picture and the
                // message is part of the picture, so it glows too. On the
                // streamed renderer that is literally one pass over the
                // finished frame; here the message lives in SwiftUI above the
                // Metal view, which cannot be sampled a second time, so the
                // same blur/blend is applied to the layer itself. Close, but
                // not identical: a fallback approximation of an effect the
                // streamed path does exactly. The image, now inside the Metal
                // chain, is under the real overlay pass and needs no such
                // approximation.
                if case let .message(message) = phonoscope.centreSlot {
                    messageLayer(message)
                        .glowOverlay(phonoscope.glowOverlay) { messageLayer(message) }
                        .allowsHitTesting(false)
                }
            }

            if phonoscope.configuration?.statusOverlay != false {
                statusOverlay
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
                switch direction {
                case .up:
                    hideThemeBar()
                case .left:
                    themeControlFocus = previousThemeControl(from: themeControlFocus)
                case .right:
                    themeControlFocus = nextThemeControl(from: themeControlFocus)
                default:
                    break
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
            await startStreamingIfAvailable()
        }
        .onDisappear {
            phonoscope.setHousePartyEnabled(false, fallbackTheme: effectiveTheme)
            phonoscope.leave()
            stream.stop()
            reporter.stop()
        }
    }

    /// Asks Nova where the GPU renderer is and connects to it. The endpoint is
    /// server-side so no household address is baked into the tvOS build, and a
    /// renderer that is absent leaves the explicit connecting surface in place
    /// rather than silently mounting the old renderer during startup.
    private func startStreamingIfAvailable() async {
        let baseURL = dashboard.activeBaseURL ?? AppConfig.dashboardBaseURL

        // The now-playing uplink runs regardless of which engine draws: Nova
        // needs it for house-party lighting and beat resolution either way.
        reporter.start(baseURL: baseURL) {
            let track = phonoscope.track
            return PhonoscopeNowPlayingSnapshot(
                appleMusicId: track?.appleMusicId,
                isrc: track?.isrc,
                title: track?.title ?? "",
                artist: track?.artist ?? "",
                album: track?.album,
                duration: track?.duration ?? 0,
                artworkUrl: track?.artworkUrl,
                genreNames: track?.genreNames ?? [],
                position: phonoscope.signal.time,
                playing: phonoscope.signal.playing,
                hasTrack: track != nil,
                barIndex: phonoscope.signal.barIndex
            )
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/phonoscope/renderer"))
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let endpoint = try? JSONDecoder().decode(PhonoscopeRendererEndpoint.self, from: data),
              endpoint.available
        else { return }
        rendererEndpoint = endpoint
        if let signalURL = endpoint.signalUrl {
            reporter.startSignal(url: signalURL) {
                PhonoscopeResolvedSignalSnapshot(
                    signal: phonoscope.signal,
                    timeSignature: phonoscope.analysis?.timeSignature ?? 4
                )
            }
        }
        stream.start(
            host: endpoint.streamHost,
            srtPort: endpoint.preferredSRTPort.flatMap { UInt16(exactly: $0) },
            tcpPort: UInt16(exactly: endpoint.streamPort) ?? 8_770,
            srtLatencyMs: endpoint.preferredSRTLatencyMs,
            rendererControlURL: baseURL.appendingPathComponent("api/phonoscope/renderer")
        )
    }

    /// The driven band geometry, handed to the fragment shader each frame.
    ///
    /// The vignette colour is the theme's `vignette` palette slot, falling back
    /// to black — the colour the edge gradients were authored with — so a theme
    /// from before that slot existed frames the band exactly as it always did.
    private var backdropBand: FluidBackgroundBand {
        let vignette = phonoscope.activeColorTheme?.colors["vignette"]?.vector
            ?? SIMD4<Float>(0, 0, 0, 1)
        // The theme's backdrop image, if it names one, plus how it is fitted.
        // The extent itself is resolved in the renderer, where the decoded
        // texture's proportions are known.
        let frame = phonoscope.pictureFrame
        return FluidBackgroundBand(
            isEnabled: true,
            heightFraction: Float(min(max(frame.backgroundHeight, 0), 1)),
            widthFraction: Float(min(max(frame.backgroundWidth, 0), 1)),
            vignetteColor: vignette,
            vignetteOpacity: Float(min(max(frame.vignetteOpacity, 0), 1)),
            vignetteSize: Float(max(frame.vignetteSize, 0)),
            imageTo: phonoscope.backgroundImageURL,
            imageFrom: phonoscope.backgroundImageFromURL,
            imageScale: Float(frame.backgroundScale),
            imageFit: frame.backgroundFit,
            imageProportional: frame.backgroundProportional,
            imageProgress: Float(phonoscope.backgroundImageProgress),
            imageParams: phonoscope.backgroundTransition
        )
    }

    private var usesLetterboxedBackground: Bool {
        phonoscope.module?.settings.contains { setting in
            setting.affects?.contains("renderer.fluidBackground.speed") == true
        } == true
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
                themeControl(title: "PREV GROUP", symbol: "backward.fill", control: .previous) {
                    phonoscope.stepThemeGroup(forward: false)
                }
                themeControl(
                    title: phonoscope.themeSwitchingPaused ? "RESUME" : "PAUSE",
                    symbol: phonoscope.themeSwitchingPaused ? "play.fill" : "pause.fill",
                    control: .pause
                ) {
                    phonoscope.toggleThemeSwitching()
                }
                themeControl(title: "NEXT GROUP", symbol: "forward.fill", control: .next) {
                    phonoscope.stepThemeGroup(forward: true)
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

    private func previousThemeControl(from control: ThemeControl?) -> ThemeControl {
        switch control {
        case .previous: return .next
        case .pause: return .previous
        case .next, nil: return .pause
        }
    }

    private func nextThemeControl(from control: ThemeControl?) -> ThemeControl {
        switch control {
        case .previous, nil: return .pause
        case .pause: return .next
        case .next: return .previous
        }
    }

    /// The image half of the centre slot, handed to the Metal pass.
    ///
    /// Everything is already resolved by the store — which two images, how far
    /// through, and the transition the change was latched with. This view only
    /// carries it across, and only on the local fallback: on the streamed path
    /// the image is already baked into the picture, so drawing it again would
    /// double it.
    private var centreImageState: PhonoscopeCentreImageState {
        guard !usesStreamedRenderer, case let .image(url) = phonoscope.centreSlot else {
            // Not showing an image — or showing one that the stream already
            // drew. Either way the local pass has nothing to do. A transition
            // still in flight is dropped with it, because there is no picture
            // left for it to be a transition of.
            return PhonoscopeCentreImageState()
        }
        return PhonoscopeCentreImageState(
            to: url,
            from: phonoscope.centreImageFromURL,
            progress: phonoscope.centreImageProgress,
            params: phonoscope.centreTransition,
            widthFraction: phonoscope.centreImageWidth,
            heightFraction: phonoscope.centreImageHeight,
            fit: phonoscope.centreImageFit,
            proportional: phonoscope.centreImageProportional,
            scale: phonoscope.messageScale)
    }

    private func messageLayer(_ message: String) -> some View {
        Text(message)
            .font(.custom("Rajdhani-Medium", size: 54))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 160)
            .foregroundStyle(effectiveTheme.titleLight.color)
            .scaleEffect(phonoscope.messageScale)
            .shadow(color: .black.opacity(0.7), radius: 8, x: 0, y: 3)
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

private extension View {
    /// Lays a blurred copy of `content` back over this view with the glow
    /// overlay's blend mode.
    ///
    /// Used only on the local Metal fallback path, for the layers that live in
    /// SwiftUI above the Metal view and therefore cannot be folded into its
    /// final pass. `.blur(radius:)` takes a Gaussian sigma in points, which is
    /// the same unit the shared blur contract authors — one blur unit is 1.2
    /// points at the 1080p authoring size.
    @ViewBuilder
    func glowOverlay<Content: View>(
        _ settings: PhonoscopeGlowOverlaySettings,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if settings.isActive {
            overlay {
                content()
                    .blur(radius: min(max(settings.blurAmount, 0), 20) * 1.2)
                    .opacity(min(max(settings.opacity, 0), 100) / 100)
                    .blendMode(settings.blendMode.swiftUI)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}

private enum ThemeControl: Hashable {
    case previous
    case pause
    case next
}

