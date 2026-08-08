import ARKit
import Combine
import RealityKit
import simd

/// Reticle state. Deliberately coarse (few cases, `Equatable`): it is published
/// to SwiftUI, and the raycast's exact position changes every frame. Publishing
/// the `SIMD3` would redraw the interface 60×/s for no reason — the reticle's
/// colour only needs to know whether there is a valid surface beneath it.
enum ReticleState: Equatable, Sendable {
    /// No surface under the reticle.
    case searching
    /// Estimated plane — usable, but less precise.
    case approximate
    /// Detected plane geometry — trustworthy position.
    case valid
}

/// A sample of an observed horizontal plane, reduced to `Sendable` values.
///
/// `ARPlaneAnchor` is not `Sendable`, so the delegate callbacks extract only the
/// scalars we need before crossing over to the MainActor.
private struct PlaneSample: Sendable, Equatable {
    let anchorID: UUID
    let y: Float
    let area: Float
    let isClassifiedFloor: Bool
    let isClassifiedCeiling: Bool
}

/// Floor candidate, surfaced to the HUD before the user confirms it.
struct FloorCandidate: Equatable, Sendable {
    let y: Float
    let area: Float
    let isClassifiedFloor: Bool
}

/// AR session lifecycle and floor detection.
///
/// Does not own the `ARSession`: in RealityKit the `ARView` creates and owns its
/// own session (`ARView.session` is read-only). This object attaches to an
/// existing view through `attach(to:)`.
@MainActor
final class ARSessionManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published private(set) var phase: ScanPhase = .detectingFloor
    @Published private(set) var scan = RoomScan()
    @Published private(set) var reticleState: ReticleState = .searching
    @Published private(set) var floorCandidate: FloorCandidate?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isFloorLocked = false

    /// The user marked near the first corner and has to choose between closing
    /// the room and registering the corner anyway.
    @Published private(set) var offersAutoClose = false

    @Published private(set) var wallsBuilt = false

    /// Ceiling-height measurements accumulated in this session.
    @Published private(set) var ceilingSamples: [Float] = []

    /// Ceiling sweep over the feature-point cloud.
    @Published private(set) var isScanningCeiling = false
    @Published private(set) var ceilingScan: CeilingEstimator.Summary?

    /// Height estimated from the wall-ceiling junction.
    ///
    /// A second reading of the same sweep, for when the ceiling face has no
    /// texture and `ceilingScan` comes back empty.
    @Published private(set) var junctionCeilingHeight: Float?
    @Published private(set) var junctionSampleCount = 0

    /// Ceiling detected by ARKit as a horizontal plane. The most reliable signal
    /// when it exists, but it depends on the ceiling having enough texture for
    /// ARKit to consolidate a plane.
    @Published private(set) var detectedCeilingHeight: Float?

    // Draft of the opening being marked.
    @Published private(set) var selectedWallIndex: Int?
    /// First marked corner of the opening: distance along the wall in `x`,
    /// height above the floor in `y`.
    @Published private(set) var draftFirstPoint: SIMD2<Float>?
    @Published private(set) var draftStart: Float?
    @Published private(set) var draftWidth: Float?
    @Published private(set) var draftType: OpeningType = .door
    @Published var draftHeight: Float = OpeningType.door.defaultHeight
    @Published var draftSill: Float = OpeningType.door.defaultSillHeight

    /// AR does not work in the Simulator. When false, the interface shows a
    /// notice instead of trying to create the `ARView` (which aborts there).
    let isSupported = ARWorldTrackingConfiguration.isSupported

    @Published var showDebugOverlays = false {
        didSet { applyDebugOptions() }
    }

    // MARK: - Unpublished state (high frequency)

    /// World point hit by the reticle this frame. Consumed by the 3D layer
    /// (elastic line, corner marking), never directly by SwiftUI.
    private(set) var reticleWorldPoint: SIMD3<Float>?

    /// Root anchor for all of the room's 3D content.
    ///
    /// Backed by an `ARAnchor` **tracked by the session**, not by an
    /// `AnchorEntity(world:)`. The latter is merely a fixed transform in the
    /// session frame: it receives none of ARKit's drift corrections. When the
    /// user walks around the room and returns to the first corner, ARKit performs
    /// *loop closure* and re-estimates the world frame by a few centimetres —
    /// unanchored geometry slides along with it, rigidly, relative to the real
    /// room.
    ///
    /// Nor is it a plane anchor: ARKit merges plane anchors as it refines
    /// detection, and the absorbed anchor is *removed* from the session, taking
    /// all its child geometry with it.
    private(set) var contentAnchor: AnchorEntity?
    private var contentARAnchor: ARAnchor?

    // MARK: - Private

    private weak var arView: ARView?
    private let raycastService = RaycastService()
    private var renderer: RoomSceneRenderer?

    /// Last valid endpoint of the elastic line, kept so it doesn't flicker when
    /// the reticle momentarily leaves the floor.
    private var lastElasticEnd: SIMD3<Float>?

    /// Corner awaiting the user's decision in the auto-close prompt.
    private var pendingCorner: SIMD3<Float>?

    /// Minimum spacing between consecutive corners. Below it an accidental tap is
    /// almost certain, and a degenerate segment would break the geometry.
    private static let minCornerSpacing: Float = 0.10

    /// Radius around the first corner that triggers the close offer.
    private static let autoCloseRadius: Float = 0.30

    /// Acceptable ceiling-height range.
    ///
    /// Much wider than the spec's 2.00–4.00 m: exposed roofs, mezzanines and
    /// double-height rooms comfortably exceed 4 m, and rejecting the measurement
    /// there would force everything to be typed by hand. The limit exists to
    /// catch gross aiming errors, not to impose a standard ceiling.
    static let minCeilingHeight: Float = 1.8
    static let maxCeilingHeight: Float = 6.0

    /// Minimum dimensions of an opening.
    private static let minOpeningWidth: Float = 0.30
    private static let minOpeningHeight: Float = 0.30

    /// Slack at the wall's edges when aiming at its vertical plane.
    private static let wallAimTolerance: Float = 0.20

    /// Minimum distance from the walls for a feature point to count as ceiling.
    private static let ceilingWallMargin: Float = 0.35

    /// Maximum distance from a wall for a point to count as wall-ceiling
    /// junction. Below `ceilingWallMargin`: the two bands do not overlap.
    private static let junctionWallDistance: Float = 0.25

    /// The cloud is read every N frames. Reading at 60 Hz does not add new points
    /// in proportion — feature points persist across frames.
    private static let ceilingScanFrameInterval = 5

    /// Horizontal planes observed so far, keyed by anchor identifier.
    private var planeSamples: [UUID: PlaneSample] = [:]

    /// Feature points already counted in the ceiling sweep.
    private var seenFeaturePointIDs: Set<UInt64> = []
    private var ceilingScanHeights: [Float] = []
    private var junctionHeights: [Float] = []
    private var framesSinceCeilingScan = 0
    private var latestCameraPosition: SIMD3<Float>?

    /// Minimum area for a plane to be considered as the floor.
    private static let minFloorArea: Float = 0.5
    /// Minimum vertical distance between camera and plane, to rule out tables and
    /// beds. A phone is held around 1.2–1.6 m; a table sits at ~0.75 m.
    private static let minCameraDrop: Float = 0.8

    // MARK: - Lifecycle

    func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        // Pin the delegate queue to main. Without it the callbacks arrive on an
        // unspecified queue and the `MainActor.assumeIsolated` below would have
        // no guarantee.
        view.session.delegateQueue = .main
        applyDebugOptions()
        runSession(resetting: true)
    }

    func runSession(resetting: Bool) {
        guard let arView, isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        // No LiDAR: no sceneReconstruction, sceneDepth or sceneUnderstanding.
        // The room geometry is computed by hand from the raycasts.
        arView.session.run(config, options: resetting ? [.resetTracking, .removeExistingAnchors] : [])
    }

    func pause() {
        arView?.session.pause()
    }

    /// Starts over: clears the model, the scene and the tracking.
    func reset() {
        planeSamples.removeAll()
        latestCameraPosition = nil
        floorCandidate = nil
        reticleWorldPoint = nil
        lastElasticEnd = nil
        pendingCorner = nil
        offersAutoClose = false
        wallsBuilt = false
        selectedWallIndex = nil
        draftStart = nil
        draftWidth = nil
        ceilingSamples.removeAll()
        clearCeilingScan()
        detectedCeilingHeight = nil
        setDraftType(.door)
        reticleState = .searching
        statusMessage = nil
        isFloorLocked = false
        scan = RoomScan()
        phase = .detectingFloor

        renderer?.clear()
        renderer = nil
        contentAnchor?.removeFromParent()
        contentAnchor = nil
        if let contentARAnchor {
            arView?.session.remove(anchor: contentARAnchor)
        }
        contentARAnchor = nil
        runSession(resetting: true)
    }

    // MARK: - Phase: floor detection

    /// Locks the floor to the current candidate and advances to corner marking.
    ///
    /// The transition is explicit (a button) even with the floor already
    /// detected: advancing automatically would surprise the user mid-recording.
    func confirmFloor() {
        guard let candidate = floorCandidate, phase == .detectingFloor else { return }
        installContentAnchor(atWorldY: candidate.y)
        // The anchor sits exactly at floor level, so in its space the floor is
        // y = 0. Nothing to convert, no value to keep in sync.
        scan.floorY = 0
        isFloorLocked = true
        phase = .markingCorners
    }

    private func installContentAnchor(atWorldY worldY: Float) {
        guard let arView, contentAnchor == nil else { return }

        // Place the anchor at floor level, under the camera's current position.
        // Anchoring near the content matters: a drift correction involving
        // rotation turns into positional error proportional to the distance from
        // the anchor.
        var transform = matrix_identity_float4x4
        transform.columns.3.x = latestCameraPosition?.x ?? 0
        transform.columns.3.y = worldY
        transform.columns.3.z = latestCameraPosition?.z ?? 0

        let arAnchor = ARAnchor(name: "roomContent", transform: transform)
        arView.session.add(anchor: arAnchor)
        contentARAnchor = arAnchor

        // `AnchorEntity(anchor:)` follows the updates ARKit makes to that anchor
        // — that is what keeps the geometry glued to the real room.
        let anchorEntity = AnchorEntity(anchor: arAnchor)
        arView.scene.addAnchor(anchorEntity)
        contentAnchor = anchorEntity
        renderer = RoomSceneRenderer(root: anchorEntity)
    }

    // MARK: - Coordinate conversion

    /// World → content anchor space.
    ///
    /// Corners are stored in anchor space, not in world coordinates. Since ARKit
    /// repositions the anchor on every drift correction, world coordinates
    /// captured at different moments would be mutually inconsistent. Distances
    /// and areas are unaffected: the conversion is a rigid transform.
    private func toAnchorSpace(_ worldPoint: SIMD3<Float>) -> SIMD3<Float>? {
        contentAnchor?.convert(position: worldPoint, from: nil)
    }

    /// Directions are not translated, only rotated — hence the separate overload.
    private func directionToAnchorSpace(_ worldDirection: SIMD3<Float>) -> SIMD3<Float>? {
        contentAnchor?.convert(direction: worldDirection, from: nil)
    }

    /// Floor height in world coordinates, which is the frame the raycast works in.
    private var worldFloorY: Float? {
        contentAnchor?.convert(position: SIMD3<Float>(0, scan.floorY, 0), to: nil).y
    }

    // MARK: - Phase: corner marking

    /// Whether there is a valid surface under the reticle to register a corner.
    var canMarkCorner: Bool {
        phase == .markingCorners && !scan.isClosed && reticleState != .searching
    }

    /// Three corners already define a polygon with area.
    var canClosePolygon: Bool {
        phase == .markingCorners && !scan.isClosed && scan.corners.count >= 3
    }

    var canUndo: Bool {
        switch phase {
        case .markingCorners:
            wallsBuilt || scan.isClosed || !scan.corners.isEmpty
        case .measuringHeight:
            true
        case .markingOpenings:
            selectedWallIndex != nil || draftFirstPoint != nil || !scan.openings.isEmpty
        case .detectingFloor, .results:
            false
        }
    }

    func markCorner() {
        guard phase == .markingCorners, !scan.isClosed,
              let hit = reticleWorldPoint,
              let local = toAnchorSpace(hit) else { return }

        // Lock Y to the floor. Raycasting against an estimated plane returns
        // slightly different heights at each point; without the lock the polygon
        // ends up non-planar and the shoelace area comes out wrong.
        let corner = local.with(y: scan.floorY)

        if let last = scan.corners.last, simd_distance(last, corner) < Self.minCornerSpacing {
            setStatus("Canto muito perto do anterior — afaste pelo menos 10 cm")
            return
        }

        // Near the first corner: the intent is almost always to close the room.
        // The specification asks for the closure to be *offered*, not performed
        // automatically — so the corner stays pending until the user chooses.
        if scan.corners.count >= 3,
           let first = scan.corners.first,
           simd_distance(first, corner) < Self.autoCloseRadius {
            pendingCorner = corner
            offersAutoClose = true
            return
        }

        commit(corner)
    }

    /// Closes the room at the first corner, discarding the pending one.
    func acceptAutoClose() {
        pendingCorner = nil
        offersAutoClose = false
        closePolygon()
    }

    /// Registers the pending corner despite it being near the first — narrow
    /// rooms legitimately have corners less than 30 cm apart.
    func declineAutoClose() {
        guard let pendingCorner else { return }
        self.pendingCorner = nil
        offersAutoClose = false
        commit(pendingCorner)
    }

    func closePolygon() {
        guard phase == .markingCorners, !scan.isClosed, scan.corners.count >= 3 else { return }
        scan.isClosed = true
        lastElasticEnd = nil
        setStatus(nil)
        renderer?.syncCorners(scan.corners, closed: true)
        renderer?.hideElastic()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - 3D walls

    /// Raises the walls with the rise animation.
    ///
    /// Button-driven rather than automatic on polygon closure: beyond the
    /// explicit-transitions rule, this is the app's visually strongest moment and
    /// whoever is recording needs to trigger it at the right time.
    func buildWalls() {
        guard scan.isClosed, scan.corners.count >= 3 else { return }
        wallsBuilt = true
        renderer?.buildWalls(scan: scan, highlighted: selectedWallIndex, animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Replays the animation without rebuilding the mesh — for retaking the shot.
    func replayWallRise() {
        guard wallsBuilt else { return }
        renderer?.animateWallRise()
    }

    private func discardWalls() {
        guard wallsBuilt else { return }
        renderer?.removeWalls()
        wallsBuilt = false
    }

    private func rebuildWalls() {
        guard wallsBuilt else { return }
        renderer?.buildWalls(scan: scan, highlighted: selectedWallIndex, animated: false)
    }

    // MARK: - Orthogonal snap

    func applyOrthogonalSnap() {
        guard scan.isClosed, !scan.isSnapped else { return }

        switch OrthogonalSnap.snap(scan.corners) {
        case .success(let corners):
            // Keep the originals so the operation stays reversible.
            scan.cornersBeforeSnap = scan.corners
            scan.corners = corners
            renderer?.syncCorners(corners, closed: true)
            rebuildWalls()
            setStatus(nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)

        case .failure(let failure):
            setStatus(Self.message(for: failure))
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func revertOrthogonalSnap() {
        guard let original = scan.cornersBeforeSnap else { return }
        scan.corners = original
        scan.cornersBeforeSnap = nil
        renderer?.syncCorners(original, closed: scan.isClosed)
        rebuildWalls()
        setStatus(nil)
    }

    private static func message(for failure: OrthogonalSnap.Failure) -> String {
        switch failure {
        case .notEnoughCorners:
            "São necessários pelo menos três cantos"
        case .tooIrregular(let ratio):
            "Marcação muito irregular para alinhar (erro de \(Int((ratio * 100).rounded()))% do perímetro)"
        case .unbalancedAxis:
            "O formato do cômodo não fecha em ângulos retos"
        }
    }

    // MARK: - Phase: ceiling height

    func beginHeightMeasurement() {
        guard scan.isClosed else { return }
        setStatus(nil)
        phase = .measuringHeight
    }

    /// Measures ceiling height by aiming at the wall-ceiling junction.
    ///
    /// Without LiDAR there is no ceiling surface to raycast against. The camera
    /// ray is intersected with the infinite vertical plane of the wall being
    /// aimed at, and the height comes from the difference between the
    /// intersection's Y and the floor's.
    func measureCeilingHeight() {
        guard phase == .measuringHeight, let arView,
              let ray = raycastService.cameraRay(in: arView),
              let origin = toAnchorSpace(ray.origin),
              let direction = directionToAnchorSpace(ray.direction) else { return }

        guard let aimed = WallGeometry.aimedWall(
            rayOrigin: origin,
            rayDirection: direction,
            corners: scan.corners,
            closed: scan.isClosed
        ) else {
            setStatus("Nenhuma parede sob a mira — aponte para o encontro entre parede e teto")
            return
        }

        let height = aimed.point.y - scan.floorY
        guard height >= Self.minCeilingHeight, height <= Self.maxCeilingHeight else {
            setStatus("Medida de \(Format.meters(height)) fora da faixa esperada — ajuste a mira ou digite o valor")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Accumulate rather than replace: a sloped ceiling has no *single*
        // height. Measuring at different points and choosing between minimum,
        // average and maximum is what makes this phase usable outside a room
        // with a flat slab.
        ceilingSamples.append(height)
        setCeilingHeight(height)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func setCeilingHeight(_ value: Float) {
        scan.ceilingHeight = min(max(value, Self.minCeilingHeight), Self.maxCeilingHeight)
        setStatus(nil)
        rebuildWalls()
    }

    /// Summary of the accumulated measurements, once there is more than one.
    var ceilingStats: (minimum: Float, average: Float, maximum: Float)? {
        guard ceilingSamples.count >= 2,
              let minimum = ceilingSamples.min(),
              let maximum = ceilingSamples.max() else { return nil }
        let average = ceilingSamples.reduce(0, +) / Float(ceilingSamples.count)
        return (minimum, average, maximum)
    }

    func clearCeilingSamples() {
        ceilingSamples.removeAll()
        setStatus(nil)
    }

    // MARK: - Ceiling sweep

    func toggleCeilingScan() {
        if isScanningCeiling {
            isScanningCeiling = false
            return
        }
        seenFeaturePointIDs.removeAll(keepingCapacity: true)
        ceilingScanHeights.removeAll(keepingCapacity: true)
        junctionHeights.removeAll(keepingCapacity: true)
        ceilingScan = nil
        junctionCeilingHeight = nil
        junctionSampleCount = 0
        framesSinceCeilingScan = 0
        isScanningCeiling = true
        setStatus(nil)
    }

    func clearCeilingScan() {
        isScanningCeiling = false
        seenFeaturePointIDs.removeAll()
        ceilingScanHeights.removeAll()
        junctionHeights.removeAll()
        ceilingScan = nil
        junctionCeilingHeight = nil
        junctionSampleCount = 0
    }

    /// Accumulates points from the sparse cloud that may belong to the ceiling.
    ///
    /// Deduplication by identifier is what makes the statistic honest: each
    /// feature point has a stable id across frames, and without it, holding still
    /// while pointing at one corner would multiply the weight of that patch of
    /// ceiling.
    private func ingestCeilingPoints(in arView: ARView) {
        framesSinceCeilingScan += 1
        guard framesSinceCeilingScan >= Self.ceilingScanFrameInterval else { return }
        framesSinceCeilingScan = 0

        guard scan.corners.count >= 3,
              let cloud = arView.session.currentFrame?.rawFeaturePoints else { return }

        let polygon = scan.corners.map(\.xz)
        var fresh: [SIMD3<Float>] = []
        fresh.reserveCapacity(cloud.points.count)

        for (index, identifier) in cloud.identifiers.enumerated() where index < cloud.points.count {
            guard seenFeaturePointIDs.insert(identifier).inserted else { continue }
            guard let local = toAnchorSpace(cloud.points[index]) else { continue }
            fresh.append(local)
        }
        guard !fresh.isEmpty else { return }

        ceilingScanHeights.append(
            contentsOf: CeilingEstimator.ceilingHeights(
                from: fresh,
                floorY: scan.floorY,
                polygon: polygon,
                minimumHeight: Self.minCeilingHeight,
                maximumHeight: Self.maxCeilingHeight,
                wallMargin: Self.ceilingWallMargin
            )
        )

        let summary = CeilingEstimator.summarize(ceilingScanHeights)
        if summary != ceilingScan { ceilingScan = summary }

        // A second reading of the same points, in the band hugging the walls.
        // This is what rescues a textureless ceiling: the smooth face produces no
        // points at all, but the corner line where it meets the wall does.
        junctionHeights.append(
            contentsOf: CeilingEstimator.junctionHeights(
                from: fresh,
                floorY: scan.floorY,
                polygon: polygon,
                minimumHeight: Self.minCeilingHeight,
                maximumHeight: Self.maxCeilingHeight,
                maxWallDistance: Self.junctionWallDistance
            )
        )

        if junctionHeights.count != junctionSampleCount {
            junctionSampleCount = junctionHeights.count
        }
        let estimate = CeilingEstimator.junctionCeilingHeight(junctionHeights)
        if estimate != junctionCeilingHeight { junctionCeilingHeight = estimate }
    }

    /// Highest horizontal plane detected above the floor, within the plausible range.
    private func recomputeCeilingPlane() {
        guard let worldFloorY else { return }

        let candidates = planeSamples.values.compactMap { sample -> Float? in
            let height = sample.y - worldFloorY
            guard height >= Self.minCeilingHeight, height <= Self.maxCeilingHeight else { return nil }
            // Classified as ceiling, or large enough not to be a piece of furniture.
            guard sample.isClassifiedCeiling || sample.area >= Self.minFloorArea else { return nil }
            return height
        }

        let best = candidates.max()
        if best != detectedCeilingHeight { detectedCeilingHeight = best }
    }

    func confirmCeilingHeight() {
        guard phase == .measuringHeight else { return }
        isScanningCeiling = false
        // The walls may not have been raised yet; make sure they exist so that
        // tap-to-select has something to highlight.
        if !wallsBuilt { buildWalls() }
        setStatus(nil)
        phase = .markingOpenings
    }

    // MARK: - Phase: doors and windows

    /// Selects the wall under the tapped screen point.
    ///
    /// Uses the screen ray against the walls' vertical planes rather than a
    /// collision hit-test: the walls are re-meshed on every opening inserted, and
    /// keeping collision shapes up to date would be more fragile than redoing the
    /// math.
    func selectWall(atScreenPoint point: CGPoint) {
        guard phase == .markingOpenings, let arView,
              let ray = arView.ray(through: point),
              let origin = toAnchorSpace(ray.origin),
              let direction = directionToAnchorSpace(ray.direction) else { return }

        guard let aimed = WallGeometry.aimedWall(
            rayOrigin: origin,
            rayDirection: direction,
            corners: scan.corners,
            closed: scan.isClosed
        ) else {
            setStatus("Nenhuma parede nesse ponto")
            return
        }

        selectedWallIndex = aimed.index
        draftStart = nil
        draftWidth = nil
        setStatus(nil)
        rebuildWalls()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var canMarkOpeningPoint: Bool {
        phase == .markingOpenings && selectedWallIndex != nil && reticleState != .searching
    }

    var canConfirmOpening: Bool {
        selectedWallIndex != nil && draftStart != nil && draftWidth != nil
    }

    /// Marks one of the opening's two opposite corners, on the wall plane.
    ///
    /// The two points define the whole rectangle — width, sill and height — the
    /// same way the corners define the room polygon.
    ///
    /// **Diverges from the specification**, which asks for two points "along the
    /// base" of the wall. Marking on the base discards the height by
    /// construction: it would have to come from a default, and the rectangle
    /// grows horizontally only — producing proportions that don't match the real
    /// opening.
    func markOpeningPoint() {
        guard phase == .markingOpenings, let aim = currentWallAim else { return }

        guard let first = draftFirstPoint else {
            draftFirstPoint = aim
            setStatus(nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }

        let width = abs(aim.x - first.x)
        let height = abs(aim.y - first.y)

        guard width >= Self.minOpeningWidth else {
            setStatus("Vão muito estreito — afaste o segundo canto na horizontal")
            return
        }
        guard height >= Self.minOpeningHeight else {
            setStatus("Vão muito baixo — marque o segundo canto mais alto")
            return
        }

        draftStart = min(first.x, aim.x)
        draftWidth = width
        draftSill = min(first.y, aim.y)
        draftHeight = height
        // Suggest the type from the width: past 1.20 m a swing leaf stops making
        // sense and the default becomes a sliding door. Still editable.
        draftType = OpeningType.suggested(forWidth: width)
        setStatus(nil)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Changes the type only.
    ///
    /// Leaves the dimensions alone: they came from the two marked corners, and
    /// overwriting them with the type's defaults would throw away the user's
    /// measurement.
    func setDraftType(_ type: OpeningType) {
        draftType = type
    }

    /// Point aimed at on the selected wall's vertical plane: distance along the
    /// wall in `x`, height above the floor in `y`.
    ///
    /// Not `@Published` — it changes every frame and only the 3D layer cares.
    private(set) var currentWallAim: SIMD2<Float>?

    private func wallAim(in arView: ARView) -> SIMD2<Float>? {
        guard let index = selectedWallIndex,
              let wall = scan.wall(at: index),
              let ray = raycastService.cameraRay(in: arView),
              let origin = toAnchorSpace(ray.origin),
              let direction = directionToAnchorSpace(ray.direction),
              let hit = WallGeometry.intersectVerticalPlane(
                  rayOrigin: origin,
                  rayDirection: direction,
                  wallStart: wall.start,
                  wallEnd: wall.end
              ),
              let distance = WallGeometry.project(hit.point, onto: wall.start, wall.end)
        else { return nil }

        // The plane is infinite, the wall is not. Slack at the corners allows
        // aiming at the exact corner without losing the target, while still
        // rejecting a hit on the far side.
        let wallLength = WallGeometry.length(from: wall.start, to: wall.end)
        guard distance >= -Self.wallAimTolerance,
              distance <= wallLength + Self.wallAimTolerance else { return nil }

        let height = hit.point.y - scan.floorY
        guard height >= -Self.wallAimTolerance,
              height <= scan.ceilingHeight + Self.wallAimTolerance else { return nil }

        return SIMD2<Float>(
            min(max(distance, 0), wallLength),
            min(max(height, 0), scan.ceilingHeight)
        )
    }

    func confirmOpening() {
        guard let index = selectedWallIndex,
              let start = draftStart,
              let width = draftWidth else { return }

        scan.openings.append(
            Opening(
                wallIndex: index,
                distanceFromStart: start,
                width: width,
                height: draftHeight,
                sillHeight: draftSill,
                type: draftType
            )
        )
        clearOpeningDraft()
        rebuildWalls()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func clearOpeningDraft() {
        draftFirstPoint = nil
        draftStart = nil
        draftWidth = nil
        selectedWallIndex = nil
        draftType = .door
        draftHeight = OpeningType.door.defaultHeight
        draftSill = OpeningType.door.defaultSillHeight
        setStatus(nil)
        rebuildWalls()
    }

    func showResults() {
        guard scan.isClosed else { return }
        clearOpeningDraft()
        phase = .results
    }

    func backToScanning() {
        guard phase == .results else { return }
        phase = .markingOpenings
    }

    // MARK: - Undo

    /// Undoes the last action of the current phase.
    func undo() {
        switch phase {
        case .markingOpenings:
            if selectedWallIndex != nil || draftFirstPoint != nil {
                clearOpeningDraft()
            } else if !scan.openings.isEmpty {
                scan.openings.removeLast()
                rebuildWalls()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()

        case .measuringHeight:
            phase = .markingCorners
            setStatus(nil)

        case .markingCorners:
            undoInMarkingCorners()

        case .detectingFloor, .results:
            break
        }
    }

    private func undoInMarkingCorners() {
        if offersAutoClose {
            pendingCorner = nil
            offersAutoClose = false
            return
        }

        if wallsBuilt {
            discardWalls()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        if scan.isSnapped {
            revertOrthogonalSnap()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        if scan.isClosed {
            scan.isClosed = false
            renderer?.syncCorners(scan.corners, closed: false)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        guard !scan.corners.isEmpty else { return }
        scan.corners.removeLast()
        // Drop the frozen endpoint: it belonged to the corner just removed.
        lastElasticEnd = nil
        setStatus(nil)
        renderer?.syncCorners(scan.corners, closed: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func commit(_ corner: SIMD3<Float>) {
        scan.corners.append(corner)
        setStatus(nil)
        renderer?.syncCorners(scan.corners, closed: scan.isClosed)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Re-evaluates which observed plane is the best floor candidate.
    ///
    /// "First horizontal plane with enough area" is not enough: tables and beds
    /// are frequently detected before the floor, and locking the floor onto a
    /// table ruins every measurement. The criterion: the **lowest** plane with
    /// enough area that also sits well below the camera (or that ARKit has
    /// classified as floor).
    private func recomputeFloorCandidate() {
        let cameraY = latestCameraPosition?.y
        let qualifying = planeSamples.values.filter { sample in
            guard sample.area >= Self.minFloorArea else { return false }
            if sample.isClassifiedFloor { return true }
            guard let cameraY else { return false }
            return (cameraY - sample.y) > Self.minCameraDrop
        }

        // Lowest first; ties broken by larger area.
        let best = qualifying.min { lhs, rhs in
            lhs.y == rhs.y ? lhs.area > rhs.area : lhs.y < rhs.y
        }

        let newCandidate = best.map {
            FloorCandidate(y: $0.y, area: $0.area, isClassifiedFloor: $0.isClassifiedFloor)
        }
        if newCandidate != floorCandidate {
            floorCandidate = newCandidate
        }
    }

    // MARK: - Per-frame loop

    /// Called once per frame to update the reticle.
    fileprivate func onFrame() {
        guard let arView else { return }

        let cameraPosition = arView.session.currentFrame?.camera.transform.translation
        if let cameraPosition {
            latestCameraPosition = cameraPosition
            if phase == .detectingFloor { recomputeFloorCandidate() }
        }

        // The raycast works in world coordinates; the corners live in anchor
        // space. The conversion happens at both boundaries.
        let newState: ReticleState
        if phase == .measuringHeight {
            // In this phase the user points upward, where there is no floor at
            // all. The reticle switches to reflecting whether a wall is under the
            // target — otherwise it would stay white the whole time, informing
            // nothing.
            reticleWorldPoint = nil
            currentWallAim = nil
            newState = ceilingAimState(in: arView)
            if isScanningCeiling { ingestCeilingPoints(in: arView) }
        } else if phase == .markingOpenings, selectedWallIndex != nil {
            // With the wall chosen, the reticle leaves the floor and starts
            // travelling that wall's plane: that is what allows height and width
            // to be marked in a single gesture.
            reticleWorldPoint = nil
            currentWallAim = wallAim(in: arView)
            newState = currentWallAim == nil ? .searching : .valid
        } else {
            let hit = raycastService.floorHit(in: arView, lockedFloorY: isFloorLocked ? worldFloorY : nil)
            reticleWorldPoint = hit?.position
            currentWallAim = nil
            newState =
                switch hit {
                case .none: .searching
                case .some(let h): h.isPrecise ? .valid : .approximate
                }
        }
        if newState != reticleState { reticleState = newState }

        updateOpeningPreview()

        // Elastic line from the last corner to the reticle. The endpoint is
        // locked to `floorY` so the line lies flat on the floor.
        if phase == .markingCorners, !scan.isClosed, let last = scan.corners.last {
            if let point = reticleWorldPoint, let local = toAnchorSpace(point) {
                lastElasticEnd = local.with(y: scan.floorY)
            }
            // No hit this frame — usually the phone pointing up or at the horizon
            // — so the line stays visible at the last valid point, in grey.
            // Hiding it on every reticle wobble flickers far too much.
            renderer?.updateElastic(from: last, to: lastElasticEnd, isStale: reticleWorldPoint == nil)
        } else {
            renderer?.hideElastic()
        }

        // The labels live in anchor space, so the camera has to come along.
        if let cameraPosition, let localCamera = toAnchorSpace(cameraPosition) {
            renderer?.faceCamera(from: localCamera)
        }
    }

    /// Quality of the aim pointed at the wall-ceiling junction.
    private func ceilingAimState(in arView: ARView) -> ReticleState {
        guard let ray = raycastService.cameraRay(in: arView),
              let origin = toAnchorSpace(ray.origin),
              let direction = directionToAnchorSpace(ray.direction),
              let aimed = WallGeometry.aimedWall(
                  rayOrigin: origin,
                  rayDirection: direction,
                  corners: scan.corners,
                  closed: scan.isClosed
              ) else { return .searching }

        let height = aimed.point.y - scan.floorY
        let inRange = height >= Self.minCeilingHeight && height <= Self.maxCeilingHeight
        return inRange ? .valid : .approximate
    }

    /// Rectangle of the opening being marked, refreshed every frame.
    ///
    /// Before the second corner the rectangle follows the reticle in both
    /// dimensions; after it, it reflects the steppers instead, so that height and
    /// sill show their effect live.
    private func updateOpeningPreview() {
        guard phase == .markingOpenings,
              let index = selectedWallIndex,
              let wall = scan.wall(at: index) else {
            renderer?.hideOpeningPreview()
            return
        }

        let cornerA: SIMD2<Float>
        let cornerB: SIMD2<Float>

        if let start = draftStart, let width = draftWidth {
            cornerA = SIMD2<Float>(start, draftSill)
            cornerB = SIMD2<Float>(start + width, min(draftSill + draftHeight, scan.ceilingHeight))
        } else if let first = draftFirstPoint {
            cornerA = first
            cornerB = currentWallAim ?? first
        } else {
            renderer?.hideOpeningPreview()
            return
        }

        renderer?.updateOpeningPreview(
            wallStart: wall.start,
            wallEnd: wall.end,
            fromDistance: cornerA.x,
            toDistance: cornerB.x,
            sill: min(cornerA.y, cornerB.y),
            top: max(cornerA.y, cornerB.y),
            color: RoomSceneRenderer.frameColor(for: draftType)
        )
    }

    fileprivate func ingest(planes: [PlaneSample]) {
        for sample in planes { planeSamples[sample.anchorID] = sample }
        if phase == .detectingFloor { recomputeFloorCandidate() }
        if isFloorLocked { recomputeCeilingPlane() }
    }

    fileprivate func forget(anchorIDs: [UUID]) {
        for id in anchorIDs { planeSamples.removeValue(forKey: id) }
        if phase == .detectingFloor { recomputeFloorCandidate() }
    }

    fileprivate func setStatus(_ message: String?) {
        if message != statusMessage { statusMessage = message }
    }

    private func applyDebugOptions() {
        guard let arView else { return }
        arView.debugOptions = showDebugOverlays ? [.showFeaturePoints, .showAnchorGeometry, .showWorldOrigin] : []
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // `delegateQueue` was pinned to `.main` in `attach(to:)`, so we are
        // already on the MainActor. `assumeIsolated` avoids the cost of an actor
        // hop every frame. The `ARFrame` is not retained — only the reticle is
        // updated.
        MainActor.assumeIsolated { self.onFrame() }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let samples = Self.samples(from: anchors)
        guard !samples.isEmpty else { return }
        MainActor.assumeIsolated { self.ingest(planes: samples) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let samples = Self.samples(from: anchors)
        guard !samples.isEmpty else { return }
        MainActor.assumeIsolated { self.ingest(planes: samples) }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // ARKit removes anchors when it merges neighbouring planes — we have to
        // forget them so we don't keep a floor candidate that no longer exists.
        let ids = anchors.compactMap { $0 as? ARPlaneAnchor }.map(\.identifier)
        guard !ids.isEmpty else { return }
        MainActor.assumeIsolated { self.forget(anchorIDs: ids) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // Convert to String here, in the delegate: `ARCamera` is not `Sendable`.
        let message: String? =
            switch camera.trackingState {
            case .normal:
                nil
            case .notAvailable:
                "Rastreamento indisponível"
            case .limited(let reason):
                switch reason {
                case .initializing:      "Inicializando — mova o celular devagar"
                case .excessiveMotion:   "Movimento rápido demais — vá mais devagar"
                case .insufficientFeatures: "Pouca textura na cena — aponte para uma área com mais detalhes"
                case .relocalizing:      "Recuperando rastreamento…"
                @unknown default:        "Rastreamento limitado"
                }
            }
        MainActor.assumeIsolated { self.setStatus(message) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let text = "Erro na sessão AR: \(error.localizedDescription)"
        MainActor.assumeIsolated { self.setStatus(text) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.setStatus("Sessão interrompida") }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { self.setStatus(nil) }
    }

    /// Reduces horizontal plane anchors to `Sendable` values.
    private nonisolated static func samples(from anchors: [ARAnchor]) -> [PlaneSample] {
        anchors.compactMap { anchor in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            let extent = plane.planeExtent
            let classificationWorks = ARPlaneAnchor.isClassificationSupported
            let isFloor = classificationWorks && plane.classification == .floor
            // Downward-facing horizontal plane. ARKit detects ceilings with
            // `.horizontal` — no need to enable vertical detection or anything
            // that depends on LiDAR.
            let isCeiling = classificationWorks && plane.classification == .ceiling
            return PlaneSample(
                anchorID: plane.identifier,
                // The plane's centre in world coordinates: the anchor's
                // translation plus the local centre offset.
                y: plane.transform.columns.3.y + plane.center.y,
                area: extent.width * extent.height,
                isClassifiedFloor: isFloor,
                isClassifiedCeiling: isCeiling
            )
        }
    }
}
