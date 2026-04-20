import SwiftUI
import AVFoundation
import Combine

// MARK: - App state

enum AppState {
    case connect
    case idle
    case armed
    case posting(image: UIImage, dots: [CGPoint])
    case result(image: UIImage, dots: [CGPoint], board: BoardQuad?, shot: ShotResult)
}

// MARK: - ViewModel

@MainActor
class AppViewModel: ObservableObject {
    @Published var appState: AppState = .connect
    @Published var exposureLocked = false
    @Published var errorMessage: String? = nil
    @Published var debugResult: DebugDetectResponse? = nil
    @Published var isDebugging = false

    @AppStorage("backendURL") var backendURL: String = ""

    let camera = CameraManager()
    private let dotDetector   = RedDotDetector()
    private let boardDetector = BoardDetector()
    // nonisolated so reads/writes on processingQueue never hop to MainActor
    private nonisolated(unsafe) var isArmed = false
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5

    var api: APIClient { APIClient(baseURL: backendURL) }

    init() {
        camera.onFrame = { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        camera.start()
        if !backendURL.isEmpty {
            appState = .idle
        }
        // Pre-warm Vision so the first real boardDetector.detect() call is instant
        let bd = boardDetector
        DispatchQueue.global(qos: .userInitiated).async { bd.warmUp() }
    }

    // MARK: Connection

    func connect(url: String) {
        backendURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                       .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        appState = .idle
    }

    // MARK: Detection

    func arm() {
        isArmed = true
        appState = .armed
    }

    func disarm() {
        isArmed = false
        appState = .idle
    }

    func captureDebug() {
        isDebugging = true
        camera.captureFrame { [weak self] pixelBuffer in
            guard let self else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ctx = CIContext()
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent),
                  let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
            else {
                DispatchQueue.main.async { self.isDebugging = false }
                return
            }
            Task { @MainActor in
                do {
                    self.debugResult = try await self.api.debugDetect(jpeg: jpeg)
                } catch {
                    self.errorMessage = "Debug failed: \(error.localizedDescription)"
                }
                self.isDebugging = false
            }
        }
    }

    func toggleExposureLock() {
        if exposureLocked {
            camera.unlockExposure()
            exposureLocked = false
        } else {
            camera.lockExposure()
            exposureLocked = true
        }
    }

    // Runs on camera.processingQueue
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isArmed else { return }
        let results = dotDetector.detect(in: pixelBuffer)
        guard !results.isEmpty else { return }

        let boardQuad = boardDetector.detect(in: pixelBuffer)

        // Skip backend call if no dot is inside the board area
        if let quad = boardQuad {
            let hasInsideDot = results.contains { quad.contains($0.normalizedCenter) }
            guard hasInsideDot else { return }
        }

        isArmed = false

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext()
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        let dots = results.map { $0.normalizedCenter }

        // Best inside dot (largest cluster) sent as a position hint to the backend
        let insideDots = boardQuad == nil
            ? results
            : results.filter { boardQuad!.contains($0.normalizedCenter) }
        let hint = insideDots.max(by: { $0.clusterSize < $1.clusterSize })?.normalizedCenter

        DispatchQueue.main.async {
            guard case .armed = self.appState else { return }
            self.appState = .posting(image: image, dots: dots)
            Task { await self.submitShot(image: image, dots: dots, board: boardQuad,
                                         jpeg: jpeg, hint: hint) }
        }
    }

    private func submitShot(image: UIImage, dots: [CGPoint], board: BoardQuad?,
                             jpeg: Data, hint: CGPoint?) async {
        do {
            let shot = try await api.detectShot(jpeg: jpeg,
                                                hintX: hint.map { Double($0.x) },
                                                hintY: hint.map { Double($0.y) })
            consecutiveFailures = 0
            if shot.multipleDots {
                errorMessage = "Multiple dots detected — please retry"
                arm()
                return
            }
            appState = .result(image: image, dots: dots, board: board, shot: shot)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                consecutiveFailures = 0
                errorMessage = "Backend unreachable — stopping"
                appState = .idle
            } else {
                errorMessage = "Backend error (\(consecutiveFailures)/\(maxConsecutiveFailures))"
                arm()
            }
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
            case .connect:
                ConnectView(vm: vm)
            case .idle:
                IdleView(vm: vm)
            case .armed:
                ArmedView(vm: vm)
            case .posting(let image, let dots):
                PostingView(image: image, dots: dots)
            case .result(let image, let dots, let board, let shot):
                ResultView(vm: vm, image: image, normalizedDots: dots, boardQuad: board, shot: shot)
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

// MARK: - Connect view

struct ConnectView: View {
    @ObservedObject var vm: AppViewModel
    @State private var url: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Shooting Game")
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text("Enter the backend server address")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER URL")
                    .font(.caption.bold())
                    .foregroundColor(.white.opacity(0.5))
                    .tracking(1)
                TextField("http://192.168.x.x:8000", text: $url)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
            }

            Button {
                vm.connect(url: url)
            } label: {
                Text("Connect")
                    .font(.headline.bold())
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(url.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.white.opacity(0.3) : Color.green)
                    .cornerRadius(12)
            }
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)

            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear { url = vm.backendURL }
    }
}

// MARK: - Server change sheet

struct ServerSheet: View {
    @ObservedObject var vm: AppViewModel
    @Binding var isPresented: Bool
    @State private var url: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Server address") {
                    TextField("http://192.168.x.x:8000", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Change Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.connect(url: url)
                        isPresented = false
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { url = vm.backendURL }
    }
}

// MARK: - Idle view

struct IdleView: View {
    @ObservedObject var vm: AppViewModel
    @State private var showServerSheet = false

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()

            VStack {
                topBar
                Spacer()
            }
        }
        .sheet(isPresented: $showServerSheet) {
            ServerSheet(vm: vm, isPresented: $showServerSheet)
        }
        .sheet(item: $vm.debugResult) { result in
            DebugResultSheet(result: result)
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button { showServerSheet = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "network")
                        Text(serverHost)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(8)
                }
            }
            HStack(spacing: 12) {
                Button { vm.toggleExposureLock() } label: {
                    Label("Lock Exp.", systemImage: vm.exposureLocked ? "lock.fill" : "lock.open")
                        .font(.subheadline.bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(vm.exposureLocked ? Color.yellow : Color.white.opacity(0.9))
                        .cornerRadius(10)
                }
                Button {
                    vm.captureDebug()
                } label: {
                    if vm.isDebugging {
                        ProgressView().tint(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color.black.opacity(0.5)).cornerRadius(10)
                    } else {
                        Label("Debug", systemImage: "ladybug")
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color.black.opacity(0.5)).cornerRadius(10)
                    }
                }
                .disabled(vm.isDebugging)
                Button { vm.arm() } label: {
                    Text("Ready")
                        .font(.title2.bold()).foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green).cornerRadius(10)
                }
            }
        }
        .padding(.top, 56)
        .padding(.horizontal, 16)
    }

    private var serverHost: String {
        URL(string: vm.backendURL)?.host ?? vm.backendURL
    }
}

// MARK: - Armed view

struct ArmedView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()
            VStack {
                HStack(spacing: 12) {
                    ScanningBadge()
                    Spacer()
                    Button {
                        vm.captureDebug()
                    } label: {
                        if vm.isDebugging {
                            ProgressView().tint(.white)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(Color.black.opacity(0.5)).cornerRadius(10)
                        } else {
                            Label("Debug", systemImage: "ladybug")
                                .font(.subheadline.bold()).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(Color.black.opacity(0.5)).cornerRadius(10)
                        }
                    }
                    .disabled(vm.isDebugging)
                    Button { vm.disarm() } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.subheadline.bold()).foregroundColor(.white)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Color.red.opacity(0.8)).cornerRadius(10)
                    }
                }
                .padding(.top, 56)
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .sheet(item: $vm.debugResult) { result in
            DebugResultSheet(result: result)
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
    let image: UIImage
    let normalizedDots: [CGPoint]
    let boardQuad: BoardQuad?
    let shot: ShotResult

    private let resultCountdownSeconds = 1
    @State private var countdown = 1
    @State private var countdownTask: Task<Void, Never>? = nil

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
        .onAppear { startCountdown() }
        .onDisappear { countdownTask?.cancel() }
    }

    private func startCountdown() {
        countdown = resultCountdownSeconds
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: resultCountdownSeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { countdown = remaining }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { vm.arm() }
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

            Button {
                countdownTask?.cancel()
                vm.arm()
            } label: {
                HStack(spacing: 6) {
                    Text("Next Shot")
                    Text("(\(countdown))").monospacedDigit()
                        .foregroundColor(.white.opacity(0.7))
                }
                .font(.title2.bold()).foregroundColor(.white)
                .padding(.horizontal, 36).padding(.vertical, 14)
                .background(Color.green).cornerRadius(10)
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
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

// MARK: - Debug result sheet

extension DebugDetectResponse: Identifiable {
    public var id: String { stage + (debugImage?.prefix(16) ?? "") }
}

struct DebugResultSheet: View {
    let result: DebugDetectResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Debug image from backend
                    if let b64 = result.debugImage,
                       let data = Data(base64Encoded: b64),
                       let uiImg = UIImage(data: data) {
                        Image(uiImage: uiImg)
                            .resizable().scaledToFit()
                            .cornerRadius(8)
                    }

                    // Stage + ArUco
                    HStack(spacing: 12) {
                        stageBadge
                        Text("ArUco: \(result.arucoIds.isEmpty ? "none" : result.arucoIds.map(String.init).joined(separator: ", "))")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    // Result summary
                    if let r = result.result {
                        if r.detected, let score = r.score {
                            Text("Score: \(score)  dist: \(String(format: "%.1f", r.distancePx ?? 0)) px")
                                .font(.headline)
                        } else {
                            Text("Backend: no dot detected").font(.headline).foregroundColor(.orange)
                        }
                    }

                    // Contour list
                    if !result.contours.isEmpty {
                        Text("Contours (\(result.contours.count))")
                            .font(.caption.bold()).foregroundColor(.secondary)
                        ForEach(result.contours) { c in
                            HStack {
                                Image(systemName: c.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(c.passed ? .green : .red)
                                Text("a=\(Int(c.area))  circ=\(String(format: "%.2f", c.circularity))")
                                    .font(.caption.monospaced())
                                Spacer()
                                if let reason = c.failReason {
                                    Text(reason).font(.caption).foregroundColor(.red)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Debug Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var stageBadge: some View {
        let (label, color): (String, Color) = switch result.stage {
        case "ok":    ("OK", .green)
        case "dots":  ("No dot", .orange)
        case "aruco": ("No board", .red)
        default:      (result.stage, .gray)
        }
        return Text(label)
            .font(.caption.bold()).foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color).cornerRadius(6)
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
