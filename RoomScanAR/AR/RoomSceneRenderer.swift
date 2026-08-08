import RealityKit
import UIKit
import simd

/// Builds and maintains the 3D marking content: corner spheres, lines between
/// consecutive corners, the elastic line to the reticle, and length labels.
///
/// Every material is an `UnlitMaterial`: without LiDAR, ARKit's lighting estimate
/// swings a lot, and a lit material leaves the markers dark and unreadable on
/// video. Unlit keeps the colour constant.
@MainActor
final class RoomSceneRenderer {

    /// Corner sphere radius — 2 cm, per the specification.
    private static let cornerRadius: Float = 0.02
    /// Line thickness.
    private static let lineThickness: Float = 0.012
    /// Font height of the floating labels, in metres.
    private static let labelFontSize: CGFloat = 0.08
    /// How far labels are lifted above the floor, to stop them z-fighting the lines.
    private static let labelLift: Float = 0.06
    /// Regenerating a text mesh costs font tessellation. A label refreshed at
    /// 10 Hz is perfectly readable and costs 6× less than one refreshed every frame.
    private static let labelUpdateFrameInterval = 6

    private let root: Entity

    /// Meshes reused by every instance — identical geometry, only the transform
    /// changes.
    private let sphereMesh: MeshResource
    private let unitLineMesh: MeshResource

    private var cornerNodes: [Entity] = []
    private var edgeNodes: [Entity] = []
    private var labelNodes: [Entity] = []

    /// Duration of the wall rise animation.
    private static let wallRiseDuration: TimeInterval = 0.8

    private var wallsRoot: Entity?
    private var wallNodes: [ModelEntity] = []

    private var elasticNode: ModelEntity?
    private var elasticLabelNode: Entity?
    private var elasticLabelCentimeters: Int?
    private var elasticIsStale: Bool?
    private var framesSinceLabelUpdate = 0

    private var previewLines: [ModelEntity] = []
    private var previewWidthLabel: Entity?
    private var previewHeightLabel: Entity?
    private var previewWidthCentimeters: Int?
    private var previewHeightCentimeters: Int?

    init(root: Entity) {
        self.root = root
        sphereMesh = .generateSphere(radius: Self.cornerRadius)
        // Unit line: 1 m along the local Z axis. Scaling Z alone stretches the
        // length without thickening the line.
        unitLineMesh = .generateBox(
            width: Self.lineThickness,
            height: Self.lineThickness,
            depth: 1.0
        )
    }

    // MARK: - Confirmed corners and edges

    /// Rebuilds all confirmed geometry.
    ///
    /// Recreating everything rather than diffing is intentional: there are few
    /// corners, and this only runs on mark or undo, never per frame.
    func syncCorners(_ corners: [SIMD3<Float>], closed: Bool) {
        for node in cornerNodes + edgeNodes + labelNodes { node.removeFromParent() }
        cornerNodes.removeAll()
        edgeNodes.removeAll()
        labelNodes.removeAll()

        for corner in corners {
            let marker = ModelEntity(mesh: sphereMesh, materials: [Self.material(.systemYellow)])
            marker.position = corner
            root.addChild(marker)
            cornerNodes.append(marker)
        }

        let segmentCount = closed ? corners.count : corners.count - 1
        guard segmentCount > 0 else { return }

        for index in 0..<segmentCount {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]

            let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(.systemGreen)])
            Self.place(line, from: start, to: end)
            root.addChild(line)
            edgeNodes.append(line)

            let label = makeLabelContainer(
                text: Format.meters(simd_distance(start, end)),
                at: (start + end) / 2,
                color: .white
            )
            root.addChild(label)
            labelNodes.append(label)
        }
    }

    // MARK: - 3D walls

    /// Raises one wall per polygon segment.
    ///
    /// All walls live under a container positioned at floor level — that
    /// container is the pivot for the rise animation.
    func buildWalls(scan: RoomScan, highlighted: Int?, animated: Bool) {
        removeWalls()

        let segmentCount = scan.wallCount
        guard segmentCount > 0, scan.ceilingHeight > 0 else { return }

        let container = Entity()
        container.position = SIMD3<Float>(0, scan.floorY, 0)
        root.addChild(container)
        wallsRoot = container

        // One entity per wall rather than a single mesh: each wall is rebuilt on
        // its own when it gains a door or window, and the selection highlight
        // swaps only that wall's material.
        for index in 0..<segmentCount {
            guard let wall = scan.wall(at: index) else { continue }

            // Panel heights are relative to the container, which already sits on
            // the floor — hence the base at 0.
            let start = wall.start.with(y: 0)
            let end = wall.end.with(y: 0)

            let cutouts = scan.openings
                .filter { $0.wallIndex == index }
                .map {
                    WallMeshBuilder.Cutout(
                        distance: $0.distanceFromStart,
                        width: $0.width,
                        sill: $0.sillHeight,
                        top: $0.topHeight
                    )
                }

            let panels = WallMeshBuilder.panels(
                from: start,
                to: end,
                ceilingHeight: scan.ceilingHeight,
                cutouts: cutouts
            )
            guard let mesh = WallMeshBuilder.mesh(for: panels) else { continue }

            let material = index == highlighted ? Self.highlightMaterial() : Self.wallMaterial()
            let entity = ModelEntity(mesh: mesh, materials: [material])
            container.addChild(entity)
            wallNodes.append(entity)

            // Contrasting frame around each opening, so the cut-out reads on
            // video — translucent walls alone don't mark the opening's edge well
            // enough.
            for opening in scan.openings where opening.wallIndex == index {
                addOpeningFrame(opening, wallStart: start, wallEnd: end, to: container)
            }
        }

        if animated { animateWallRise() }
    }

    private func addOpeningFrame(
        _ opening: Opening,
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>,
        to container: Entity
    ) {
        let left = opening.distanceFromStart
        let right = opening.distanceFromStart + opening.width
        let bottom = opening.sillHeight
        let top = opening.topHeight

        let corners = [
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: left, height: bottom),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: right, height: bottom),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: right, height: top),
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: left, height: top),
        ]

        let color = Self.frameColor(for: opening.type)
        for index in 0..<4 {
            let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(color)])
            Self.placeInSpace(line, from: corners[index], to: corners[(index + 1) % 4])
            container.addChild(line)
            wallNodes.append(line)
        }
    }

    /// Animates the walls rising from floor level to full height.
    ///
    /// The mesh is built at its final height and what animates is the container's
    /// **Y scale**, with its pivot on the floor. Animating the vertices would
    /// require regenerating the mesh every frame; the visual result is the same.
    func animateWallRise() {
        guard let wallsRoot else { return }

        let target = wallsRoot.transform
        var flattened = target
        // An exact zero degenerates the transform matrix; flush with the floor
        // is enough.
        flattened.scale.y = 0.001
        wallsRoot.transform = flattened

        _ = wallsRoot.move(
            to: target,
            relativeTo: wallsRoot.parent,
            duration: Self.wallRiseDuration,
            timingFunction: .easeOut
        )
    }

    func removeWalls() {
        wallsRoot?.removeFromParent()
        wallsRoot = nil
        wallNodes.removeAll()
    }

    /// Wall material: translucent, so the real room stays visible behind it.
    ///
    /// `UnlitMaterial` rather than `PhysicallyBasedMaterial`: under PBR,
    /// `environmentTexturing` lights the wall, and a bright room **washes out**
    /// the colour set here — that was why the walls came out lighter than the
    /// tint asked for. Unlit delivers exactly the colour written, in any
    /// environment. Transparency is also **declared** here (`blending`) rather
    /// than inferred from a colour's alpha channel, whose behaviour varies
    /// between RealityKit versions.
    private static func wallMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: Self.wallTint)
        material.blending = .transparent(opacity: .init(floatLiteral: Self.wallOpacityPerFace))
        return material
    }

    /// Deep, heavily saturated blue: contrasts against white walls — the typical
    /// room — without going flat black.
    private static let wallTint = UIColor(red: 0.05, green: 0.16, blue: 0.48, alpha: 1)

    /// Opacity **per face**. The mesh is double-sided, so alpha composes twice:
    /// 0.32 per face yields roughly 0.54 perceived. This is the number to touch
    /// if the walls come out too dark or too light on video.
    private static let wallOpacityPerFace: Float = 0.32

    /// The wall selected to receive an opening.
    private static func highlightMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor.systemYellow)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.42))
        return material
    }

    /// Places the unit line between any two points in space.
    ///
    /// Unlike `place`, which only yaws around Y because it knows the corners are
    /// coplanar: opening frames have vertical edges.
    private static func placeInSpace(_ entity: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 1e-5 else { return }
        entity.position = (start + end) / 2
        entity.scale = SIMD3<Float>(1, 1, length)
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: delta / length)
    }

    // MARK: - Elastic line

    /// Line from the last marked corner to the reticle's current position, with
    /// the in-progress length labelled at its midpoint.
    ///
    /// - Parameter isStale: the endpoint is the last valid point, not this
    ///   frame's. Rendered grey to make it obvious it stopped following.
    func updateElastic(from start: SIMD3<Float>?, to end: SIMD3<Float>?, isStale: Bool) {
        guard let start, let end else {
            hideElastic()
            return
        }

        let line: ModelEntity
        if let elasticNode {
            line = elasticNode
        } else {
            let entity = ModelEntity(mesh: unitLineMesh, materials: [Self.material(.white)])
            root.addChild(entity)
            elasticNode = entity
            line = entity
        }
        line.isEnabled = true
        Self.place(line, from: start, to: end)

        // Swapping materials is costly; only do it when the state actually changes.
        if elasticIsStale != isStale {
            elasticIsStale = isStale
            line.model?.materials = [Self.material(Self.elasticColor(isStale: isStale))]
            // Force the label to be regenerated in the new colour.
            elasticLabelCentimeters = nil
            framesSinceLabelUpdate = Self.labelUpdateFrameInterval
        }

        updateElasticLabel(length: simd_distance(start, end), at: (start + end) / 2, isStale: isStale)
    }

    private static func elasticColor(isStale: Bool) -> UIColor {
        isStale ? .systemGray : .white
    }

    func hideElastic() {
        elasticNode?.isEnabled = false
        elasticLabelNode?.isEnabled = false
    }

    private func updateElasticLabel(length: Float, at position: SIMD3<Float>, isStale: Bool) {
        let container: Entity
        if let elasticLabelNode {
            container = elasticLabelNode
        } else {
            let entity = Entity()
            root.addChild(entity)
            elasticLabelNode = entity
            container = entity
        }
        container.isEnabled = true
        // The position tracks the reticle every frame; only the *text* is throttled.
        container.position = position + SIMD3<Float>(0, Self.labelLift, 0)

        framesSinceLabelUpdate += 1
        guard framesSinceLabelUpdate >= Self.labelUpdateFrameInterval else { return }
        framesSinceLabelUpdate = 0

        let centimeters = Int((length * 100).rounded())
        guard centimeters != elasticLabelCentimeters else { return }
        elasticLabelCentimeters = centimeters

        while let child = container.children.first { child.removeFromParent() }
        container.addChild(makeTextModel(Format.meters(length), color: Self.elasticColor(isStale: isStale)))
    }

    // MARK: - Preview of the opening being marked

    /// Rectangle of the opening being marked, with width and height labelled.
    ///
    /// Same role the elastic line plays for corner marking: showing the
    /// measurement **before** confirming. Without it the user only discovers the
    /// opening's size after adding it.
    func updateOpeningPreview(
        wallStart: SIMD3<Float>,
        wallEnd: SIMD3<Float>,
        fromDistance: Float,
        toDistance: Float,
        sill: Float,
        top: Float,
        color: UIColor
    ) {
        let left = min(fromDistance, toDistance)
        let right = max(fromDistance, toDistance)
        let width = right - left
        let height = max(top - sill, 0)

        func corner(_ distance: Float, _ elevation: Float) -> SIMD3<Float> {
            WallGeometry.point(onWallFrom: wallStart, to: wallEnd, distance: distance, height: elevation)
        }

        let outline = [
            corner(left, sill), corner(right, sill),
            corner(right, top), corner(left, top),
        ]

        if previewLines.isEmpty {
            for _ in 0..<4 {
                let line = ModelEntity(mesh: unitLineMesh, materials: [Self.material(color)])
                root.addChild(line)
                previewLines.append(line)
            }
        }
        for index in previewLines.indices {
            previewLines[index].isEnabled = true
            previewLines[index].model?.materials = [Self.material(color)]
            Self.placeInSpace(previewLines[index], from: outline[index], to: outline[(index + 1) % 4])
        }

        // Width below, height at the side — the two dimensions the user is
        // actually adjusting.
        placePreviewLabel(
            &previewWidthLabel,
            text: Format.meters(width),
            at: corner((left + right) / 2, sill) + SIMD3<Float>(0, -Self.labelLift, 0),
            color: color,
            cache: &previewWidthCentimeters,
            value: width
        )
        placePreviewLabel(
            &previewHeightLabel,
            text: Format.meters(height),
            at: corner(right, (sill + top) / 2),
            color: color,
            cache: &previewHeightCentimeters,
            value: height
        )
    }

    func hideOpeningPreview() {
        for line in previewLines { line.isEnabled = false }
        previewWidthLabel?.isEnabled = false
        previewHeightLabel?.isEnabled = false
    }

    private func placePreviewLabel(
        _ container: inout Entity?,
        text: String,
        at position: SIMD3<Float>,
        color: UIColor,
        cache: inout Int?,
        value: Float
    ) {
        let entity: Entity
        if let container {
            entity = container
        } else {
            let created = Entity()
            root.addChild(created)
            container = created
            entity = created
        }
        entity.isEnabled = true
        entity.position = position

        // Same saving as the elastic line: regenerating a text mesh is expensive,
        // and the value only really changes at centimetre granularity.
        let centimeters = Int((value * 100).rounded())
        guard centimeters != cache else { return }
        cache = centimeters

        while let child = entity.children.first { child.removeFromParent() }
        entity.addChild(makeTextModel(text, color: color))
    }

    // MARK: - Label orientation

    /// Turns the labels to face the camera, around Y.
    ///
    /// Billboarding on the vertical axis only (not full): the text always stays
    /// upright, which is how a plan's dimension text is read.
    func faceCamera(from cameraPosition: SIMD3<Float>) {
        for node in labelNodes {
            Self.yaw(node, toward: cameraPosition)
        }
        if let elasticLabelNode, elasticLabelNode.isEnabled {
            Self.yaw(elasticLabelNode, toward: cameraPosition)
        }
        for label in [previewWidthLabel, previewHeightLabel] {
            if let label, label.isEnabled { Self.yaw(label, toward: cameraPosition) }
        }
    }

    // MARK: - Teardown

    func clear() {
        removeWalls()
        for node in cornerNodes + edgeNodes + labelNodes { node.removeFromParent() }
        cornerNodes.removeAll()
        edgeNodes.removeAll()
        labelNodes.removeAll()
        elasticNode?.removeFromParent()
        elasticNode = nil
        elasticLabelNode?.removeFromParent()
        elasticLabelNode = nil
        elasticLabelCentimeters = nil
        elasticIsStale = nil

        for line in previewLines { line.removeFromParent() }
        previewLines.removeAll()
        previewWidthLabel?.removeFromParent()
        previewWidthLabel = nil
        previewHeightLabel?.removeFromParent()
        previewHeightLabel = nil
        previewWidthCentimeters = nil
        previewHeightCentimeters = nil
    }

    // MARK: - Factories

    private func makeLabelContainer(text: String, at position: SIMD3<Float>, color: UIColor) -> Entity {
        let container = Entity()
        container.position = position + SIMD3<Float>(0, Self.labelLift, 0)
        container.addChild(makeTextModel(text, color: color))
        return container
    }

    private func makeTextModel(_ text: String, color: UIColor) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: Self.labelFontSize, weight: .semibold),
            alignment: .center
        )
        let model = ModelEntity(mesh: mesh, materials: [Self.material(color)])
        // Generated text starts with its origin at the lower-left corner;
        // recentre it so the container can be positioned at the segment midpoint.
        model.position = -mesh.bounds.center
        return model
    }

    private static func material(_ color: UIColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    /// Frame colour per opening type. Against the dark wall, saturated colours
    /// tell the types apart at a glance on video.
    static func frameColor(for type: OpeningType) -> UIColor {
        switch type {
        case .door:        .systemOrange
        case .slidingDoor: .systemPurple
        case .openGap:     .white
        case .window:      .systemTeal
        }
    }

    // MARK: - Placement math

    /// Positions, rotates and stretches the unit line to connect two points.
    private static func place(_ entity: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let delta = end - start
        entity.position = (start + end) / 2
        entity.scale = SIMD3<Float>(1, 1, max(simd_length(delta), 0.0001))
        // Rotates the local +Z axis onto the segment's direction. Since every
        // corner shares the same Y, a rotation around Y suffices: rotating
        // (0,0,1) by θ yields (sin θ, 0, cos θ), hence θ = atan2(dx, dz).
        entity.orientation = Self.yawQuaternion(dx: delta.x, dz: delta.z)
    }

    private static func yaw(_ entity: Entity, toward target: SIMD3<Float>) {
        let delta = target - entity.position
        guard abs(delta.x) > 1e-5 || abs(delta.z) > 1e-5 else { return }
        entity.orientation = Self.yawQuaternion(dx: delta.x, dz: delta.z)
    }

    private static func yawQuaternion(dx: Float, dz: Float) -> simd_quatf {
        simd_quatf(angle: atan2(dx, dz), axis: SIMD3<Float>(0, 1, 0))
    }
}
