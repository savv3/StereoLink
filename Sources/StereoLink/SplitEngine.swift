// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation

/// Where the stereo signal comes from.
enum AudioSource: Equatable {
    /// All system audio, captured with a process tap. Needs no driver.
    case systemTap
    /// The StereoLink virtual output device's loopback input. The system volume
    /// control applies, because the driver scales audio before it loops back.
    case virtualDevice(AudioDevice)
}

/// Output buffer roles in the render context.
enum OutputSide {
    static let left: UInt8 = 0
    static let right: UInt8 = 1
    /// The virtual device's own output: must stay silent, or we'd feed back into it.
    static let silent: UInt8 = 2
}

/// State shared with the real-time IOProc. Allocated once per run; never touched by ARC.
struct RenderContext {
    var targetGain: Float
    var currentGain: Float
    /// Index of the first input buffer that carries the source signal.
    var inputOffset: Int
    /// Role of each output buffer of the aggregate (see `OutputSide`).
    var outputSides: UnsafeMutablePointer<UInt8>
    var outputSideCount: Int
}

/// Plays the left channel of a stereo source on every speaker of one device and
/// the right channel on every speaker of another.
///
/// Topology: a private aggregate device with the left device as clock and the
/// right device drift-corrected. The source is either a system tap (which mutes
/// the original output while read) or the StereoLink virtual device, added as
/// the first, drift-corrected sub-device.
final class SplitEngine {
    private(set) var isRunning = false
    private(set) var source: AudioSource?
    private(set) var left: AudioDevice?
    private(set) var right: AudioDevice?

    var gain: Float = 1 {
        didSet { context?.pointee.targetGain = gain }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: UnsafeMutablePointer<RenderContext>?

    deinit { stop() }

    func start(source: AudioSource, left: AudioDevice, right: AudioDevice) throws {
        stop()
        do {
            if source == .systemTap { try createTap() }
            try createAggregate(source: source, left: left, right: right)
            try buildContext(source: source, left: left)
            try startIO()
            self.source = source
            self.left = left
            self.right = right
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let context {
            context.pointee.outputSides.deallocate()
            context.deinitialize(count: 1)
            context.deallocate()
        }
        context = nil
        source = nil
        left = nil
        right = nil
        isRunning = false
    }

    // MARK: - Setup

    private func createTap() throws {
        // Exclude ourselves, or the tap would capture our own output and feed back.
        let me = try AudioSystem.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        description.name = "StereoLink System Tap"
        description.isPrivate = true
        // Silence the original output only while we are actually reading the tap,
        // so audio falls back to normal if StereoLink stops or crashes.
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateProcessTap(description, &id), "Creating system audio tap")
        tapID = id
        tapUID = description.uuid.uuidString
    }

    private func createAggregate(source: AudioSource, left: AudioDevice, right: AudioDevice) throws {
        var subDevices: [[String: Any]] = []
        if case .virtualDevice(let device) = source {
            subDevices.append([kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: true])
        }
        subDevices.append([kAudioSubDeviceUIDKey: left.uid])
        subDevices.append([kAudioSubDeviceUIDKey: right.uid, kAudioSubDeviceDriftCompensationKey: true])

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "StereoLink Engine",
            kAudioAggregateDeviceUIDKey: AudioSystem.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: left.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if source == .systemTap {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ]
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creating aggregate device")
        aggregateID = id
    }

    private func buildContext(source: AudioSource, left: AudioDevice) throws {
        // The aggregate can take a moment to publish its stream layout after creation.
        var outputs: [Int] = []
        var inputs: [Int] = []
        for _ in 0..<40 {
            outputs = AudioSystem.streamChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeOutput)
            inputs = AudioSystem.streamChannelCounts(aggregateID, scope: kAudioObjectPropertyScopeInput)
            if !outputs.isEmpty && !inputs.isEmpty { break }
            usleep(25_000)
        }
        guard !outputs.isEmpty else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), operation: "Aggregate has no outputs")
        }
        guard !inputs.isEmpty else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), operation: "Aggregate has no source input")
        }

        // Output streams follow sub-device order: [virtual device], left, right.
        var silentCount = 0
        if case .virtualDevice(let device) = source {
            silentCount = AudioSystem.streamChannelCounts(device.id, scope: kAudioObjectPropertyScopeOutput).count
        }
        let leftEnd = silentCount + AudioSystem.streamChannelCounts(left.id, scope: kAudioObjectPropertyScopeOutput).count
        let sides = UnsafeMutablePointer<UInt8>.allocate(capacity: outputs.count)
        for i in 0..<outputs.count {
            sides[i] = i < silentCount ? OutputSide.silent : (i < leftEnd ? OutputSide.left : OutputSide.right)
        }

        let offset: Int
        switch source {
        case .virtualDevice:
            // The virtual device is the first sub-device, so its input comes first.
            offset = 0
        case .systemTap:
            // Tap streams come after any sub-device input streams; the tap is stereo,
            // so walk back from the end until we've covered two channels.
            var index = inputs.count
            var channels = 0
            while index > 0 && channels < 2 {
                index -= 1
                channels += inputs[index]
            }
            offset = index
        }

        let context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        context.initialize(to: RenderContext(
            targetGain: gain,
            currentGain: gain,
            inputOffset: offset,
            outputSides: sides,
            outputSideCount: outputs.count
        ))
        self.context = context
    }

    private func startIO() throws {
        var proc: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcID(aggregateID, stereoLinkIOProc, context, &proc), "Creating IO callback")
        procID = proc
        try caCheck(AudioDeviceStart(aggregateID, proc), "Starting audio")
    }
}


// MARK: - Real-time render

/// Runs on Core Audio's real-time thread: no allocation, locks or Objective-C calls.
private func stereoLinkIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context = clientData?.assumingMemoryBound(to: RenderContext.self) else { return noErr }
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let output = UnsafeMutableAudioBufferListPointer(outputData)

    // Locate left/right source samples in the tap's buffer(s).
    var leftSrc: UnsafePointer<Float>?
    var rightSrc: UnsafePointer<Float>?
    var srcStride = 1
    var srcFrames = 0
    let offset = context.pointee.inputOffset
    if offset < input.count, let data = input[offset].mData {
        let first = input[offset]
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = Int(first.mNumberChannels)
        if channels >= 2 {
            leftSrc = UnsafePointer(samples)
            rightSrc = UnsafePointer(samples + 1)
            srcStride = channels
            srcFrames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        } else {
            leftSrc = UnsafePointer(samples)
            rightSrc = leftSrc
            srcFrames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            if offset + 1 < input.count, let second = input[offset + 1].mData {
                rightSrc = UnsafePointer(second.assumingMemoryBound(to: Float.self))
            }
        }
    }

    let startGain = context.pointee.currentGain
    let targetGain = context.pointee.targetGain
    let sideCount = context.pointee.outputSideCount

    for index in 0..<output.count {
        let buffer = output[index]
        guard let data = buffer.mData else { continue }
        let out = data.assumingMemoryBound(to: Float.self)
        let channels = max(Int(buffer.mNumberChannels), 1)
        let outFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels

        let side = index < sideCount ? context.pointee.outputSides[index] : OutputSide.silent
        let source: UnsafePointer<Float>? = switch side {
        case OutputSide.left: leftSrc
        case OutputSide.right: rightSrc
        default: nil
        }
        guard let src = source else {
            memset(data, 0, Int(buffer.mDataByteSize))
            continue
        }

        let frames = min(srcFrames, outFrames)
        // Linear ramp from the previous gain to avoid zipper noise on volume changes.
        var g = startGain
        let step = frames > 0 ? (targetGain - startGain) / Float(frames) : 0
        for frame in 0..<frames {
            let sample = src[frame * srcStride] * g
            g += step
            let base = frame * channels
            for channel in 0..<channels {
                out[base + channel] = sample
            }
        }
        if outFrames > frames {
            memset(out + frames * channels, 0, (outFrames - frames) * channels * MemoryLayout<Float>.size)
        }
    }

    context.pointee.currentGain = targetGain
    return noErr
}
