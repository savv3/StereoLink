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

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var status: Status = .off

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); scheduleReconcile() }
    }
    @Published var leftUID: String? {
        didSet { defaults.set(leftUID, forKey: Keys.left); rememberName(leftUID); scheduleReconcile() }
    }
    @Published var rightUID: String? {
        didSet { defaults.set(rightUID, forKey: Keys.right); rememberName(rightUID); scheduleReconcile() }
    }
    /// Slider position 0...1; mapped to gain with a squared curve.
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Keys.volume); engine.gain = Self.gain(for: volume) }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private enum Keys {
        static let enabled = "enabled"
        static let left = "leftDeviceUID"
        static let right = "rightDeviceUID"
        static let volume = "volume"
        static let names = "knownDeviceNames"
    }

    private let defaults = UserDefaults.standard
    private let engine = SplitEngine()
    private var deviceListener: PropertyListener?
    private var pendingReconcile: DispatchWorkItem?
    private var isAsleep = false
    private var knownNames: [String: String]

    private init() {
        enabled = defaults.bool(forKey: Keys.enabled)
        leftUID = defaults.string(forKey: Keys.left)
        rightUID = defaults.string(forKey: Keys.right)
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        knownNames = defaults.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
        engine.gain = Self.gain(for: volume)

        refreshDevices()
        deviceListener = PropertyListener(object: AudioSystem.systemObject, selector: kAudioHardwarePropertyDevices) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
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

    // MARK: - Actions

    func swapSides() {
        (leftUID, rightUID) = (rightUID, leftUID)
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
        // HDMI/DisplayPort devices tend to flap while displays wake; let them settle.
        scheduleReconcile(after: 0.75)
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

    /// Brings the engine in line with the desired state. Safe to call any time.
    private func reconcile() {
        guard enabled else {
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
        guard let left = devices.first(where: { $0.uid == leftUID }),
              let right = devices.first(where: { $0.uid == rightUID })
        else {
            engine.stop()
            let missing = [leftUID, rightUID].filter { !isConnected($0) }.map(displayName(for:))
            status = .waiting("Waiting for " + missing.joined(separator: " and "))
            return
        }

        // Already running on the same physical devices (IDs change when a device reappears).
        if engine.isRunning, engine.left?.id == left.id, engine.right?.id == right.id,
           engine.left?.uid == left.uid, engine.right?.uid == right.uid {
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

    private static func gain(for volume: Double) -> Float {
        Float(volume * volume)
    }
}
