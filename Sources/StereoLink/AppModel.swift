// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Status: Equatable {
        case off
        case running
        case waiting(String)
        case error(String)
    }

    enum SourceMode: String, CaseIterable, Identifiable {
        /// Apps play to the "StereoLink" output device; the system volume works.
        case virtualDevice
        /// Capture whatever plays on the current output (no driver needed).
        case systemTap

        var id: String { rawValue }
        var title: String {
            switch self {
            case .virtualDevice: "StereoLink output device"
            case .systemTap: "All system audio (no driver)"
            }
        }
    }

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var status: Status = .off
    @Published private(set) var isSystemOutput = false

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); scheduleReconcile() }
    }
    @Published var sourceMode: SourceMode {
        didSet { defaults.set(sourceMode.rawValue, forKey: Keys.source); scheduleReconcile() }
    }
    @Published var leftUID: String? {
        didSet { defaults.set(leftUID, forKey: Keys.left); rememberName(leftUID); scheduleReconcile() }
    }
    @Published var rightUID: String? {
        didSet { defaults.set(rightUID, forKey: Keys.right); rememberName(rightUID); scheduleReconcile() }
    }
    /// Software level for the system-tap source, 0...1, mapped with a squared curve.
    /// The virtual device uses the system volume instead.
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume); applyGain() }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private enum Keys {
        static let enabled = "enabled"
        static let source = "sourceMode"
        static let left = "leftDeviceUID"
        static let right = "rightDeviceUID"
        static let volume = "volume"
        static let names = "knownDeviceNames"
        static let previousOutput = "previousOutputDeviceUID"
    }

    private let defaults = UserDefaults.standard
    private let engine = SplitEngine()
    private var deviceListener: PropertyListener?
    private var defaultOutputListener: PropertyListener?
    private var pendingReconcile: DispatchWorkItem?
    private var isAsleep = false
    private var knownNames: [String: String]

    private init() {
        enabled = defaults.bool(forKey: Keys.enabled)
        sourceMode = defaults.string(forKey: Keys.source).flatMap(SourceMode.init(rawValue:)) ?? .virtualDevice
        leftUID = defaults.string(forKey: Keys.left)
        rightUID = defaults.string(forKey: Keys.right)
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        knownNames = defaults.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
        applyGain()

        refreshDevices()
        deviceListener = PropertyListener(object: AudioSystem.systemObject, selector: kAudioHardwarePropertyDevices) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        defaultOutputListener = PropertyListener(object: AudioSystem.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated { self?.refreshSystemOutput() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        scheduleReconcile(after: 0)
    }

    // MARK: - Derived state

    /// The StereoLink virtual device, if the driver is installed.
    var virtualDevice: AudioDevice? {
        devices.first { $0.uid == AudioSystem.virtualDeviceUID }
    }

    /// Real outputs that can be used as the left or right speakers.
    var speakerDevices: [AudioDevice] {
        devices.filter { $0.uid != AudioSystem.virtualDeviceUID }
    }

    // MARK: - Actions

    func swapSides() {
        (leftUID, rightUID) = (rightUID, leftUID)
    }

    /// Makes StereoLink the system output, remembering the current one to restore later.
    func useAsSystemOutput() {
        guard let virtual = virtualDevice else { return }
        if let current = AudioSystem.defaultOutputDevice(), current != virtual.id,
           let uid = devices.first(where: { $0.id == current })?.uid {
            defaults.set(uid, forKey: Keys.previousOutput)
        }
        do {
            try AudioSystem.setDefaultOutputDevice(virtual.id)
        } catch {
            status = .error(error.localizedDescription)
        }
        refreshSystemOutput()
    }

    /// If StereoLink is the system output, switch back to the output used before it
    /// (or any real device), so quitting never leaves the Mac silent.
    func restoreSystemOutput() {
        guard let virtual = virtualDevice, AudioSystem.defaultOutputDevice() == virtual.id else { return }
        let previousUID = defaults.string(forKey: Keys.previousOutput)
        let target = speakerDevices.first { $0.uid == previousUID }
            ?? speakerDevices.first { $0.uid == leftUID }
            ?? speakerDevices.first
        if let target { try? AudioSystem.setDefaultOutputDevice(target.id) }
        refreshSystemOutput()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("StereoLink: launch-at-login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutdown() {
        pendingReconcile?.cancel()
        engine.stop()
        restoreSystemOutput()
    }

    /// Display name for a UID, including devices that are currently disconnected.
    func displayName(for uid: String) -> String {
        devices.first { $0.uid == uid }?.name ?? knownNames[uid] ?? uid
    }

    func isConnected(_ uid: String) -> Bool {
        devices.contains { $0.uid == uid }
    }

    // MARK: - Device churn

    private func refreshDevices() {
        devices = AudioSystem.outputDevices()
        for device in devices where device.uid == leftUID || device.uid == rightUID {
            rememberName(device.uid)
        }
        refreshSystemOutput()
        // HDMI/DisplayPort devices tend to flap while displays wake; let them settle.
        scheduleReconcile(after: 0.75)
    }

    private func refreshSystemOutput() {
        isSystemOutput = virtualDevice.map { AudioSystem.defaultOutputDevice() == $0.id } ?? false
    }

    private func handleSleep() {
        isAsleep = true
        pendingReconcile?.cancel()
        engine.stop()
        if enabled { status = .waiting("Paused while asleep") }
    }

    private func handleWake() {
        isAsleep = false
        refreshDevices()
        scheduleReconcile(after: 2)
    }

    private func scheduleReconcile(after delay: TimeInterval = 0.25) {
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyGain() {
        engine.gain = sourceMode == .virtualDevice ? 1 : Float(volume * volume)
    }

    /// Brings the engine in line with the desired state. Safe to call any time.
    private func reconcile() {
        applyGain()
        guard enabled else {
            engine.stop()
            status = .off
            return
        }
        guard !isAsleep else { return }

        let source: AudioSource
        switch sourceMode {
        case .systemTap:
            source = .systemTap
        case .virtualDevice:
            guard let virtual = virtualDevice else {
                engine.stop()
                status = .waiting("StereoLink device not installed")
                return
            }
            source = .virtualDevice(virtual)
        }

        guard let leftUID, let rightUID else {
            engine.stop()
            status = .waiting("Choose a left and a right output")
            return
        }
        guard leftUID != rightUID else {
            engine.stop()
            status = .waiting("Left and right must be different devices")
            return
        }
        guard let left = speakerDevices.first(where: { $0.uid == leftUID }),
              let right = speakerDevices.first(where: { $0.uid == rightUID })
        else {
            engine.stop()
            let missing = [leftUID, rightUID].filter { !isConnected($0) }.map(displayName(for:))
            status = .waiting("Waiting for " + missing.joined(separator: " and "))
            return
        }

        // Already running with the same devices (IDs change when a device reappears).
        if engine.isRunning, engine.source == source, engine.left == left, engine.right == right {
            status = .running
            return
        }

        do {
            try engine.start(source: source, left: left, right: right)
            status = .running
        } catch {
            status = .error(error.localizedDescription)
            // Devices are often half-ready right after appearing; try again shortly.
            scheduleReconcile(after: 3)
        }
    }

    private func rememberName(_ uid: String?) {
        guard let uid, let device = devices.first(where: { $0.uid == uid }), knownNames[uid] != device.name else { return }
        knownNames[uid] = device.name
        defaults.set(knownNames, forKey: Keys.names)
    }
}
