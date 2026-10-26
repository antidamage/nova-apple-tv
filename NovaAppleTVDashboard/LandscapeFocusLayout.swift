import Foundation

/// The band's panels and controls for the current state of the dashboard, as the
/// navigation sees them (`BandMap`). The Home and Systems lists are what the
/// household lists on screen; the controls beside each list are the selected
/// row's.
func bandSpec(state: DashboardState, homeSelection: String, systemSelection: String,
              themeOverride: String = "") -> BandSpec {
    var spec = BandSpec()
    spec.themeSelection = ThemeMode.mode(storeValue: themeOverride)
    spec.hasQuickLights = state.homeZone != nil
    spec.hasQuickClimate = state.climateZone != nil
    spec.rooms = ([state.homeZone].compactMap { $0 } + state.homeChildZones.filter(\.canUseLightingControls))
        .map { BandSpec.Room(id: $0.id, hasControls: $0.canUseLightingControls) }
    spec.homeSelection = homeSelection
    spec.systems = state.primaryZones.filter { !$0.isHomeZone }.map { zone in
        let kind: BandSpec.SystemKind = zone.isClimateZone ? .climate
            : zone.isOutsideZone ? .outside(hasPower: !zone.lightEntities.isEmpty)
            : zone.isNetworkZone ? .network
            : .plain
        return BandSpec.System(zoneID: zone.id, kind: kind)
    } + [BandSpec.System(zoneID: "__timers", kind: .timers),
         BandSpec.System(zoneID: phonoscopeZoneID, kind: .phonoscope)]
    spec.systemSelection = systemSelection
    return spec
}
