// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation

/// Error wrapping a non-zero OSStatus from Core Audio.
struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? { "\(operation) failed (\(Self.describe(status)))" }

    /// Core Audio errors are usually four-char codes, e.g. 'who?' or '!dev'.
    static func describe(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return "\(status)"
    }
}

func caCheck(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation()) }
}

func caAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannels: Int
}

enum AudioSystem {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Prefix for the UID of the private aggregate device StereoLink creates.
    static let aggregateUIDPrefix = "com.stereolink.aggregate."

    /// UID published by the StereoLink virtual device driver (Driver/StereoLinkDriver.c).
    static let virtualDeviceUID = "StereoLink_UID"

    static func deviceIDs() -> [AudioObjectID] {
        var addr = caAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// All devices with at least one output channel, excluding StereoLink's own aggregate.
    static func outputDevices() -> [AudioDevice] {
        deviceIDs().compactMap { id -> AudioDevice? in
            let channels = streamChannelCounts(id, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
            guard channels > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(aggregateUIDPrefix)
            else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return AudioDevice(id: id, uid: uid, name: name, outputChannels: channels)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var addr = caAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) throws {
        var addr = caAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        try caCheck(
            AudioObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id),
            "Changing the system output"
        )
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = caAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Channel count of each stream (one entry per AudioBuffer the device's IOProc sees).
    static func streamChannelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = caAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The Core Audio process object for a PID (needed to exclude ourselves from the tap).
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = caAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try caCheck(
            AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "Looking up StereoLink's audio process"
        )
        guard object != kAudioObjectUnknown else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareBadObjectError), operation: "Looking up StereoLink's audio process")
        }
        return object
    }
}

/// Registers a Core Audio property listener for its lifetime.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) {
        self.object = object
        self.address = caAddress(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
