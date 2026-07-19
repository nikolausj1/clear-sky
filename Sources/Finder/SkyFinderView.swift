import SwiftUI
import UIKit

/// What to open Sky Finder targeting — an `Identifiable` wrapper so `.fullScreenCover(item:)`
/// can present it, and so re-tapping a different "Find" button (a new `SkyFinderPresentation`
/// with a new `id`) reliably re-presents even if one somehow dismissed and re-opened rapidly.
struct SkyFinderPresentation: Identifiable {
    let id = UUID()
    /// `nil` = free-explore mode.
    var initialKind: SkyFinderTarget.Kind?
    /// Sim-verify-only escape hatch for the `-showFinder iss` launch-arg hook: the ingress paths
    /// that matter in real use (planet/moon rows, a specific satellite pass row) always already
    /// have the exact `SkyFinderTarget.Kind` in hand (a `SatellitePass` for the satellite case),
    /// so they set `initialKind` directly. The launch-arg hook fires before `SkyFinderView` has
    /// loaded any pass data at all, so it can only name a `SatelliteKind` and let the view resolve
    /// it to a concrete `Kind` once its own load finishes — see `SkyFinderView`'s `.task`.
    var initialSatelliteKindFallback: SatelliteKind?

    init(initialKind: SkyFinderTarget.Kind? = nil, initialSatelliteKindFallback: SatelliteKind? = nil) {
        self.initialKind = initialKind
        self.initialSatelliteKindFallback = initialSatelliteKindFallback
    }
}

/// `-showFinder explore|moon|mercury|venus|mars|jupiter|saturn|iss` — sim-verify only (`simctl`
/// can't tap a "Find" button), parsed in `NavigationShell`, threaded through `ForecastView`/
/// `ForecastPageView` the same way `-showPeopleSheet` already is.
enum SkyFinderLaunchArgTarget: String {
    case explore, moon, mercury, venus, mars, jupiter, saturn, iss

    var presentation: SkyFinderPresentation {
        switch self {
        case .explore: return SkyFinderPresentation()
        case .moon: return SkyFinderPresentation(initialKind: .moon())
        case .mercury: return SkyFinderPresentation(initialKind: .planet(.mercury))
        case .venus: return SkyFinderPresentation(initialKind: .planet(.venus))
        case .mars: return SkyFinderPresentation(initialKind: .planet(.mars))
        case .jupiter: return SkyFinderPresentation(initialKind: .planet(.jupiter))
        case .saturn: return SkyFinderPresentation(initialKind: .planet(.saturn))
        case .iss: return SkyFinderPresentation(initialSatelliteKindFallback: .iss)
        }
    }
}

/// Sky Finder: point the phone at the sky, get guided to tonight's objects. Full-screen cover
/// presented from the Tonight's Sky card / true-sky hero (see those files' `onOpenFinder`/
/// `onFindPlanetTap` call sites). Owns its own data load (astronomy + satellite passes) rather
/// than being handed a snapshot from its presenter, mirroring `DoodleHeaderView`'s own
/// independent fetch — `SkyTonightService`'s in-memory cache/in-flight de-dup means this never
/// double-hits the network for the same (location, evening) `TonightSkyCard` already loaded.
///
/// **Scene coordinate mapping.** This is a directional guidance tool, not a camera AR overlay —
/// there's no live camera feed, matching the work order's "deep-indigo (non-camera)" spec. The
/// on-screen crosshair always sits at dead center (by definition: that's "where the phone is
/// pointing"); everything else — the horizon line, the target marker, the edge arrow — is placed
/// relative to it using a fixed `pointsPerDegree` scale, the same "direction, not a literal
/// projected-FOV arrow" simplification `FinderGuidance.GuidanceDelta` itself documents.
struct SkyFinderView: View {
    let location: SavedLocation
    let date: Date
    var presentation: SkyFinderPresentation = SkyFinderPresentation()

    @Environment(\.dismiss) private var dismiss
    @State private var adapter = DeviceMotionAdapter()
    private let journalStore = SkyJournalStore.shared

    @State private var astronomy: SkyTonight.TonightSky?
    @State private var satellitePasses: [SatellitePass] = []
    @State private var selectedKind: SkyFinderTarget.Kind?
    @State private var now = Date()
    @State private var isPresentingJournal = false
    @State private var lastHapticFireDate = Date.distantPast
    @State private var hasFiredLockHaptic = false
    @State private var justLoggedSeen = false

    /// Screen-space scale for both the horizon line's vertical offset and the target marker's
    /// radial placement — tuned so the ~35° "target marker visible" cutoff (`nearFieldThresholdDeg`)
    /// lands comfortably inside a phone screen (35° × 4pt/° = 140pt from center).
    private static let pointsPerDegree: CGFloat = 4.0
    private static let nearFieldThresholdDeg = 35.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background

                switch adapter.availability {
                case .unavailable(let reason):
                    noDeviceState(reason: reason)
                case .available:
                    horizonScene(in: proxy.size)
                    ribbon(in: proxy.size)

                    VStack(spacing: 0) {
                        topBar
                        pickerChips
                        if let hint = adapter.calibrationHint {
                            calibrationBanner(hint)
                        }
                        Spacer(minLength: 0)
                        if selectedKind == nil {
                            freeExploreLine
                                .padding(.bottom, 24)
                        } else {
                            lockOrApproachCard
                                .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.09))
        .task {
            selectedKind = presentation.initialKind
            await loadData()
            if selectedKind == nil, let fallbackKind = presentation.initialSatelliteKindFallback,
               let match = satellitePasses.first(where: { $0.satellite.kind == fallbackKind }) {
                selectedKind = .satellite(match)
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { tick in
            now = tick
            tickHaptics()
        }
        .sheet(isPresented: $isPresentingJournal) {
            SkyJournalView(store: journalStore)
        }
        .statusBarHidden()
        .onDisappear {
            adapter.stop()
        }
    }

    // MARK: - Data load

    private func loadData() async {
        astronomy = SkyTonightService.astronomy(latitude: location.latitude, longitude: location.longitude, date: date, timeZone: .current)
        let result = await SkyTonightService.shared.state(
            locationId: location.id, latitude: location.latitude, longitude: location.longitude,
            date: date, timeZone: .current, overrides: nil
        )
        satellitePasses = SkyTonightService.availableValue(result.satellites) ?? []
        // Demo mode has no real astronomy/network dependency to wait on for its own canned
        // target, but real planet/moon/satellite picking still needs this same load — so demo
        // mode rides along on it rather than a separate path.
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.05, blue: 0.14), Color(red: 0.02, green: 0.02, blue: 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { proxy in
                ForEach(Array(Self.starPositions.enumerated()), id: \.offset) { _, star in
                    Circle()
                        .fill(Color.white.opacity(star.opacity))
                        .frame(width: star.diameter, height: star.diameter)
                        .position(x: proxy.size.width * star.x, y: proxy.size.height * star.y)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// ~50 fixed star-speck positions, deterministically generated once (a simple seeded LCG, not
    /// `Double.random`, so this array is identical every launch — no need for it to differ, and a
    /// stable seed keeps sim-verify screenshots reproducible run to run).
    private static let starPositions: [(x: CGFloat, y: CGFloat, diameter: CGFloat, opacity: Double)] = {
        var seed: UInt64 = 0x5A17
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        return (0..<56).map { _ in
            (CGFloat(next()), CGFloat(next()), CGFloat(next() > 0.85 ? 2.0 : 1.0), 0.25 + next() * 0.35)
        }
    }()

    // MARK: - No-device state

    private func noDeviceState(reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "iphone.gen1.slash")
                .font(.system(size: 44))
                .foregroundStyle(Color.white.opacity(0.5))
            Text("Sky Finder needs a real device")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
            closeButton
                .padding(.bottom, 24)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            closeButton
            Spacer()
            Button {
                isPresentingJournal = true
            } label: {
                Image(systemName: "book.closed.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sky Journal")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Sky Finder")
    }

    // MARK: - Picker chips

    private var pickerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Explore", isSelected: selectedKind == nil) { selectedKind = nil }
                ForEach(pickerKinds, id: \.id) { kind in
                    chip(title: kind.name, isSelected: selectedKind == kind) { selectedKind = kind }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    private var pickerKinds: [SkyFinderTarget.Kind] {
        var kinds: [SkyFinderTarget.Kind] = [.moon()]
        if let astronomy {
            kinds += astronomy.planets.filter(\.isVisibleTonight).map { .planet($0.body) }
        }
        kinds += satellitePasses.map { .satellite($0) }
        return kinds
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Calibration banner

    private func calibrationBanner(_ hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location.north.line")
                .font(.footnote)
            Text(hint)
                .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.28), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Horizon + crosshair scene

    private var currentReading: DeviceMotionAdapter.Reading { adapter.reading }

    private var targetPosition: (azimuthDeg: Double, altitudeDeg: Double)? {
        guard let selectedKind else { return nil }
        return SkyFinderTarget.position(for: selectedKind, at: now, location: location, passes: satellitePasses)
    }

    private var guidanceDelta: FinderGuidance.GuidanceDelta? {
        guard let targetPosition else { return nil }
        return FinderGuidance.delta(
            from: (azimuthDeg: currentReading.azimuthDeg, altitudeDeg: currentReading.altitudeDeg),
            to: targetPosition,
            deviceRollRad: currentReading.deviceRollRad
        )
    }

    private func horizonScene(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Horizon: world altitude 0 sits `currentAltitude * pointsPerDegree` below where it would
        // be if the phone were level — i.e. tilting the phone UP moves the drawn horizon line
        // DOWN the screen, since you're now looking further above it.
        let horizonY = center.y + CGFloat(currentReading.altitudeDeg) * Self.pointsPerDegree

        return ZStack {
            Group {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: size.width * 1.6, height: 1)
                    .position(x: center.x, y: horizonY)
                ForEach(Self.horizonTicks, id: \.label) { tick in
                    horizonTickMark(tick, center: center, horizonY: horizonY)
                }
            }
            // World-referenced geometry drawn in screen space needs to counter-rotate by the
            // device's own roll to still read correctly on a tilted screen — same rationale
            // `FinderGuidance.delta(deviceRollRad:)` documents for the arrow angle.
            .rotationEffect(.radians(-currentReading.deviceRollRad), anchor: UnitPoint(x: center.x / size.width, y: center.y / size.height))

            crosshair(center: center)

            if let guidanceDelta, let selectedKind {
                if guidanceDelta.angularSeparationDeg <= Self.nearFieldThresholdDeg {
                    targetMarker(delta: guidanceDelta, center: center, kind: selectedKind)
                } else {
                    edgeArrow(delta: guidanceDelta, center: center, size: size)
                }
            }
        }
    }

    private static let horizonTicks: [(label: String, azimuthDeg: Double)] = [
        ("N", 0), ("E", 90), ("S", 180), ("W", 270),
    ]

    private func horizonTickMark(_ tick: (label: String, azimuthDeg: Double), center: CGPoint, horizonY: CGFloat) -> some View {
        let azOffset = FinderGuidance.shortestAzimuthDeltaDeg(from: currentReading.azimuthDeg, to: tick.azimuthDeg)
        let x = center.x + CGFloat(azOffset) * Self.pointsPerDegree
        return VStack(spacing: 2) {
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 10)
            Text(tick.label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .position(x: x, y: horizonY + 14)
    }

    private func crosshair(center: CGPoint) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                .frame(width: 34, height: 34)
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1, height: 10).offset(y: -22)
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1, height: 10).offset(y: 22)
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 10, height: 1).offset(x: -22)
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 10, height: 1).offset(x: 22)
        }
        .position(center)
    }

    /// The target marker within `nearFieldThresholdDeg` — placed at a polar offset from center
    /// (`screenArrowAngleRad`, `angularSeparationDeg` scaled by `pointsPerDegree`), blooming
    /// (bigger + brighter glow) once locked.
    private func targetMarker(delta: FinderGuidance.GuidanceDelta, center: CGPoint, kind: SkyFinderTarget.Kind) -> some View {
        let radius = CGFloat(delta.angularSeparationDeg) * Self.pointsPerDegree
        let angle = delta.screenArrowAngleRad
        let point = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        let isLocked = delta.isOnTarget
        let color = targetColor(for: kind)

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [color.opacity(isLocked ? 0.55 : 0.3), color.opacity(0)], center: .center, startRadius: 0, endRadius: isLocked ? 26 : 16)
                )
                .frame(width: isLocked ? 52 : 32, height: isLocked ? 52 : 32)
            Circle()
                .fill(color)
                .frame(width: isLocked ? 14 : 9, height: isLocked ? 14 : 9)
        }
        .position(point)
        .animation(.easeOut(duration: 0.2), value: isLocked)
    }

    private func edgeArrow(delta: FinderGuidance.GuidanceDelta, center: CGPoint, size: CGSize) -> some View {
        let radius = min(size.width, size.height) * 0.34
        let angle = delta.screenArrowAngleRad
        let point = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        return VStack(spacing: 4) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 22))
                .rotationEffect(.radians(angle))
            Text("\(Int(delta.angularSeparationDeg.rounded()))°")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .position(point)
    }

    private func targetColor(for kind: SkyFinderTarget.Kind) -> Color {
        switch kind.base {
        case .moon: return .white
        case .planet(let body): return TrueSkyLayer.dotColor(for: body)
        case .satellite: return Color.clearSkyAccentOnDark
        }
    }

    // MARK: - Free explore

    private var freeExploreLine: some View {
        VStack(spacing: 6) {
            Text("Pointing at az \(Int(currentReading.azimuthDeg.rounded()))° · alt \(Int(currentReading.altitudeDeg.rounded()))°")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
            if let nearest = nearestObjectWithinRange {
                Text("Nearest: \(nearest.name), \(Int(nearest.separationDeg.rounded()))° away")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var nearestObjectWithinRange: (name: String, separationDeg: Double)? {
        let candidates = pickerKinds.compactMap { kind -> (name: String, separationDeg: Double)? in
            guard let position = SkyFinderTarget.position(for: kind, at: now, location: location, passes: satellitePasses) else { return nil }
            let separation = FinderGuidance.angularSeparationDeg(
                az1: currentReading.azimuthDeg, alt1: currentReading.altitudeDeg,
                az2: position.azimuthDeg, alt2: position.altitudeDeg
            )
            return (kind.name, separation)
        }
        return candidates.filter { $0.separationDeg <= 15 }.min { $0.separationDeg < $1.separationDeg }
    }

    // MARK: - Lock / approach card

    @ViewBuilder
    private var lockOrApproachCard: some View {
        if let selectedKind, let guidanceDelta {
            VStack(spacing: 10) {
                Text(selectedKind.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if guidanceDelta.isOnTarget {
                    if let fact = SkyFinderTarget.lockFact(for: selectedKind, planets: astronomy?.planets ?? [], moon: astronomy?.moon, passes: satellitePasses) {
                        Text(fact)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    if canLogSighting(selectedKind) {
                        seenButton(for: selectedKind)
                    }
                } else {
                    Text(riseWaitingText(for: selectedKind) ?? "\(Int(guidanceDelta.angularSeparationDeg.rounded()))° to go")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(duration: 0.35), value: guidanceDelta.isOnTarget)
        }
    }

    /// "Not up yet" messaging for a satellite pass targeted before it starts — ingress from a
    /// pass row that isn't soon/current opens the finder aimed at the pass's rise azimuth (its
    /// interpolated position simply clamps there — see `SkyFinderTarget.interpolatedPosition`),
    /// so this replaces the generic "N° to go" line with the specific rise time/direction instead.
    private func riseWaitingText(for kind: SkyFinderTarget.Kind) -> String? {
        guard case .satellite(let catalogNumber, let startTime) = kind.base,
              let pass = satellitePasses.first(where: { $0.satellite.catalogNumber == catalogNumber && $0.pass.startTime == startTime }),
              !SkyFinderTarget.isSatellitePassActive(pass.pass, at: now),
              now < pass.pass.startTime
        else { return nil }
        return "Not up yet — rises \(Self.timeFormatter.string(from: pass.pass.startTime)) in the \(pass.pass.startAzimuthCompass)"
    }

    /// Logging a sighting only makes sense once the object is actually confirmable: any
    /// static target (Moon/planet) once locked, or a satellite pass specifically while its
    /// window is active (never for a "not up yet" rise-direction target).
    private func canLogSighting(_ kind: SkyFinderTarget.Kind) -> Bool {
        guard case .satellite(let catalogNumber, let startTime) = kind.base else { return true }
        guard let pass = satellitePasses.first(where: { $0.satellite.catalogNumber == catalogNumber && $0.pass.startTime == startTime }) else { return true }
        return SkyFinderTarget.isSatellitePassActive(pass.pass, at: now)
    }

    private func seenButton(for kind: SkyFinderTarget.Kind) -> some View {
        Button {
            journalStore.logSighting(objectId: kind.id, name: kind.name, date: now)
            justLoggedSeen = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: justLoggedSeen ? "checkmark.circle.fill" : "checkmark.circle")
                Text(justLoggedSeen ? "Seen ✓" : "Seen")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .onChange(of: selectedKind) { _, _ in justLoggedSeen = false }
    }

    // MARK: - Ribbon

    private func ribbon(in size: CGSize) -> some View {
        let objects = ribbonObjects
        let positions = FinderGuidance.ribbonPositions(
            objects: objects.map { (name: $0.kind.name, azimuthDeg: $0.azimuthDeg, altitudeDeg: $0.altitudeDeg) },
            deviceAzimuthDeg: currentReading.azimuthDeg
        )
        return ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 56)
            ForEach(Array(zip(objects, positions)), id: \.0.kind.id) { object, position in
                Button {
                    selectedKind = object.kind
                } label: {
                    VStack(spacing: 2) {
                        Circle()
                            .fill(targetColor(for: object.kind))
                            .frame(width: 6, height: 6)
                        Text(object.kind.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .position(x: size.width * position.xFraction, y: size.height - ribbonRowOffset(position.altBand))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }

    private func ribbonRowOffset(_ band: FinderGuidance.AltitudeBand) -> CGFloat {
        switch band {
        case .belowHorizon, .low: return 18
        case .mid: return 30
        case .high: return 42
        }
    }

    /// Every currently-up object tonight, for the ribbon — "currently up" for a satellite means
    /// its pass window is actively in progress right now, not merely scheduled later tonight
    /// (unlike the picker chips, which list every pass regardless of timing).
    private var ribbonObjects: [(kind: SkyFinderTarget.Kind, azimuthDeg: Double, altitudeDeg: Double)] {
        pickerKinds.compactMap { kind in
            if case .satellite(let catalogNumber, let startTime) = kind.base {
                guard let pass = satellitePasses.first(where: { $0.satellite.catalogNumber == catalogNumber && $0.pass.startTime == startTime }),
                      SkyFinderTarget.isSatellitePassActive(pass.pass, at: now)
                else { return nil }
            }
            guard let position = SkyFinderTarget.position(for: kind, at: now, location: location, passes: satellitePasses), position.altitudeDeg > 0 else {
                return nil
            }
            return (kind, position.azimuthDeg, position.altitudeDeg)
        }
    }

    // MARK: - Haptics

    private func tickHaptics() {
        // Demo mode: keeps the canned sweep aimed at wherever the REAL selected target actually
        // is (see `DeviceMotionAdapter.setDemoAnchor`'s doc comment) — a no-op outside demo mode,
        // and cheap enough (a couple of trig calls) to ride along on this already-ticking timer
        // rather than needing a dedicated one.
        if let targetPosition {
            adapter.setDemoAnchor(azimuthDeg: targetPosition.azimuthDeg, altitudeDeg: targetPosition.altitudeDeg)
        }
        guard let guidanceDelta else { return }
        switch guidanceDelta.proximityTier {
        case .far:
            hasFiredLockHaptic = false
        case .mid:
            hasFiredLockHaptic = false
            fireHapticIfDue(style: .soft, cadence: 2.0)
        case .near:
            hasFiredLockHaptic = false
            fireHapticIfDue(style: .medium, cadence: 0.7)
        case .locked:
            guard !hasFiredLockHaptic else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            hasFiredLockHaptic = true
        }
    }

    private func fireHapticIfDue(style: UIImpactFeedbackGenerator.FeedbackStyle, cadence: TimeInterval) {
        guard now.timeIntervalSince(lastHapticFireDate) >= cadence else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        lastHapticFireDate = now
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
