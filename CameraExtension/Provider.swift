import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log

let frameWidth: Int32 = 1920
let frameHeight: Int32 = 1080
let frameRate: Int32 = 30
let viewerProperty = CMIOExtensionProperty(rawValue: "4cc_bdvw_glob_0000")
private let log = Logger(subsystem: "com.anetrebskii.backdrop.camera", category: "extension")

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: StreamSource!
    private var sinkStream: StreamSource!
    private var formatDescription: CMFormatDescription!
    private var pool: CVPixelBufferPool!
    private let queue = DispatchQueue(label: "com.anetrebskii.backdrop.camera.frames", qos: .userInteractive)
    private var placeholderTimer: DispatchSourceTimer?
    private var sourceActive = false
    private let viewerLock = NSLock()
    private var hasViewer = false
    private var sinkActive = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrame: UInt64 = 0
    private var sequence: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: UUID(uuidString: "6E2A3C1B-8F4D-4B1E-9C7A-2D5F0B8E1A11")!, legacyDeviceID: nil, source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: frameWidth, height: frameHeight, extensions: nil, formatDescriptionOut: &formatDescription)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frameWidth,
            kCVPixelBufferHeightKey as String: frameHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)

        let duration = CMTime(value: 1, timescale: frameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription, maxFrameDuration: duration, minFrameDuration: duration, validFrameDurations: nil)
        sourceStream = StreamSource(localizedName: "Backdrop Camera.Video", streamID: UUID(uuidString: "6E2A3C1B-8F4D-4B1E-9C7A-2D5F0B8E1A12")!, format: format, direction: .source, owner: self)
        sinkStream = StreamSource(localizedName: "Backdrop Camera.Sink", streamID: UUID(uuidString: "6E2A3C1B-8F4D-4B1E-9C7A-2D5F0B8E1A13")!, format: format, direction: .sink, owner: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel, viewerProperty] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = "Backdrop Camera" }
        if properties.contains(viewerProperty) {
            viewerLock.lock()
            let value = hasViewer ? "1" : "0"
            viewerLock.unlock()
            props.setPropertyState(CMIOExtensionPropertyState(value: value as NSString), forProperty: viewerProperty)
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    private func setViewer(_ value: Bool) {
        viewerLock.lock()
        hasViewer = value
        viewerLock.unlock()
        device.notifyPropertiesChanged([viewerProperty: CMIOExtensionPropertyState<AnyObject>(value: (value ? "1" : "0") as NSString)])
    }

    func startSource() {
        setViewer(true)
        queue.async {
            self.sourceActive = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.sendPlaceholderIfIdle() }
            timer.resume()
            self.placeholderTimer = timer
        }
    }

    func stopSource() {
        setViewer(false)
        queue.async {
            self.sourceActive = false
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
        }
    }

    func startSink(client: CMIOExtensionClient) {
        queue.async {
            self.sinkClient = client
            self.sinkActive = true
            self.consume()
        }
    }

    func stopSink() {
        queue.async {
            self.sinkActive = false
            self.sinkClient = nil
        }
    }

    private func consume() {
        guard sinkActive, let client = sinkClient else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] buffer, seq, _, hasMore, _ in
            guard let self else { return }
            self.queue.async {
                if let buffer {
                    self.lastSinkFrame = DispatchTime.now().uptimeNanoseconds
                    if self.sourceActive {
                        self.sourceStream.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: DispatchTime.now().uptimeNanoseconds)
                    }
                    let output = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: DispatchTime.now().uptimeNanoseconds)
                    self.sinkStream.stream.notifyScheduledOutputChanged(output)
                }
                if buffer != nil && hasMore {
                    self.consume()
                } else {
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consume() }
                }
            }
        }
    }

    private func sendPlaceholderIfIdle() {
        guard sourceActive else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastSinkFrame > 500_000_000 else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x22, CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(frameHeight))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        sequence += 1
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now)
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private weak var owner: DeviceSource?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, direction: CMIOExtensionStream.Direction, owner: DeviceSource) {
        self.format = format
        self.direction = direction
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        var props: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            props.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return props
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: frameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { activeFormatIndex = index }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        currentClient = client
        return true
    }

    func startStream() throws {
        guard let owner else { return }
        if direction == .source {
            owner.startSource()
        } else if let client = currentClient {
            owner.startSink(client: client)
        }
    }

    func stopStream() throws {
        if direction == .source { owner?.stopSource() } else { owner?.stopSink() }
    }

    var currentClient: CMIOExtensionClient?
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "Backdrop Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "Backdrop" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
