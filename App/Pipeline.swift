import AppKit
import AVFoundation
import CoreImage
import Metal
import Vision

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case blur, image
    var id: Self { self }
    var title: String { self == .blur ? "Blur" : "Image" }
}

enum SegmentationQuality: String, CaseIterable, Identifiable {
    case fast, balanced, accurate
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var level: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: .fast
        case .balanced: .balanced
        case .accurate: .accurate
        }
    }
}

enum CameraState: Equatable {
    case starting, running, noCamera, denied
}

private struct RenderSettings {
    var effectOn = true
    var style: BackgroundStyle = .blur
    var quality: SegmentationQuality = .accurate
    var softness = 1.0
    var blurStrength = 0.5
    var background: CIImage?
}

final class Pipeline: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let outputSize = CGSize(width: 1920, height: 1080)

    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraID = "" { didSet { if cameraID != oldValue { configureSession() } } }
    @Published var effectOn: Bool { didSet { defaults.set(effectOn, forKey: "effectOn"); pushSettings() } }
    @Published var style: BackgroundStyle { didSet { defaults.set(style.rawValue, forKey: "style"); pushSettings() } }
    @Published var quality: SegmentationQuality { didSet { defaults.set(quality.rawValue, forKey: "quality"); pushSettings() } }
    @Published var softness: Double { didSet { defaults.set(softness, forKey: "softness"); pushSettings() } }
    @Published var blurStrength: Double { didSet { defaults.set(blurStrength, forKey: "blurStrength"); pushSettings() } }
    @Published var backgroundURL: URL? { didSet { defaults.set(backgroundURL?.path, forKey: "background"); loadBackground() } }
    @Published var preview: CGImage?
    @Published var stats = ""
    @Published var cameraState: CameraState = .starting
    @Published var virtualCameraConnected = false

    private let defaults = UserDefaults.standard
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.anetrebskii.backdrop.video", qos: .userInteractive)
    private let ciContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
    private let request = VNGeneratePersonSegmentationRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let sink = VirtualCameraSink()
    private let lock = NSLock()
    private var settings = RenderSettings()
    private var backgroundImage: CIImage?
    private var outputPool: CVPixelBufferPool?
    private var reconnectTimer: Timer?
    private var fixtureTimer: DispatchSourceTimer?
    private var started = false
    private var frames = 0
    private var segmentationTime = 0.0
    private var statsStart = CACurrentMediaTime()
    private(set) var lastOutput: CVPixelBuffer?

    override init() {
        effectOn = defaults.object(forKey: "effectOn") as? Bool ?? true
        style = BackgroundStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .blur
        quality = SegmentationQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .accurate
        softness = defaults.object(forKey: "softness") as? Double ?? 1.0
        blurStrength = defaults.object(forKey: "blurStrength") as? Double ?? 0.5
        backgroundURL = defaults.string(forKey: "background").map { URL(fileURLWithPath: $0) }
        super.init()
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(Self.outputSize.width),
            kCVPixelBufferHeightKey as String: Int(Self.outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &outputPool)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        loadBackground()
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshCameras() }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshCameras() }
    }

    func start() {
        guard !started else { return }
        started = true
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.connectVirtualCamera() }
        connectVirtualCamera()
        if let fixture = ProcessInfo.processInfo.environment["BACKDROP_FIXTURE"] {
            startFixture(path: fixture)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.refreshCameras()
                } else {
                    self.cameraState = .denied
                }
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    private let sinkQueue = DispatchQueue(label: "com.anetrebskii.backdrop.sink")

    func connectVirtualCamera() {
        sinkQueue.async {
            let connected = self.sink.connect()
            DispatchQueue.main.async {
                if self.virtualCameraConnected != connected { self.virtualCameraConnected = connected }
            }
        }
    }

    func refreshCameras() {
        guard fixtureTimer == nil else { return }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
        cameras = discovery.devices.filter { $0.localizedName != VirtualCameraSink.deviceName && !$0.localizedName.localizedCaseInsensitiveContains("virtual") }
        if !cameras.contains(where: { $0.uniqueID == cameraID }) {
            let saved = defaults.string(forKey: "camera")
            cameraID = (cameras.first { $0.uniqueID == saved } ?? cameras.first { $0.deviceType == .continuityCamera } ?? cameras.first { $0.localizedName.hasPrefix("iPhone") } ?? cameras.first)?.uniqueID ?? ""
        }
        if cameras.isEmpty {
            cameraState = .noCamera
            preview = nil
        }
    }

    private func startFixture(path: String) {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            cameraState = .noCamera
            return
        }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return }
        ciContext.render(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)), to: buffer)
        cameraState = .running
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in
            self?.process(buffer, time: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        fixtureTimer = timer
    }

    private func configureSession() {
        defaults.set(cameraID, forKey: "camera")
        let device = cameras.first { $0.uniqueID == cameraID }
        cameraState = device == nil ? .noCamera : .starting
        videoQueue.async {
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if self.session.outputs.isEmpty, self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            var ok = false
            if let device, let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                ok = true
            }
            self.session.commitConfiguration()
            if ok, !self.session.isRunning { self.session.startRunning() }
            if !ok {
                DispatchQueue.main.async { self.cameraState = .noCamera }
            }
        }
    }

    private func loadBackground() {
        var image: CIImage?
        if let url = backgroundURL, let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            let rect = CGRect(origin: .zero, size: Self.outputSize)
            image = source.transformed(by: Self.fillTransform(from: source.extent)).cropped(to: rect)
        }
        backgroundImage = image
        pushSettings()
    }

    private func pushSettings() {
        let next = RenderSettings(effectOn: effectOn, style: style, quality: quality, softness: softness, blurStrength: blurStrength, background: backgroundImage)
        lock.lock()
        settings = next
        lock.unlock()
    }

    private static func fillTransform(from extent: CGRect) -> CGAffineTransform {
        let scale = max(outputSize.width / extent.width, outputSize.height / extent.height)
        let tx = (outputSize.width - extent.width * scale) / 2 - extent.minX * scale
        let ty = (outputSize.height - extent.height * scale) / 2 - extent.minY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func process(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let outputPool else { return }
        lock.lock()
        let current = settings
        lock.unlock()

        let rect = CGRect(origin: .zero, size: Self.outputSize)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let fill = Self.fillTransform(from: source.extent)
        let frame = source.transformed(by: fill).cropped(to: rect)
        var result = frame

        if current.effectOn {
            request.qualityLevel = current.quality.level
            let began = CACurrentMediaTime()
            try? sequenceHandler.perform([request], on: pixelBuffer)
            segmentationTime += CACurrentMediaTime() - began
            if let maskBuffer = request.results?.first?.pixelBuffer {
                let rawMask = CIImage(cvPixelBuffer: maskBuffer)
                let toSource = CGAffineTransform(scaleX: source.extent.width / rawMask.extent.width, y: source.extent.height / rawMask.extent.height)
                var mask = rawMask.transformed(by: toSource.concatenating(fill)).cropped(to: rect)
                let backgroundMask = mask.applyingFilter("CIColorInvert")
                mask = mask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.45, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.45, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.45, w: 0),
                    "inputBiasVector": CIVector(x: -0.3, y: -0.3, z: -0.3, w: 0),
                ]).applyingFilter("CIColorClamp")
                if current.softness > 0 {
                    mask = mask.clampedToExtent().applyingGaussianBlur(sigma: current.softness).cropped(to: rect)
                }
                let background: CIImage
                if current.style == .image, let image = current.background {
                    background = image
                } else {
                    let sigma = 8 + current.blurStrength * 40
                    background = frame
                        .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.clear.cropped(to: rect), kCIInputMaskImageKey: backgroundMask])
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: sigma)
                        .unpremultiplyingAlpha()
                        .settingAlphaOne(in: rect)
                        .cropped(to: rect)
                }
                result = frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
            }
        }

        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &outputBuffer) == kCVReturnSuccess, let outputBuffer else { return }
        ciContext.render(result, to: outputBuffer, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        sink.send(outputBuffer, presentationTime: time)
        lastOutput = outputBuffer

        frames += 1
        if frames % 2 == 0 {
            let small = CIImage(cvPixelBuffer: outputBuffer).transformed(by: CGAffineTransform(scaleX: 1.0 / 3, y: 1.0 / 3))
            if let image = ciContext.createCGImage(small, from: small.extent) {
                DispatchQueue.main.async {
                    self.preview = image
                    if self.cameraState != .running { self.cameraState = .running }
                }
            }
        }
        let elapsed = CACurrentMediaTime() - statsStart
        if elapsed >= 1 {
            let fps = Double(frames) / elapsed
            let ms = current.effectOn ? segmentationTime / Double(frames) * 1000 : 0
            frames = 0
            segmentationTime = 0
            statsStart = CACurrentMediaTime()
            let text = current.effectOn ? String(format: "%.0f fps, %.0f ms", fps, ms) : String(format: "%.0f fps", fps)
            DispatchQueue.main.async { self.stats = text }
        }
    }

    func stopForSnapshot(state: CameraState) {
        fixtureTimer?.cancel()
        videoQueue.sync {}
        DispatchQueue.main.async {
            self.preview = nil
            self.stats = ""
            self.cameraState = state
        }
    }

    func snapshotOutput(to url: URL) {
        videoQueue.sync {
            guard let lastOutput else { return }
            let image = CIImage(cvPixelBuffer: lastOutput)
            try? ciContext.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
