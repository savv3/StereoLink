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

    /// The channel currently playing the test sound, if any.
    struct TestTarget: Equatable {
        let side: SpeakerSide
        let channel: Int
    }

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var status: Status = .off
    @Published private(set) var isSystemOutput = false
    /// Volume and mute of the StereoLink device, i.e. the system volume when it's the output.
    @Published private(set) var deviceVolume: Double = 1
    @Published private(set) var deviceMuted = false

    @Published var leftUID: String? {
        didSet { defaults.set(leftUID, forKey: Keys.left); rememberName(leftUID); scheduleReconcile() }
    }
    @Published var rightUID: String? {
        didSet { defaults.set(rightUID, forKey: Keys.right); rememberName(rightUID); scheduleReconcile() }
    }
    /// Software level used only when the StereoLink driver isn't installed, 0...1.
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume); applyGain() }
    }
    @Published private(set) var testTarget: TestTarget?
    /// Revealed by Option-clicking the menu bar icon.
    @Published var showChannelTest = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private enum Keys {
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
    private var volumeListeners: [PropertyListener] = []
    private var volumeListenerDevice: AudioObjectID?
    private var pendingReconcile: DispatchWorkItem?
    private var isAsleep = false
    private var knownNames: [String: String]
    private var testWork: DispatchWorkItem?

    private init() {
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

    /// The level the menu slider shows and sets. With the driver installed this is the
    /// StereoLink device's volume, so the slider, volume keys and menu bar all agree.
    var level: Double {
        get { virtualDevice != nil ? deviceVolume : volume }
        set {
            if let virtual = virtualDevice {
                AudioSystem.setVolumeScalar(virtual.id, Float(newValue))
                if deviceMuted && newValue > 0 { AudioSystem.setMuted(virtual.id, false) }
                refreshDeviceVolume()
            } else {
                volume = newValue
            }
        }
    }

    var isMuted: Bool { virtualDevice != nil && deviceMuted }

    func toggleMute() {
        guard let virtual = virtualDevice else { return }
        AudioSystem.setMuted(virtual.id, !deviceMuted)
        refreshDeviceVolume()
    }

    // MARK: - Channel test

    var leftDevice: AudioDevice? { speakerDevices.first { $0.uid == leftUID } }
    var rightDevice: AudioDevice? { speakerDevices.first { $0.uid == rightUID } }
    var canTestChannels: Bool { status == .running }

    /// Plays a short system sound on one channel of one display.
    func testChannel(side: SpeakerSide, channel: Int) {
        runTests([TestTarget(side: side, channel: channel)])
    }

    /// Plays the test sound on every channel in turn, left display first.
    func testAllChannels() {
        var targets: [TestTarget] = []
        for (side, device) in [(SpeakerSide.left, leftDevice), (.right, rightDevice)] {
            for channel in 0..<(device?.outputChannels ?? 0) {
                targets.append(TestTarget(side: side, channel: channel))
            }
        }
        runTests(targets)
    }

    private func runTests(_ targets: [TestTarget]) {
        testWork?.cancel()
        guard canTestChannels, let target = targets.first else {
            testTarget = nil
            return
        }
        engine.playTest(side: target.side, channel: target.channel)
        testTarget = target
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runTests(Array(targets.dropFirst())) }
        }
        testWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(engine.testDuration, 0.5) + 0.2, execute: work)
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
        testWork?.cancel()
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
        watchDeviceVolume()
        // HDMI/DisplayPort devices tend to flap while displays wake; let them settle.
        scheduleReconcile(after: 0.75)
    }

    /// StereoLink is active exactly when its device is the system output, so choosing
    /// it in Sound settings (or macOS picking it automatically) turns splitting on.
    private func refreshSystemOutput() {
        let selected = virtualDevice.map { AudioSystem.defaultOutputDevice() == $0.id } ?? false
        if selected != isSystemOutput {
            isSystemOutput = selected
            scheduleReconcile(after: 0.1)
        }
    }

    private func watchDeviceVolume() {
        let id = virtualDevice?.id
        guard id != volumeListenerDevice else { return }
        volumeListenerDevice = id
        volumeListeners = []
        guard let id else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            volumeListeners.append(PropertyListener(object: id, selector: selector, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDeviceVolume() }
            })
        }
        refreshDeviceVolume()
    }

    func refreshDeviceVolume() {
        guard let virtual = virtualDevice else { return }
        deviceVolume = Double(AudioSystem.volumeScalar(virtual.id) ?? 1)
        deviceMuted = AudioSystem.isMuted(virtual.id)
        applyGain()
    }

    private func handleSleep() {
        isAsleep = true
        pendingReconcile?.cancel()
        engine.stop()
        if isSystemOutput { status = .waiting("Paused while asleep") }
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

    /// The tap captures audio before any device volume, so we apply the StereoLink
    /// device's volume ourselves, with the same curve the driver reports.
    private func applyGain() {
        let gain: Float
        if virtualDevice != nil {
            gain = deviceMuted ? 0 : Float(deviceVolume * deviceVolume)
        } else {
            gain = Float(volume * volume)
        }
        engine.gain = gain
    }

    /// Brings the engine in line with the desired state. Safe to call any time.
    private func reconcile() {
        applyGain()
        guard isSystemOutput else {
            engine.stop()
            status = .off
            return
        }
        guard !isAsleep else { return }

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
        if engine.isRunning, engine.left == left, engine.right == right {
            status = .running
            return
        }

        do {
            try engine.start(left: left, right: right)
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
