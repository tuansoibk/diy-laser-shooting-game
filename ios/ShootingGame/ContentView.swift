import SwiftUI
import AVFoundation

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
    case result(image: UIImage, normalizedDot: CGPoint)
}

// MARK: - ViewModel

class AppViewModel: ObservableObject {
    @Published var state: DetectionState = .idle
    @Published var exposureLocked = false

    let camera = CameraManager()
    private let detector = RedDotDetector()

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

    func lockExposure() {
        camera.lockExposure()
        DispatchQueue.main.async { self.exposureLocked = true }
    }

    // Runs on camera.processingQueue
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isArmed else { return }
        guard let result = detector.detect(in: pixelBuffer) else { return }

        isArmed = false  // disarm before any async work — no second detection

        // Capture the frame as UIImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        // Frames are delivered in portrait orientation (set in CameraManager), no rotation needed
        let image = UIImage(cgImage: cgImage)

        DispatchQueue.main.async {
            self.state = .result(image: image, normalizedDot: result.normalizedCenter)
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
            case .result(let image, let dot):
                ResultView(vm: vm, image: image, normalizedDot: dot)
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
                // Exposure lock indicator
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
    let normalizedDot: CGPoint

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let imgSize = fittedSize(for: image.size, in: geo.size)
                let offsetX = (geo.size.width  - imgSize.width)  / 2
                let offsetY = (geo.size.height - imgSize.height) / 2

                // Captured frame
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Green circle over detected dot
                let dotX = offsetX + normalizedDot.x * imgSize.width
                let dotY = offsetY + normalizedDot.y * imgSize.height
                DotOverlay()
                    .position(x: dotX, y: dotY)
            }

            // Bottom overlay: coords + Ready button
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Text("Dot detected")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(String(format: "x: %.3f  y: %.3f", normalizedDot.x, normalizedDot.y))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
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

struct DotOverlay: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.4), lineWidth: 2)
                .frame(width: pulsing ? 50 : 34, height: pulsing ? 50 : 34)
                .animation(.easeOut(duration: 0.4), value: pulsing)
            Circle()
                .stroke(Color.green, lineWidth: 2)
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        }
        .onAppear { pulsing = true }
    }
}
