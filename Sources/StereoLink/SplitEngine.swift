// SPDX-License-Identifier: GPL-3.0-or-later

import AudioToolbox
import CoreAudio
import Foundation

enum SpeakerSide: UInt8 {
    case left = 0
    case right = 1
}

/// State shared with the real-time IOProc. Allocated once per run; never touched by ARC.
struct RenderContext {
    var targetGain: Float
    var currentGain: Float
    /// Index of the first input buffer that belongs to the process tap.
    var inputOffset: Int
    /// For each output buffer of the aggregate: which display it belongs to…
    var outputSides: UnsafeMutablePointer<UInt8>
    /// …and the 0-based number, within that display, of its first channel.
    var outputChannelBase: UnsafeMutablePointer<Int>
    var outputCount: Int

    // Channel test. The main thread only ever writes `testRequest`, a single
    // word: serial << 16 | side << 8 | channel. Everything else is IO-thread state.
    var testRequest: UInt64 = 0
    var testSerialSeen: UInt64 = 0
    var testActive = false
    var testSide: UInt8 = 0
    var testChannel: Int = 0
    var testPosition: Int = 0
    var testSamples: UnsafeMutablePointer<Float>?
    var testLength: Int = 0
}

/// Captures system audio with a process tap and plays the left channel on every
/// speaker of one device and the right channel on every speaker of another.
///
/// Topology: private aggregate device = [left device (clock), right device (drift
/// corrected)] + [system tap]. The tap mutes the original output while we read it.
final class SplitEngine {
    private(set) var isRunning = false
    private(set) var left: AudioDevice?
    private(set) var right: AudioDevice?
    /// Length of the channel-test sound, in seconds.
    private(set) var testDuration: TimeInterval = 0

    var gain: Float = 1 {
        didSet { context?.pointee.targetGain = gain }
    }

    /// Short system sound used to identify each speaker.
    static let testSoundURL = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: UnsafeMutablePointer<RenderContext>?
    private var testSerial: UInt64 = 0

    deinit { stop() }

    func start(left: AudioDevice, right: AudioDevice) throws {
        stop()
        do {
            try createTap()
            try createAggregate(left: left, right: right)
            try buildContext(left: left, right: right)
            try startIO()
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
            context.pointee.outputChannelBase.deallocate()
            context.pointee.testSamples?.deallocate()
            context.deinitialize(count: 1)
            context.deallocate()
        }
        context = nil
        left = nil
        right = nil
        testDuration = 0
        isRunning = false
    }

    /// Plays the test sound on one channel of one display, silencing everything else.
    func playTest(side: SpeakerSide, channel: Int) {
        guard let context, context.pointee.testSamples != nil else { return }
        testSerial += 1
        context.pointee.testRequest = testSerial << 16 | UInt64(side.rawValue) << 8 | UInt64(channel & 0xFF)
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

    private func createAggregate(left: AudioDevice, right: AudioDevice) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "StereoLink Engine",
            kAudioAggregateDeviceUIDKey: AudioSystem.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: left.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: left.uid],
                [kAudioSubDeviceUIDKey: right.uid, kAudioSubDeviceDriftCompensationKey: true],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try caCheck(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creating aggregate device")
        aggregateID = id
    }

    private func buildContext(left: AudioDevice, right: AudioDevice) throws {
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
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnspecifiedError), operation: "Aggregate has no tap input")
        }

        // Output streams are the sub-devices' streams in order: left's first, then right's.
        let leftStreamCount = AudioSystem.streamChannelCounts(left.id, scope: kAudioObjectPropertyScopeOutput).count
        let sides = UnsafeMutablePointer<UInt8>.allocate(capacity: outputs.count)
        let bases = UnsafeMutablePointer<Int>.allocate(capacity: outputs.count)
        var channelInDevice = 0
        for i in 0..<outputs.count {
            if i == leftStreamCount { channelInDevice = 0 }
            sides[i] = i < leftStreamCount ? SpeakerSide.left.rawValue : SpeakerSide.right.rawValue
            bases[i] = channelInDevice
            channelInDevice += outputs[i]
        }

        // Tap streams come after any sub-device input streams; the tap is stereo,
        // so walk back from the end until we've covered two channels.
        var offset = inputs.count
        var channels = 0
        while offset > 0 && channels < 2 {
            offset -= 1
            channels += inputs[offset]
        }

        var context = RenderContext(
            targetGain: gain,
            currentGain: gain,
            inputOffset: offset,
            outputSides: sides,
            outputChannelBase: bases,
            outputCount: outputs.count
        )

        let sampleRate = AudioSystem.nominalSampleRate(aggregateID) ?? 48_000
        if let sound = Self.loadMono(url: Self.testSoundURL, sampleRate: sampleRate), !sound.isEmpty {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: sound.count)
            samples.initialize(from: sound, count: sound.count)
            context.testSamples = samples
            context.testLength = sound.count
            testDuration = Double(sound.count) / sampleRate
        }

        let pointer = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        pointer.initialize(to: context)
        self.context = pointer
    }

    private func startIO() throws {
        var proc: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcID(aggregateID, stereoLinkIOProc, context, &proc), "Creating IO callback")
        procID = proc
        try caCheck(AudioDeviceStart(aggregateID, proc), "Starting audio")
    }

    /// Decodes an audio file to mono Float32 at the given sample rate.
    private static func loadMono(url: URL, sampleRate: Double) -> [Float]? {
        var fileRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &fileRef) == noErr, let file = fileRef else { return nil }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        guard ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &format
        ) == noErr else { return nil }

        var result: [Float] = []
        var chunk = [Float](repeating: 0, count: 4096)
        while true {
            var frames = UInt32(chunk.count)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr else { return nil }
            if frames == 0 { break }
            result.append(contentsOf: chunk.prefix(Int(frames)))
        }
        return result
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

    // Pick up a new channel-test request.
    let request = context.pointee.testRequest
    let serial = request >> 16
    if serial != context.pointee.testSerialSeen {
        context.pointee.testSerialSeen = serial
        context.pointee.testActive = context.pointee.testSamples != nil
        context.pointee.testSide = UInt8((request >> 8) & 0xFF)
        context.pointee.testChannel = Int(request & 0xFF)
        context.pointee.testPosition = 0
    }

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
    let count = context.pointee.outputCount
    let testing = context.pointee.testActive
    var cycleFrames = 0

    for index in 0..<output.count {
        let buffer = output[index]
        guard let data = buffer.mData else { continue }
        let out = data.assumingMemoryBound(to: Float.self)
        let channels = max(Int(buffer.mNumberChannels), 1)
        let outFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        cycleFrames = max(cycleFrames, outFrames)
        let side = index < count ? context.pointee.outputSides[index] : SpeakerSide.right.rawValue

        if testing {
            // Only the channel under test plays, everything else is silent.
            memset(data, 0, Int(buffer.mDataByteSize))
            guard side == context.pointee.testSide, let test = context.pointee.testSamples else { continue }
            let channel = context.pointee.testChannel - (index < count ? context.pointee.outputChannelBase[index] : 0)
            guard channel >= 0 && channel < channels else { continue }
            let position = context.pointee.testPosition
            let frames = min(outFrames, context.pointee.testLength - position)
            for frame in 0..<max(frames, 0) {
                out[frame * channels + channel] = test[position + frame] * targetGain
            }
            continue
        }

        guard let src = side == SpeakerSide.left.rawValue ? leftSrc : rightSrc else {
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

    if testing {
        context.pointee.testPosition += cycleFrames
        if context.pointee.testPosition >= context.pointee.testLength {
            context.pointee.testActive = false
        }
    }
    context.pointee.currentGain = targetGain
    return noErr
}
