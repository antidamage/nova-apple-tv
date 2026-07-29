import SwiftUI

struct PhonoscopeView: View {
    @EnvironmentObject private var phonoscope: PhonoscopeStore
    @EnvironmentObject private var dashboard: DashboardStore
    @FocusState private var capturesRemote: Bool
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if usesLetterboxedBackground {
                GeometryReader { geometry in
                    FluidBackgroundView(
                        theme: dashboard.theme,
                        baseURL: dashboard.activeBaseURL ?? AppConfig.dashboardBaseURL,
                        blobScale: 4,
                        blobSoftness: 0.45
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
                theme: dashboard.theme,
                letterboxedBackground: usesLetterboxedBackground
            )
            .ignoresSafeArea()

            if phonoscope.configuration?.statusOverlay != false {
                statusOverlay
            }

            // Keep a real focus target inside the full-screen surface. Without
            // one, tvOS may route Menu/Back to the application lifecycle before
            // the dashboard's parent handler can consume it.
            Color.white
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .focusable(true)
                .focused($capturesRemote)
        }
        .onExitCommand(perform: onBack)
        .onAppear {
            DispatchQueue.main.async {
                capturesRemote = true
            }
        }
        .task {
            phonoscope.enter()
        }
        .onDisappear {
            phonoscope.leave()
        }
    }

    private var activeSettings: [String: Double] {
        guard let module = phonoscope.module else { return [:] }
        var values = Dictionary(uniqueKeysWithValues: module.settings.map { ($0.id, $0.default) })
        let configured = phonoscope.configuration?.moduleSettings[module.id] ?? [:]
        values.merge(configured) { _, configured in configured }
        return values
    }

    private var usesLetterboxedBackground: Bool {
        phonoscope.module?.id == "particle-ripples"
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
                        .foregroundStyle(.white.opacity(0.62))
                    if !phonoscope.signal.lyricCurrent.isEmpty {
                        Text(phonoscope.signal.lyricCurrent)
                            .font(.custom("Rajdhani-Medium", size: 22))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .padding(.top, 5)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(phonoscope.module?.name.uppercased() ?? "LOADING MODULE")
                    Text(phonoscope.status)
                        .foregroundStyle(.white.opacity(0.58))
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
        .foregroundStyle(.white.opacity(0.9))
        .allowsHitTesting(false)
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
