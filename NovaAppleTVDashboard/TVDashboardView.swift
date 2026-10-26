import Darwin
import Foundation
import SwiftUI
import UIKit

// Stable owner of background, camera presentation and the Phonoscope lifecycle.
// LandscapeDashboard owns the home-control layout, focus and encoder editing.

struct TVDashboardView: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var phonoscope: PhonoscopeStore
    @EnvironmentObject private var activity: NovaActivityStore
    @EnvironmentObject private var speech: VoiceSpeechStore
    @EnvironmentObject private var presets: PresetPlaybackStore
    @StateObject private var remote = RemoteSwipeInput()
    /// Set when the visualiser closes, so the band comes back on the Phonoscope row.
    @State private var returningFromPhonoscope = false
    @Environment(\.scenePhase) private var scenePhase
    // Device verification can launch straight into the streamed surface without
    // changing normal startup or adding a production-only navigation path.
    @State private var isPhonoscopePresented =
        ProcessInfo.processInfo.arguments.contains("--launch-phonoscope")
        || ProcessInfo.processInfo.environment["NOVA_LAUNCH_PHONOSCOPE"] == "1"

    var body: some View {
        ZStack {
            if !isPhonoscopePresented {
                Group {
                FluidBackgroundView(theme: store.theme, baseURL: store.activeBaseURL ?? AppConfig.dashboardBaseURL)
                    .ignoresSafeArea()

                // Horizontal control band: the whole dashboard flows left->right
                // inside a fixed-height band (a fraction of the screen height, from
                // the shared theme's `layout.tvHeightFraction`). The band is
                // vertically centred, leaving ambient fluid background above/below.
                // Hosted so the focus engine cannot move focus on its own and the
                // remote's touch surface is read directly (RemoteInputHost). The
                // host is a separate view tree, so it is given what it inherits.
                #if os(tvOS)
                RemoteInputHost(input: remote) {
                    LandscapeDashboard(onOpenPhonoscope: openPhonoscope, startOnPhonoscope: returningFromPhonoscope,
                                       onStarted: { returningFromPhonoscope = false })
                        .environmentObject(store)
                        .environmentObject(activity)
                        .environmentObject(speech)
                        .environmentObject(phonoscope)
                        .environmentObject(presets)
                        .environmentObject(remote)
                        .environment(\.scenePhase, scenePhase)
                        .foregroundStyle(store.theme.text)
                        .focusEffectDisabled()
                }
                .ignoresSafeArea()
                #else
                // The phone: no remote to host, and the same band drawn to the
                // phone's height (PhoneCanvas, specs/ios-touch-app.md).
                PhoneCanvas {
                    LandscapeDashboard(onOpenPhonoscope: openPhonoscope, startOnPhonoscope: returningFromPhonoscope,
                                       onStarted: { returningFromPhonoscope = false })
                        .environmentObject(remote)
                        .foregroundStyle(store.theme.text)
                }
                // Every tap is told to the unlocked dials, which lock when it lands
                // outside them; the tap still reaches what it landed on.
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    NotificationCenter.default.post(name: RotaryTouch.outsideTap, object: tap.location)
                })
                #endif

            }
                .transition(.opacity)
            }

            if isPhonoscopePresented {
                PhonoscopeView(onBack: dismissPhonoscope)
                    .environmentObject(phonoscope)
                    .transition(.opacity)
                    .zIndex(10_000)
            }
        }
        .background(Color.black)
        .animation(
            .easeInOut(duration: Double(phonoscope.configuration?.transitionMs ?? 600) / 1_000),
            value: isPhonoscopePresented
        )
        .foregroundStyle(store.theme.text)
        .focusEffectDisabled()
        #if os(tvOS)
        .onExitCommand { if isPhonoscopePresented { dismissPhonoscope() } }
        #endif
        .onChange(of: isPhonoscopePresented) { _, presented in
            setScreenAwake(presented && phonoscope.signal.playing)
            if !presented, phonoscope.housePartyEnabled {
                // The dashboard is fully transparent while Phonoscope is up.
                // Keep its followed palette intact through the crossfade back,
                // then visibly ease from those colours to the configured theme.
                store.clearVisualizerColorOverride(
                    duration: phonoscopeTransitionSeconds,
                    delay: phonoscopeTransitionSeconds
                )
            }
        }
        .onChange(of: phonoscope.signal.playing) { _, playing in
            guard isPhonoscopePresented else { return }
            setScreenAwake(playing)
        }
        .onChange(of: phonoscope.visualizerTheme) { _, visualizerTheme in
            guard phonoscope.housePartyEnabled else { return }
            // Already eased upstream by `PhonoscopeStore.advanceTheme`, so this
            // tracks it directly rather than filtering it a second time.
            store.setVisualizerColorOverride(visualizerTheme)
        }
        .onChange(of: store.followVisualizerWhenActive) { _, followsVisualizer in
            if followsVisualizer, phonoscope.housePartyEnabled {
                store.setVisualizerColorOverride(
                    phonoscope.visualizerTheme,
                    duration: phonoscopeTransitionSeconds
                )
            } else if !followsVisualizer {
                store.clearVisualizerColorOverride(duration: phonoscopeTransitionSeconds)
            }
        }
        .onChange(of: phonoscope.housePartyEnabled) { _, housePartyEnabled in
            if housePartyEnabled {
                store.setVisualizerColorOverride(
                    phonoscope.visualizerTheme,
                    duration: phonoscopeTransitionSeconds
                )
            } else {
                store.clearVisualizerColorOverride(duration: phonoscopeTransitionSeconds)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // tvOS can rebuild or reactivate the SwiftUI scene after overlays
            // and interruptions. Reassert the lease when the app returns so
            // the system screen saver cannot take over a running visualiser.
            if phase == .active {
                setScreenAwake(isPhonoscopePresented && phonoscope.signal.playing)
            }
        }
        .onDisappear {
            setScreenAwake(false)
        }
        // Full-screen camera player, hosted by the root so it survives the zone
        // collapsing or the camera tile unmounting while the modal holds focus.
        .fullScreenCover(isPresented: cameraCoverBinding) {
            if let id = store.fullScreenCameraID {
                CameraFullScreenPlayer(
                    url: AppConfig.cameraURL(cameraID: id, path: "index.m3u8")
                )
                .ignoresSafeArea()
                #if os(iOS)
                // Menu closes it on the TV; the phone needs a button.
                .overlay(alignment: .topLeading) {
                    Button { store.fullScreenCameraID = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .accessibilityLabel("Close camera")
                }
                #endif
            }
        }
    }

    // Drives the full-screen camera cover from the store-owned camera id.
    private var cameraCoverBinding: Binding<Bool> {
        Binding(
            get: { store.fullScreenCameraID != nil },
            set: { presented in
                if !presented { store.fullScreenCameraID = nil }
            }
        )
    }

    private func dismissPhonoscope() {
        returningFromPhonoscope = true
        withAnimation {
            isPhonoscopePresented = false
        }
    }

    private var phonoscopeTransitionSeconds: Double {
        Double(phonoscope.configuration?.transitionMs ?? 600) / 1_000
    }

    private func openPhonoscope() {
        withAnimation {
            isPhonoscopePresented = true
        }
    }

    /// Phonoscope is an intentionally unattended, continuously animated
    /// display. Own the global UIKit idle-timer lease at this stable root
    /// rather than the transient Metal child view so SwiftUI focus/view
    /// reconstruction cannot accidentally release it.
    private func setScreenAwake(_ awake: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != awake else { return }
        UIApplication.shared.isIdleTimerDisabled = awake
        debugInteractionLog("Phonoscope screen-awake lease \(awake ? "enabled" : "released")")
    }

}
