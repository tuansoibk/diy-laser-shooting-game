import SwiftUI
import AVFoundation
import Combine

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

// MARK: - State

enum DetectionState {
    case idle
    case armed
    case result(image: UIImage, normalizedDots: [CGPoint], boardQuad: BoardQuad?)
}

// MARK: - ViewModel

class AppViewModel: ObservableObject {
    @Published var state: DetectionState = .idle
    @Published var exposureLocked = false

    let camera = CameraManager()
    private let detector = RedDotDetector()
    private let boardDetector = BoardDetector()

    // Only touched from camera.processingQueue
    private var isArmed = false

    init() {
        camera.onFrame = { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        camera.start()
    }

    func arm() {
        camera.processingQueue.async { self.isArmed = true }
        DispatchQueue.main.async { self.state = .armed }
    }

    func disarm() {
        camera.processingQueue.async { self.isArmed = false }
        DispatchQueue.main.async { self.state = .idle }
    }

    func lockExposure() {
        camera.lockExposure()
        DispatchQueue.main.async { self.exposureLocked = true }
    }

    // Runs on camera.processingQueue
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isArmed else { return }
        let results = detector.detect(in: pixelBuffer)
        guard !results.isEmpty else { return }

        isArmed = false  // disarm before any async work — no second detection

        // Board detection on the same frame — no threading issues, same queue, same frame
        let boardQuad = boardDetector.detect(in: pixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        let dots = results.map { $0.normalizedCenter }

        DispatchQueue.main.async {
            self.state = .result(image: image, normalizedDots: dots, boardQuad: boardQuad)
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch vm.state {
            case .idle:
                IdleView(vm: vm)
            case .armed:
                ArmedView(vm: vm)
            case .result(let image, let dots, let boardQuad):
                ResultView(vm: vm, image: image, normalizedDots: dots, boardQuad: boardQuad)
            }
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Idle view

struct IdleView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()
            VStack {
                HStack {
                    Image(systemName: vm.exposureLocked ? "lock.fill" : "lock.open")
                    Text(vm.exposureLocked ? "Exposure locked" : "Exposure auto")
                }
                .font(.caption)
                .foregroundColor(vm.exposureLocked ? .yellow : .white.opacity(0.6))
                .padding(8)
                .background(Color.black.opacity(0.5))
                .cornerRadius(6)
                .padding(.top, 56)

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        vm.lockExposure()
                    } label: {
                        Label("Lock Exposure", systemImage: "lock")
                            .font(.subheadline.bold())
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.yellow)
                            .cornerRadius(10)
                    }

                    Button {
                        vm.arm()
                    } label: {
                        Text("Ready")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 12)
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                }
                .padding(.bottom, 52)
            }
        }
    }
}

// MARK: - Armed view

struct ArmedView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ZStack {
            CameraPreview(session: vm.camera.session).ignoresSafeArea()
            VStack {
                ScanningBadge()
                    .padding(.top, 56)
                Spacer()
                Button { vm.disarm() } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(10)
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
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(blinking ? 1 : 0.2)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: blinking)
            Text("Scanning for dot…")
                .font(.subheadline.bold())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.65))
        .cornerRadius(8)
        .onAppear { blinking = true }
    }
}

// MARK: - Result view

struct ResultView: View {
    @ObservedObject var vm: AppViewModel
    let image: UIImage
    let normalizedDots: [CGPoint]
    let boardQuad: BoardQuad?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let imgSize = fittedSize(for: image.size, in: geo.size)
                let offsetX = (geo.size.width  - imgSize.width)  / 2
                let offsetY = (geo.size.height - imgSize.height) / 2

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Board boundary outline
                if let quad = boardQuad {
                    BoardOutline(quad: quad, imgSize: imgSize, offset: CGPoint(x: offsetX, y: offsetY))
                }

                // Dot overlays — green if inside board (or no board detected), yellow if outside
                ForEach(normalizedDots.indices, id: \.self) { i in
                    let dot = normalizedDots[i]
                    let insideBoard = boardQuad.map { $0.contains(dot) } ?? true
                    let dotX = offsetX + dot.x * imgSize.width
                    let dotY = offsetY + dot.y * imgSize.height
                    DotOverlay(index: i + 1, color: insideBoard ? .green : .yellow)
                        .position(x: dotX, y: dotY)
                }
            }

            VStack {
                Spacer()
                VStack(spacing: 4) {
                    Text("\(normalizedDots.count) dot\(normalizedDots.count == 1 ? "" : "s") detected")
                        .font(.headline)
                        .foregroundColor(.white)
                    if boardQuad == nil {
                        Text("Board not detected")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    ForEach(normalizedDots.indices, id: \.self) { i in
                        let insideBoard = boardQuad.map { $0.contains(normalizedDots[i]) } ?? true
                        HStack(spacing: 6) {
                            Circle().fill(insideBoard ? Color.green : Color.yellow)
                                .frame(width: 8, height: 8)
                            Text(String(format: "#%d  x: %.3f  y: %.3f", i + 1, normalizedDots[i].x, normalizedDots[i].y))
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .padding(14)
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)

                Button {
                    vm.arm()
                } label: {
                    Text("Ready")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 14)
                        .background(Color.green)
                        .cornerRadius(10)
                }
                .padding(.bottom, 52)
                .padding(.top, 8)
            }
        }
    }

    private func fittedSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

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
            Circle()
                .stroke(color.opacity(0.4), lineWidth: 2)
                .frame(width: pulsing ? 50 : 34, height: pulsing ? 50 : 34)
                .animation(.easeOut(duration: 0.4), value: pulsing)
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 34, height: 34)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
                .offset(x: 14, y: -14)
        }
        .onAppear { pulsing = true }
    }
}
