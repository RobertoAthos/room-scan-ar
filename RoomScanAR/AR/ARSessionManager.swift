import ARKit
import Combine
import RealityKit
import simd

/// Estado da mira. Deliberadamente grosso (poucos casos, `Equatable`): é publicado
/// para a SwiftUI, e a posição exata do raycast muda a cada frame. Publicar o
/// `SIMD3` redesenharia a interface 60×/s sem necessidade — a cor da mira só
/// precisa saber se há superfície válida embaixo dela.
enum ReticleState: Equatable, Sendable {
    /// Nenhuma superfície sob a mira.
    case searching
    /// Plano estimado — usável, mas menos preciso.
    case approximate
    /// Geometria de plano detectada — posição confiável.
    case valid
}

/// Amostra de um plano horizontal observado, reduzida a valores `Sendable`.
///
/// `ARPlaneAnchor` não é `Sendable`, então os callbacks do delegate extraem
/// só os escalares de que precisamos antes de cruzar para o MainActor.
private struct PlaneSample: Sendable, Equatable {
    let anchorID: UUID
    let y: Float
    let area: Float
    let isClassifiedFloor: Bool
}

/// Candidato a piso, exposto ao HUD antes da confirmação do usuário.
struct FloorCandidate: Equatable, Sendable {
    let y: Float
    let area: Float
    let isClassifiedFloor: Bool
}

/// Ciclo de vida da sessão AR e detecção do piso.
///
/// Não possui a `ARSession`: em RealityKit a `ARView` cria e é dona da sua própria
/// sessão (`ARView.session` é somente-leitura). Este objeto se acopla a uma view
/// existente via `attach(to:)`.
@MainActor
final class ARSessionManager: NSObject, ObservableObject {

    // MARK: - Estado publicado

    @Published private(set) var phase: ScanPhase = .detectingFloor
    @Published private(set) var scan = RoomScan()
    @Published private(set) var reticleState: ReticleState = .searching
    @Published private(set) var floorCandidate: FloorCandidate?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isFloorLocked = false

    /// AR não funciona no Simulator. Quando falso, a interface mostra um aviso
    /// em vez de tentar criar a `ARView` (que aborta no Simulator).
    let isSupported = ARWorldTrackingConfiguration.isSupported

    @Published var showDebugOverlays = false {
        didSet { applyDebugOptions() }
    }

    // MARK: - Estado não publicado (alta frequência)

    /// Ponto de mundo atingido pela mira neste frame. Consumido pela camada 3D
    /// (linha elástica, marcação de canto), nunca diretamente pela SwiftUI.
    private(set) var reticleWorldPoint: SIMD3<Float>?

    /// Âncora raiz de todo o conteúdo 3D do cômodo.
    ///
    /// Deliberadamente uma âncora de **mundo**, não uma `AnchorEntity(anchor: planeAnchor)`.
    /// O ARKit funde plane anchors conforme refina a detecção, e a âncora absorvida
    /// é *removida* da sessão — levaria junto toda a geometria pendurada nela.
    private(set) var contentAnchor: AnchorEntity?

    // MARK: - Privado

    private weak var arView: ARView?
    private let raycastService = RaycastService()
    private var renderer: RoomSceneRenderer?

    /// Distância mínima entre cantos consecutivos. Abaixo disso é quase certo
    /// que foi toque acidental, e um segmento degenerado quebraria a geometria.
    private static let minCornerSpacing: Float = 0.10

    /// Planos horizontais observados até agora, por identificador de âncora.
    private var planeSamples: [UUID: PlaneSample] = [:]
    private var latestCameraY: Float?

    /// Área mínima para considerar um plano como piso.
    private static let minFloorArea: Float = 0.5
    /// Distância vertical mínima entre a câmera e o plano para descartar mesas e camas.
    /// Um celular é segurado por volta de 1,2–1,6 m; uma mesa fica a ~0,75 m.
    private static let minCameraDrop: Float = 0.8

    // MARK: - Ciclo de vida

    func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        // Fixa a fila do delegate no main queue. Sem isso os callbacks chegam numa
        // fila indefinida e o `MainActor.assumeIsolated` abaixo não teria garantia.
        view.session.delegateQueue = .main
        applyDebugOptions()
        runSession(resetting: true)
    }

    func runSession(resetting: Bool) {
        guard let arView, isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        // Sem LiDAR: nada de sceneReconstruction, sceneDepth ou sceneUnderstanding.
        // A geometria do cômodo é calculada manualmente a partir dos raycasts.
        arView.session.run(config, options: resetting ? [.resetTracking, .removeExistingAnchors] : [])
    }

    func pause() {
        arView?.session.pause()
    }

    /// Recomeça do zero: limpa o modelo, a cena e o rastreamento.
    func reset() {
        planeSamples.removeAll()
        latestCameraY = nil
        floorCandidate = nil
        reticleWorldPoint = nil
        reticleState = .searching
        statusMessage = nil
        isFloorLocked = false
        scan = RoomScan()
        phase = .detectingFloor

        renderer?.clear()
        renderer = nil
        if let contentAnchor {
            contentAnchor.removeFromParent()
        }
        contentAnchor = nil
        runSession(resetting: true)
    }

    // MARK: - Fase: detecção de piso

    /// Trava o piso no candidato atual e avança para a marcação de cantos.
    ///
    /// A transição é explícita (botão) mesmo com o piso já detectado: um avanço
    /// automático surpreenderia o usuário no meio de uma gravação.
    func confirmFloor() {
        guard let candidate = floorCandidate, phase == .detectingFloor else { return }
        scan.floorY = candidate.y
        isFloorLocked = true
        installContentAnchor(atY: candidate.y)
        phase = .markingCorners
    }

    private func installContentAnchor(atY y: Float) {
        guard let arView, contentAnchor == nil else { return }
        // Âncora na origem do mundo: os filhos recebem coordenadas de mundo
        // absolutas, iguais às que guardamos em `RoomScan.corners`.
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        arView.scene.addAnchor(anchor)
        contentAnchor = anchor
        renderer = RoomSceneRenderer(root: anchor)
    }

    // MARK: - Fase: marcação de cantos

    /// Há superfície válida sob a mira para registrar um canto.
    var canMarkCorner: Bool {
        phase == .markingCorners && reticleState != .searching
    }

    var canUndo: Bool {
        phase == .markingCorners && !scan.corners.isEmpty
    }

    func markCorner() {
        guard phase == .markingCorners, let hit = reticleWorldPoint else { return }

        // Trava o Y no piso. O raycast contra plano estimado devolve alturas
        // ligeiramente diferentes a cada ponto; sem travar, o polígono fica
        // não-planar e a área do shoelace sai errada.
        let corner = hit.with(y: scan.floorY)

        if let last = scan.corners.last, simd_distance(last, corner) < Self.minCornerSpacing {
            setStatus("Canto muito perto do anterior — afaste pelo menos 10 cm")
            return
        }

        scan.corners.append(corner)
        setStatus(nil)
        renderer?.syncCorners(scan.corners, closed: scan.isClosed)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func undoLastCorner() {
        guard !scan.corners.isEmpty else { return }
        scan.corners.removeLast()
        setStatus(nil)
        renderer?.syncCorners(scan.corners, closed: scan.isClosed)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Reavalia qual plano observado é o melhor candidato a piso.
    ///
    /// Não basta "primeiro plano horizontal com área suficiente": mesas e camas são
    /// detectadas antes do chão com frequência, e travar o piso numa mesa arruína
    /// todas as medidas. Critério: plano mais **baixo** que tenha área suficiente e
    /// que esteja bem abaixo da câmera (ou que o ARKit tenha classificado como piso).
    private func recomputeFloorCandidate() {
        let cameraY = latestCameraY
        let qualifying = planeSamples.values.filter { sample in
            guard sample.area >= Self.minFloorArea else { return false }
            if sample.isClassifiedFloor { return true }
            guard let cameraY else { return false }
            return (cameraY - sample.y) > Self.minCameraDrop
        }

        // Mais baixo primeiro; empate desempata pela maior área.
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

    // MARK: - Loop por frame

    /// Chamado uma vez por frame para atualizar a mira.
    fileprivate func onFrame() {
        guard let arView else { return }

        let cameraPosition = arView.session.currentFrame?.camera.transform.translation
        if let cameraPosition {
            latestCameraY = cameraPosition.y
            if phase == .detectingFloor { recomputeFloorCandidate() }
        }

        let hit = raycastService.horizontalHit(in: arView)
        reticleWorldPoint = hit?.position

        let newState: ReticleState =
            switch hit {
            case .none: .searching
            case .some(let h): h.isPrecise ? .valid : .approximate
            }
        if newState != reticleState { reticleState = newState }

        // Linha elástica do último canto até a mira. O destino também é travado
        // em `floorY` para que a linha fique deitada no piso.
        if phase == .markingCorners, let last = scan.corners.last {
            renderer?.updateElastic(from: last, to: reticleWorldPoint?.with(y: scan.floorY))
        } else {
            renderer?.hideElastic()
        }

        if let cameraPosition {
            renderer?.faceCamera(from: cameraPosition)
        }
    }

    fileprivate func ingest(planes: [PlaneSample]) {
        for sample in planes { planeSamples[sample.anchorID] = sample }
        if phase == .detectingFloor { recomputeFloorCandidate() }
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
        // `delegateQueue` foi fixada em `.main` em `attach(to:)`, então já estamos
        // no MainActor. `assumeIsolated` evita o custo de um hop de ator por frame.
        // O `ARFrame` não é retido — só a mira é atualizada.
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
        // O ARKit remove âncoras ao fundir planos vizinhos — precisamos esquecê-las
        // para não manter um candidato a piso que já não existe.
        let ids = anchors.compactMap { $0 as? ARPlaneAnchor }.map(\.identifier)
        guard !ids.isEmpty else { return }
        MainActor.assumeIsolated { self.forget(anchorIDs: ids) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // Converte para String aqui, no delegate: `ARCamera` não é `Sendable`.
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

    /// Reduz âncoras de plano horizontais a valores `Sendable`.
    private nonisolated static func samples(from anchors: [ARAnchor]) -> [PlaneSample] {
        anchors.compactMap { anchor in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            let extent = plane.planeExtent
            let isFloor = ARPlaneAnchor.isClassificationSupported && plane.classification == .floor
            return PlaneSample(
                anchorID: plane.identifier,
                // O centro do plano em coordenadas de mundo: a translação da âncora
                // mais o offset do centro local.
                y: plane.transform.columns.3.y + plane.center.y,
                area: extent.width * extent.height,
                isClassifiedFloor: isFloor
            )
        }
    }
}
