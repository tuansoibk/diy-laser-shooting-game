import SwiftUI
import AVFoundation
import Combine

// MARK: - App state

enum AppState {
    case setup
    case roundMenu(gameId: Int)
    case idle(gameId: Int, roundId: Int)
    case armed(gameId: Int, roundId: Int)
    case posting(gameId: Int, roundId: Int, image: UIImage, dots: [CGPoint])
    case result(gameId: Int, roundId: Int, image: UIImage, dots: [CGPoint], board: BoardQuad?, shot: ShotResult)
}

// MARK: - ViewModel

@MainActor
class AppViewModel: ObservableObject {
    @Published var appState: AppState = .setup
    @Published var exposureLocked = false
    @Published var errorMessage: String? = nil

    // Persisted settings
    @AppStorage("backendURL")  var backendURL: String = "http://192.168.1.1:8000"
    @AppStorage("playerName")  var playerName: String = "Player"

    let camera = CameraManager()
    private let dotDetector   = RedDotDetector()
    private let boardDetector = BoardDetector()
    private var isArmed = false   // processing queue only

    var api: APIClient { APIClient(baseURL: backendURL) }

    init() {
        camera.onFrame = { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        camera.start()
    }

    // MARK: Setup

    func startGame() async {
        errorMessage = nil
        do {
            let game = try await api.createGame(playerName: playerName)
            appState = .roundMenu(gameId: game.id)
        } catch {
            errorMessage = "Cannot reach backend: \(error.localizedDescription)"
        }
    }

    // MARK: Round management

    func startRound(gameId: Int) async {
        errorMessage = nil
        do {
            let round = try await api.createRound(gameId: gameId)
            appState = .idle(gameId: gameId, roundId: round.id)
        } catch {
            errorMessage = "Failed to start round: \(error.localizedDescription)"
        }
    }

    func endRound(gameId: Int, roundId: Int) async {
        try? await api.endRound(roundId: roundId)
        appState = .roundMenu(gameId: gameId)
    }

    // MARK: Detection

    func arm(gameId: Int, roundId: Int) {
        camera.processingQueue.async { self.isArmed = true }
        appState = .armed(gameId: gameId, roundId: roundId)
    }

    func disarm(gameId: Int, roundId: Int) {
        camera.processingQueue.async { self.isArmed = false }
        appState = .idle(gameId: gameId, roundId: roundId)
    }

    func lockExposure() {
        camera.lockExposure()
        exposureLocked = true
    }

    // Runs on camera.processingQueue
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isArmed else { return }
        let results = dotDetector.detect(in: pixelBuffer)
        guard !results.isEmpty else { return }

        isArmed = false

        let boardQuad = boardDetector.detect(in: pixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext()
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        let dots = results.map { $0.normalizedCenter }

        DispatchQueue.main.async {
            guard case .armed(let gameId, let roundId) = self.appState else { return }
            self.appState = .posting(gameId: gameId, roundId: roundId, image: image, dots: dots)
            Task { await self.submitShot(gameId: gameId, roundId: roundId,
                                         image: image, dots: dots, board: boardQuad, jpeg: jpeg) }
        }
    }

    private func submitShot(gameId: Int, roundId: Int,
                             image: UIImage, dots: [CGPoint], board: BoardQuad?, jpeg: Data) async {
        do {
            let shot = try await api.detectShot(roundId: roundId, jpeg: jpeg)
            appState = .result(gameId: gameId, roundId: roundId,
                               image: image, dots: dots, board: board, shot: shot)
        } catch {
            errorMessage = "Backend error: \(error.localizedDescription)"
            appState = .idle(gameId: gameId, roundId: roundId)
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch vm.appState {
            case .setup:
                SetupView(vm: vm)
            case .roundMenu(let gameId):
                RoundMenuView(vm: vm, gameId: gameId)
            case .idle(let gameId, let roundId):
                IdleView(vm: vm, gameId: gameId, roundId: roundId)
            case .armed(let gameId, let roundId):
                ArmedView(vm: vm, gameId: gameId, roundId: roundId)
            case .posting(_, _, let image, let dots):
                PostingView(image: image, dots: dots)
            case .result(let gameId, let roundId, let image, let dots, let board, let shot):
                ResultView(vm: vm, gameId: gameId, roundId: roundId,
                           image: image, normalizedDots: dots, boardQuad: board, shot: shot)
            }

            // Floating error toast
            if let msg = vm.errorMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(8)
                        .padding()
                        .onTapGesture { vm.errorMessage = nil }
                }
            }
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Camera preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}

// MARK: - Setup view

struct SetupView: View {
    @ObservedObject var vm: AppViewModel
    @State private var connecting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Shooting Game")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                    .padding(.top, 80)

                VStack(alignment: .leading, spacing: 8) {
                    label("Player name")
                    TextField("Player", text: $vm.playerName)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("Backend URL")
                    TextField("http://192.168.x.x:8000", text: $vm.backendURL)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }

                Button {
                    connecting = true
                    Task {
                        await vm.startGame()
                        connecting = false
                    }
                } label: {
                    HStack {
                        if connecting { ProgressView().tint(.black) }
                        Text(connecting ? "Connecting…" : "Start Game")
                            .font(.headline.bold())
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .cornerRadius(12)
                }
                .disabled(connecting)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.bold()).foregroundColor(.white.opacity(0.6))
    }
}

// MARK: - Round menu

struct RoundMenuView: View {
    @ObservedObject var vm: AppViewModel
    let gameId: Int
    @State private var starting = false

    var body: some View {
        VStack(spacing: 32) {
            Text("Game #\(gameId)")
                .font(.title2.bold())
                .foregroundColor(.white.opacity(0.5))

            Text(vm.playerName)
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Button {
                starting = true
                Task {
                    await vm.startRound(gameId: gameId)
                    starting = false
                }
            } label: {
                HStack {
                    if starting { ProgressView().tint(.black) }
                    Text(starting ? "Starting…" : "Start Round")
                        .font(.title2.bold())
                }
                .foregroundColor(.black)
                .padding(.horizontal, 48)
                .padding(.vertical, 16)
                .background(Color.green)
                .cornerRadius(12)
            }
            .disabled(starting)

            Button("New Game") {
                vm.appState = .setup
            }
            .foregroundColor(.white.opacity(0.5))
            .font(.subheadline)
        }
    }
}

// MARK: - Idle view

struct IdleView: View {
    @ObservedObject var vm: AppViewModel
    let gameId: Int
    let roundId: Int

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()

            VStack {
                statusBar
                Spacer()
                buttons
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: vm.exposureLocked ? "lock.fill" : "lock.open")
                Text(vm.exposureLocked ? "Locked" : "Auto")
            }
            .foregroundColor(vm.exposureLocked ? .yellow : .white.opacity(0.5))

            Divider().frame(height: 14).background(Color.white.opacity(0.3))

            Text("Round #\(roundId)")
                .foregroundColor(.white.opacity(0.7))
        }
        .font(.caption.bold())
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
        .cornerRadius(8)
        .padding(.top, 56)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { vm.lockExposure() } label: {
                    Label("Lock Exp.", systemImage: "lock")
                        .font(.subheadline.bold()).foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.yellow).cornerRadius(10)
                }
                Button { vm.arm(gameId: gameId, roundId: roundId) } label: {
                    Text("Ready")
                        .font(.title2.bold()).foregroundColor(.white)
                        .padding(.horizontal, 36).padding(.vertical, 12)
                        .background(Color.green).cornerRadius(10)
                }
            }
            Button {
                Task { await vm.endRound(gameId: gameId, roundId: roundId) }
            } label: {
                Text("End Round")
                    .font(.subheadline).foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.bottom, 52)
    }
}

// MARK: - Armed view

struct ArmedView: View {
    @ObservedObject var vm: AppViewModel
    let gameId: Int
    let roundId: Int

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()
            VStack {
                ScanningBadge().padding(.top, 56)
                Spacer()
                Button { vm.disarm(gameId: gameId, roundId: roundId) } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.subheadline.bold()).foregroundColor(.white)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Color.red.opacity(0.8)).cornerRadius(10)
                }
                .padding(.bottom, 52)
            }
        }
    }
}

struct ScanningBadge: View {
    @State private var blinking = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .opacity(blinking ? 1 : 0.2)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: blinking)
            Text("Scanning for dot…").font(.subheadline.bold()).foregroundColor(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black.opacity(0.65)).cornerRadius(8)
        .onAppear { blinking = true }
    }
}

// MARK: - Posting view

struct PostingView: View {
    let image: UIImage
    let dots: [CGPoint]

    var body: some View {
        ZStack {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Sending to backend…").font(.subheadline.bold()).foregroundColor(.white)
                }
                .padding(14)
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
                .padding(.bottom, 52)
            }
        }
    }
}

// MARK: - Result view

struct ResultView: View {
    @ObservedObject var vm: AppViewModel
    let gameId: Int
    let roundId: Int
    let image: UIImage
    let normalizedDots: [CGPoint]
    let boardQuad: BoardQuad?
    let shot: ShotResult

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let imgSize = fittedSize(for: image.size, in: geo.size)
                let ox = (geo.size.width  - imgSize.width)  / 2
                let oy = (geo.size.height - imgSize.height) / 2

                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                if let quad = boardQuad {
                    BoardOutline(quad: quad, imgSize: imgSize, offset: CGPoint(x: ox, y: oy))
                }

                ForEach(normalizedDots.indices, id: \.self) { i in
                    let dot = normalizedDots[i]
                    let inside = boardQuad.map { $0.contains(dot) } ?? true
                    DotOverlay(index: i + 1, color: inside ? .green : .yellow)
                        .position(x: ox + dot.x * imgSize.width,
                                  y: oy + dot.y * imgSize.height)
                }
            }

            VStack {
                // Score badge
                if shot.detected, let score = shot.score {
                    Text("\(score)")
                        .font(.system(size: 72, weight: .black))
                        .foregroundColor(scoreColor(score))
                        .shadow(color: .black, radius: 4)
                        .padding(.top, 56)
                }
                Spacer()
                bottomBar
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if shot.detected {
                VStack(spacing: 3) {
                    if let dist = shot.distancePx {
                        Text(String(format: "%.1f px from centre", dist))
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                    }
                    if boardQuad == nil {
                        Text("Board not detected").font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            } else {
                Text("No shot detected by backend")
                    .font(.subheadline).foregroundColor(.orange)
            }

            HStack(spacing: 12) {
                Button {
                    vm.arm(gameId: gameId, roundId: roundId)
                } label: {
                    Text("Next Shot")
                        .font(.title2.bold()).foregroundColor(.white)
                        .padding(.horizontal, 36).padding(.vertical, 14)
                        .background(Color.green).cornerRadius(10)
                }
                Button {
                    Task { await vm.endRound(gameId: gameId, roundId: roundId) }
                } label: {
                    Text("End Round")
                        .font(.subheadline).foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(Color.white.opacity(0.15)).cornerRadius(10)
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.7))
        .cornerRadius(14)
        .padding(.bottom, 44)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 8...10: return .green
        case 5...7:  return .yellow
        default:     return .red
        }
    }

    private func fittedSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

// MARK: - Shared overlays

struct BoardOutline: View {
    let quad: BoardQuad
    let imgSize: CGSize
    let offset: CGPoint
    var body: some View {
        Path { path in
            let pts = quad.corners.map {
                CGPoint(x: offset.x + $0.x * imgSize.width,
                        y: offset.y + $0.y * imgSize.height)
            }
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        .stroke(Color.cyan.opacity(0.8), lineWidth: 2)
    }
}

struct DotOverlay: View {
    let index: Int
    let color: Color
    @State private var pulsing = false
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.4), lineWidth: 2)
                .frame(width: pulsing ? 50 : 34, height: pulsing ? 50 : 34)
                .animation(.easeOut(duration: 0.4), value: pulsing)
            Circle().stroke(color, lineWidth: 2).frame(width: 34, height: 34)
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(index)").font(.system(size: 10, weight: .bold)).foregroundColor(color)
                .offset(x: 14, y: -14)
        }
        .onAppear { pulsing = true }
    }
}
