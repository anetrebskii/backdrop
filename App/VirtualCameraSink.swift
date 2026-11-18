import CoreMediaIO
import CoreVideo
import Foundation

final class VirtualCameraSink {
    static let deviceName = "Backdrop Camera"

    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private(set) var isConnected = false
    private let lock = NSLock()

    func connect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isConnected { return true }
        guard let device = findDevice(), let stream = sinkStream(of: device) else { return false }
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let unmanagedQueue else { return false }
        queue = unmanagedQueue.takeRetainedValue()
        guard CMIODeviceStartStream(device, stream) == noErr else {
            queue = nil
            return false
        }
        deviceID = device
        streamID = stream
        isConnected = true
        return true
    }

    func disconnect() {
        guard isConnected else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
        isConnected = false
    }

    func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        if CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque()) != noErr {
            Unmanaged.passUnretained(sampleBuffer).release()
        }
    }

    private func findDevice() -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return nil }
        return devices.first { name(of: $0) == Self.deviceName }
    }

    private func name(of object: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &name) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &streams) == noErr else { return nil }
        return streams.first { direction(of: $0) == 0 }
    }

    private func direction(of stream: CMIOStreamID) -> UInt32? {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }
}
