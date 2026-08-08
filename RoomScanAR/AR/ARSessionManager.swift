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

    /// O usuário marcou perto do primeiro canto e precisa decidir entre fechar
    /// o cômodo ou registrar o canto assim mesmo.
    @Published private(set) var offersAutoClose = false

    @Published private(set) var wallsBuilt = false

    /// Medições de pé-direito acumuladas nesta sessão.
    @Published private(set) var ceilingSamples: [Float] = []

    // Rascunho da abertura em construção.
    @Published private(set) var selectedWallIndex: Int?
    @Published private(set) var draftStart: Float?
    @Published private(set) var draftWidth: Float?
    @Published private(set) var draftType: OpeningType = .door
    @Published var draftHeight: Float = OpeningType.door.defaultHeight
    @Published var draftSill: Float = OpeningType.door.defaultSillHeight

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
    /// Respaldada por um `ARAnchor` **rastreado pela sessão**, e não por um
    /// `AnchorEntity(world:)`. Este último é só um transform fixo no frame da
    /// sessão: não recebe as correções de deriva do ARKit. Quando o usuário dá a
    /// volta no cômodo e retorna ao primeiro canto, o ARKit faz *loop closure* e
    /// reestima o frame do mundo em alguns centímetros — a geometria não-ancorada
    /// desliza junto, rígida, em relação ao cômodo real.
    ///
    /// Também não é uma âncora de plano: o ARKit funde plane anchors conforme
    /// refina a detecção, e a âncora absorvida é *removida* da sessão, levando
    /// consigo toda a geometria filha.
    private(set) var contentAnchor: AnchorEntity?
    private var contentARAnchor: ARAnchor?

    // MARK: - Privado

    private weak var arView: ARView?
    private let raycastService = RaycastService()
    private var renderer: RoomSceneRenderer?

    /// Último destino válido da linha elástica, preservado para que ela não pisque
    /// quando a mira momentaneamente sai do piso.
    private var lastElasticEnd: SIMD3<Float>?

    /// Canto aguardando decisão do usuário no diálogo de fechamento automático.
    private var pendingCorner: SIMD3<Float>?

    /// Distância mínima entre cantos consecutivos. Abaixo disso é quase certo
    /// que foi toque acidental, e um segmento degenerado quebraria a geometria.
    private static let minCornerSpacing: Float = 0.10

    /// Raio ao redor do primeiro canto que dispara a oferta de fechamento.
    private static let autoCloseRadius: Float = 0.30

    /// Faixa aceitável de pé-direito.
    ///
    /// Bem mais larga que os 2,00–4,00 m da especificação: telhado aparente,
    /// mezanino e pé-direito duplo passam facilmente de 4 m, e recusar a medida
    /// nesses casos obrigaria a digitar tudo à mão. O limite existe para pegar
    /// erro grosseiro de mira, não para impor um teto padrão.
    static let minCeilingHeight: Float = 1.8
    static let maxCeilingHeight: Float = 6.0

    /// Largura mínima de um vão.
    private static let minOpeningWidth: Float = 0.30

    /// Planos horizontais observados até agora, por identificador de âncora.
    private var planeSamples: [UUID: PlaneSample] = [:]
    private var latestCameraPosition: SIMD3<Float>?

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

    // MARK: - Fase: detecção de piso

    /// Trava o piso no candidato atual e avança para a marcação de cantos.
    ///
    /// A transição é explícita (botão) mesmo com o piso já detectado: um avanço
    /// automático surpreenderia o usuário no meio de uma gravação.
    func confirmFloor() {
        guard let candidate = floorCandidate, phase == .detectingFloor else { return }
        installContentAnchor(atWorldY: candidate.y)
        // A âncora fica exatamente no nível do piso, então no espaço dela o piso
        // é y = 0. Não há conversão a fazer nem valor a manter sincronizado.
        scan.floorY = 0
        isFloorLocked = true
        phase = .markingCorners
    }

    private func installContentAnchor(atWorldY worldY: Float) {
        guard let arView, contentAnchor == nil else { return }

        // Posiciona a âncora ao nível do piso, sob a posição atual da câmera.
        // Ancorar perto do conteúdo importa: uma correção de deriva que envolva
        // rotação vira erro de posição proporcional à distância até a âncora.
        var transform = matrix_identity_float4x4
        transform.columns.3.x = latestCameraPosition?.x ?? 0
        transform.columns.3.y = worldY
        transform.columns.3.z = latestCameraPosition?.z ?? 0

        let arAnchor = ARAnchor(name: "roomContent", transform: transform)
        arView.session.add(anchor: arAnchor)
        contentARAnchor = arAnchor

        // `AnchorEntity(anchor:)` segue as atualizações que o ARKit faz nessa
        // âncora — é isso que mantém a geometria colada ao cômodo real.
        let anchorEntity = AnchorEntity(anchor: arAnchor)
        arView.scene.addAnchor(anchorEntity)
        contentAnchor = anchorEntity
        renderer = RoomSceneRenderer(root: anchorEntity)
    }

    // MARK: - Conversão de coordenadas

    /// Mundo → espaço da âncora de conteúdo.
    ///
    /// Os cantos são guardados no espaço da âncora, não em coordenadas de mundo.
    /// Como o ARKit reposiciona a âncora a cada correção de deriva, coordenadas de
    /// mundo capturadas em instantes diferentes seriam mutuamente inconsistentes.
    /// Distâncias e áreas não mudam: a conversão é uma transformação rígida.
    private func toAnchorSpace(_ worldPoint: SIMD3<Float>) -> SIMD3<Float>? {
        contentAnchor?.convert(position: worldPoint, from: nil)
    }

    /// Direções não sofrem translação, só rotação — daí a sobrecarga própria.
    private func directionToAnchorSpace(_ worldDirection: SIMD3<Float>) -> SIMD3<Float>? {
        contentAnchor?.convert(direction: worldDirection, from: nil)
    }

    /// Altura do piso em coordenadas de mundo, que é o frame em que o raycast opera.
    private var worldFloorY: Float? {
        contentAnchor?.convert(position: SIMD3<Float>(0, scan.floorY, 0), to: nil).y
    }

    // MARK: - Fase: marcação de cantos

    /// Há superfície válida sob a mira para registrar um canto.
    var canMarkCorner: Bool {
        phase == .markingCorners && !scan.isClosed && reticleState != .searching
    }

    /// Três cantos já definem um polígono com área.
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
            selectedWallIndex != nil || draftStart != nil || !scan.openings.isEmpty
        case .detectingFloor, .results:
            false
        }
    }

    func markCorner() {
        guard phase == .markingCorners, !scan.isClosed,
              let hit = reticleWorldPoint,
              let local = toAnchorSpace(hit) else { return }

        // Trava o Y no piso. O raycast contra plano estimado devolve alturas
        // ligeiramente diferentes a cada ponto; sem travar, o polígono fica
        // não-planar e a área do shoelace sai errada.
        let corner = local.with(y: scan.floorY)

        if let last = scan.corners.last, simd_distance(last, corner) < Self.minCornerSpacing {
            setStatus("Canto muito perto do anterior — afaste pelo menos 10 cm")
            return
        }

        // Perto do primeiro canto: quase sempre a intenção é fechar o cômodo.
        // A especificação pede *oferecer* o fechamento, não fechar sozinho —
        // então o canto fica pendente até o usuário escolher.
        if scan.corners.count >= 3,
           let first = scan.corners.first,
           simd_distance(first, corner) < Self.autoCloseRadius {
            pendingCorner = corner
            offersAutoClose = true
            return
        }

        commit(corner)
    }

    /// Fecha o cômodo no primeiro canto, descartando o canto pendente.
    func acceptAutoClose() {
        pendingCorner = nil
        offersAutoClose = false
        closePolygon()
    }

    /// Registra o canto pendente mesmo estando perto do primeiro — cômodos
    /// estreitos legitimamente têm cantos a menos de 30 cm um do outro.
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

    // MARK: - Paredes 3D

    /// Levanta as paredes com a animação de subida.
    ///
    /// Acionado por botão, e não automaticamente ao fechar o polígono: além da
    /// regra de transições explícitas, é o momento visualmente mais forte do app
    /// e quem grava o vídeo precisa disparar na hora certa.
    func buildWalls() {
        guard scan.isClosed, scan.corners.count >= 3 else { return }
        wallsBuilt = true
        renderer?.buildWalls(scan: scan, highlighted: selectedWallIndex, animated: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Repete a animação sem reconstruir a malha — para regravar a tomada.
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

    // MARK: - Snap ortogonal

    func applyOrthogonalSnap() {
        guard scan.isClosed, !scan.isSnapped else { return }

        switch OrthogonalSnap.snap(scan.corners) {
        case .success(let corners):
            // Guarda os originais para que a operação seja reversível.
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

    // MARK: - Fase: pé-direito

    func beginHeightMeasurement() {
        guard scan.isClosed else { return }
        setStatus(nil)
        phase = .measuringHeight
    }

    /// Mede o pé-direito mirando no encontro entre parede e teto.
    ///
    /// Sem LiDAR não há superfície no teto para fazer raycast. O raio da câmera é
    /// intersectado com o plano vertical infinito da parede que está sendo mirada,
    /// e a altura sai da diferença entre o Y da interseção e o do piso.
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

        // Acumula em vez de substituir: um teto inclinado não tem *um*
        // pé-direito. Medir em pontos diferentes e escolher entre mínimo, média
        // e máximo é o que torna a fase utilizável fora de um cômodo de laje.
        ceilingSamples.append(height)
        setCeilingHeight(height)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func setCeilingHeight(_ value: Float) {
        scan.ceilingHeight = min(max(value, Self.minCeilingHeight), Self.maxCeilingHeight)
        setStatus(nil)
        rebuildWalls()
    }

    /// Resumo das medições acumuladas, quando há mais de uma.
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

    func confirmCeilingHeight() {
        guard phase == .measuringHeight else { return }
        // As paredes podem não ter sido levantadas antes; garante que existam
        // para que a seleção por toque tenha o que destacar.
        if !wallsBuilt { buildWalls() }
        setStatus(nil)
        phase = .markingOpenings
    }

    // MARK: - Fase: portas e janelas

    /// Seleciona a parede sob o ponto tocado na tela.
    ///
    /// Usa o raio da tela contra os planos verticais das paredes, e não um
    /// hit-test de colisão: as paredes são remalhadas a cada abertura inserida,
    /// e manter formas de colisão em dia seria mais frágil que refazer a conta.
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

    /// Marca uma das duas extremidades do vão, projetando o ponto da mira sobre
    /// a parede selecionada.
    func markOpeningPoint() {
        guard phase == .markingOpenings,
              let index = selectedWallIndex,
              let wall = scan.wall(at: index),
              let hit = reticleWorldPoint,
              let local = toAnchorSpace(hit),
              let distance = WallGeometry.project(local, onto: wall.start, wall.end) else { return }

        let wallLength = WallGeometry.length(from: wall.start, to: wall.end)
        let clamped = min(max(distance, 0), wallLength)

        guard let start = draftStart else {
            draftStart = clamped
            setStatus(nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }

        let width = abs(clamped - start)
        guard width >= Self.minOpeningWidth else {
            setStatus("Vão muito estreito — marque os dois pontos mais afastados")
            return
        }

        draftStart = min(start, clamped)
        draftWidth = width
        // Sugere o tipo pela largura: acima de 1,20 m uma folha de giro deixa de
        // fazer sentido, e o padrão vira porta de correr. Continua editável.
        setDraftType(OpeningType.suggested(forWidth: width))
        setStatus(nil)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func setDraftType(_ type: OpeningType) {
        draftType = type
        draftHeight = type.defaultHeight
        draftSill = type.defaultSillHeight
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
        draftStart = nil
        draftWidth = nil
        selectedWallIndex = nil
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

    // MARK: - Desfazer

    /// Desfaz a última ação da fase atual.
    func undo() {
        switch phase {
        case .markingOpenings:
            if selectedWallIndex != nil || draftStart != nil {
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
        // Descarta o destino congelado: ele pertencia ao canto que acabou de sair.
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

    /// Reavalia qual plano observado é o melhor candidato a piso.
    ///
    /// Não basta "primeiro plano horizontal com área suficiente": mesas e camas são
    /// detectadas antes do chão com frequência, e travar o piso numa mesa arruína
    /// todas as medidas. Critério: plano mais **baixo** que tenha área suficiente e
    /// que esteja bem abaixo da câmera (ou que o ARKit tenha classificado como piso).
    private func recomputeFloorCandidate() {
        let cameraY = latestCameraPosition?.y
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
            latestCameraPosition = cameraPosition
            if phase == .detectingFloor { recomputeFloorCandidate() }
        }

        // O raycast opera em coordenadas de mundo; os cantos vivem no espaço da
        // âncora. A conversão acontece nas duas fronteiras.
        let newState: ReticleState
        if phase == .measuringHeight {
            // Nesta fase o usuário aponta para cima, onde não há piso nenhum.
            // A mira passa a refletir se existe parede sob o alvo — senão ficaria
            // branca o tempo todo, sem informar nada.
            reticleWorldPoint = nil
            newState = ceilingAimState(in: arView)
        } else {
            let hit = raycastService.floorHit(in: arView, lockedFloorY: isFloorLocked ? worldFloorY : nil)
            reticleWorldPoint = hit?.position
            newState =
                switch hit {
                case .none: .searching
                case .some(let h): h.isPrecise ? .valid : .approximate
                }
        }
        if newState != reticleState { reticleState = newState }

        updateOpeningPreview()

        // Linha elástica do último canto até a mira. O destino é travado em
        // `floorY` para que a linha fique deitada no piso.
        if phase == .markingCorners, !scan.isClosed, let last = scan.corners.last {
            if let point = reticleWorldPoint, let local = toAnchorSpace(point) {
                lastElasticEnd = local.with(y: scan.floorY)
            }
            // Sem acerto neste frame — normalmente o celular apontando para cima
            // ou para o horizonte — a linha continua visível no último ponto
            // válido, em cinza. Some-la a cada oscilação da mira pisca demais.
            renderer?.updateElastic(from: last, to: lastElasticEnd, isStale: reticleWorldPoint == nil)
        } else {
            renderer?.hideElastic()
        }

        // Os rótulos vivem no espaço da âncora, então a câmera precisa vir junto.
        if let cameraPosition, let localCamera = toAnchorSpace(cameraPosition) {
            renderer?.faceCamera(from: localCamera)
        }
    }

    /// Qualidade da mira apontada para o encontro parede/teto.
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

    /// Retângulo do vão em construção, atualizado a cada frame.
    ///
    /// Antes do segundo ponto o lado direito acompanha a mira; depois dele fica
    /// fixo, para que os steppers de altura e peitoril mostrem o efeito ao vivo.
    private func updateOpeningPreview() {
        guard phase == .markingOpenings,
              let index = selectedWallIndex,
              let wall = scan.wall(at: index),
              let start = draftStart else {
            renderer?.hideOpeningPreview()
            return
        }

        let end: Float
        if let width = draftWidth {
            end = start + width
        } else if let hit = reticleWorldPoint,
                  let local = toAnchorSpace(hit),
                  let distance = WallGeometry.project(local, onto: wall.start, wall.end) {
            let wallLength = WallGeometry.length(from: wall.start, to: wall.end)
            end = min(max(distance, 0), wallLength)
        } else {
            end = start
        }

        renderer?.updateOpeningPreview(
            wallStart: wall.start,
            wallEnd: wall.end,
            fromDistance: start,
            toDistance: end,
            sill: draftSill,
            top: min(draftSill + draftHeight, scan.ceilingHeight),
            color: draftType == .window ? .systemTeal : .systemOrange
        )
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
