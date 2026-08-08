import ARKit
import RealityKit
import simd

/// Point marking by raycasting from the centre of the screen.
///
/// Without LiDAR there is no environment mesh. The only surface ARKit knows how
/// to cast rays against is the horizontal plane it detects through
/// visual-inertial odometry — and that plane covers only the region the user has
/// already swept.
///
/// Once the floor is locked, though, that dependency disappears: the
/// intersection of the camera ray with the infinite plane `y = floorY` is
/// computed analytically, and holds for any downward-pointing direction.
///
/// `@MainActor` because `ARView` is MainActor-isolated in the SDK — not our
/// choice. It is also where the per-frame loop runs, so there is no hop cost.
@MainActor
struct RaycastService {

    // `nonisolated` because `Hit.isPrecise` — a nested struct, outside the
    // MainActor — needs to read them.

    /// Maximum accepted distance for a floor intersection.
    /// Beyond it, angular error turns into too much positional error.
    nonisolated static let maxFloorDistance: Float = 15.0

    /// Past this distance marking is still possible, but the reticle warns that
    /// precision has dropped: 1° of camera pose error becomes ~10 cm at 6 m.
    nonisolated static let preciseFloorDistance: Float = 6.0

    /// Vertical tolerance for accepting a plane hit as the floor.
    /// Serves to discard tables and beds sitting in the ray's path.
    nonisolated private static let floorLevelTolerance: Float = 0.15

    struct Hit: Equatable {
        enum Source: Equatable {
            /// Actually detected plane geometry — the most reliable source.
            case planeGeometry
            /// Plane estimated from feature points.
            case estimatedPlane
            /// Analytic intersection with the already-locked floor plane.
            case lockedFloorPlane
        }

        let position: SIMD3<Float>
        let source: Source
        /// Distance from the camera to the point, in metres.
        let distance: Float

        var isPrecise: Bool {
            switch source {
            case .planeGeometry:    true
            case .estimatedPlane:   false
            case .lockedFloorPlane: distance <= RaycastService.preciseFloorDistance
            }
        }
    }

    /// The floor point under the reticle.
    ///
    /// - Parameter lockedFloorY: floor height, if already confirmed. When
    ///   present, it enables the analytic intersection and the rejection of
    ///   planes that aren't at floor level.
    func floorHit(in view: ARView, lockedFloorY: Float?) -> Hit? {
        guard let cameraPosition = cameraRay(in: view)?.origin else { return nil }

        // 1. Detected plane geometry: the most reliable source when it exists.
        if let point = planeGeometryHit(in: view) {
            if let lockedFloorY {
                // A table plane in the ray's path would be marked as a corner.
                // Only accept the hit if it sits at floor level.
                if abs(point.y - lockedFloorY) <= Self.floorLevelTolerance {
                    return Hit(
                        position: point,
                        source: .planeGeometry,
                        distance: simd_distance(cameraPosition, point)
                    )
                }
            } else {
                return Hit(
                    position: point,
                    source: .planeGeometry,
                    distance: simd_distance(cameraPosition, point)
                )
            }
        }

        // 2. Floor locked: analytic intersection, regardless of whether the
        //    detected plane reaches the region under the reticle.
        if let lockedFloorY, let hit = lockedFloorIntersection(in: view, floorY: lockedFloorY) {
            return hit
        }

        // 3. Before the floor is locked there is no reference plane yet; the
        //    feature-point estimated plane is what's left.
        if lockedFloorY == nil, let point = estimatedPlaneHit(in: view) {
            return Hit(
                position: point,
                source: .estimatedPlane,
                distance: simd_distance(cameraPosition, point)
            )
        }

        return nil
    }

    /// Intersection of the camera ray with the infinite horizontal plane `y = floorY`.
    ///
    /// With origin O, direction D and the plane at `floorY`:
    ///     t = (floorY − O.y) / D.y
    ///     point = O + t·D
    /// Since D is a unit vector, `t` is already the distance in metres.
    func lockedFloorIntersection(in view: ARView, floorY: Float) -> Hit? {
        guard let ray = cameraRay(in: view) else { return nil }

        // Ray parallel to the floor (phone held upright) or pointing up: no
        // intersection exists in front of the camera.
        guard ray.direction.y < -1e-3 else { return nil }

        let t = (floorY - ray.origin.y) / ray.direction.y
        // A negative t means the floor is behind the camera — which happens if
        // the camera is below the locked floor level.
        guard t > 0, t <= Self.maxFloorDistance else { return nil }

        return Hit(
            position: ray.origin + t * ray.direction,
            source: .lockedFloorPlane,
            distance: t
        )
    }

    /// The camera ray right now: origin and unit direction, in world coordinates.
    func cameraRay(in view: ARView) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let frame = view.session.currentFrame else { return nil }
        let transform = frame.camera.transform
        // In ARKit the camera looks down -Z in its own space.
        let forward = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        return (transform.translation, simd_normalize(forward))
    }

    // MARK: - ARKit queries

    private func planeGeometryHit(in view: ARView) -> SIMD3<Float>? {
        raycast(in: view, allowing: .existingPlaneGeometry)
    }

    private func estimatedPlaneHit(in view: ARView) -> SIMD3<Float>? {
        raycast(in: view, allowing: .estimatedPlane)
    }

    private func raycast(in view: ARView, allowing target: ARRaycastQuery.Target) -> SIMD3<Float>? {
        // CAREFUL: `UIView.center` is the frame's centre in the *superview's*
        // space, not the centre of the view itself. With the ARView full-screen
        // inside a ZStack the two diverge and the ray comes out offset. The
        // correct point is the middle of `bounds`.
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let screenCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

        guard let query = view.makeRaycastQuery(
            from: screenCenter,
            allowing: target,
            alignment: .horizontal
        ), let result = view.session.raycast(query).first else { return nil }

        return result.worldTransform.translation
    }
}
