// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@main
struct StereoLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.status == .running ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("StereoLink").font(.headline)
            statusLine

            Divider()

            systemOutputRow

            Divider()

            devicePicker("Left", selection: $model.leftUID)
            devicePicker("Right", selection: $model.rightUID)
            HStack {
                Spacer()
                Button {
                    model.swapSides()
                } label: {
                    Label("Swap Left and Right", systemImage: "arrow.left.arrow.right")
                }
                .disabled(model.leftUID == nil && model.rightUID == nil)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.virtualDevice == nil)
                .help("Mute")
                Slider(value: $model.level, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            if model.showChannelTest {
                Divider()
                channelTest
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            HStack {
                Spacer()
                Button("Quit StereoLink") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { menuOpened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            menuOpened()
        }
    }

    private func menuOpened() {
        model.refreshDeviceVolume()
        model.showChannelTest = NSEvent.modifierFlags.contains(.option)
    }

    @ViewBuilder
    private var channelTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Channel Test").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Test All") { model.testAllChannels() }
                    .disabled(!model.canTestChannels)
            }
            if model.canTestChannels {
                channelRow("Left", side: .left, device: model.leftDevice)
                channelRow("Right", side: .right, device: model.rightDevice)
            } else {
                Text("Choose StereoLink as the sound output to test the speakers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func channelRow(_ title: String, side: SpeakerSide, device: AudioDevice?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 40, alignment: .leading)
                .foregroundStyle(.secondary)
            ForEach(0..<(device?.outputChannels ?? 0), id: \.self) { channel in
                let playing = model.testTarget == AppModel.TestTarget(side: side, channel: channel)
                Button {
                    model.testChannel(side: side, channel: channel)
                } label: {
                    Label(channelLabel(channel, of: device?.outputChannels ?? 0),
                          systemImage: playing ? "speaker.wave.2.fill" : "speaker.fill")
                }
                .buttonStyle(.bordered)
                .tint(playing ? .accentColor : nil)
            }
            Spacer(minLength: 0)
        }
    }

    private func channelLabel(_ channel: Int, of count: Int) -> String {
        guard count == 2 else { return "\(channel + 1)" }
        return channel == 0 ? "1 L" : "2 R"
    }

    @ViewBuilder
    private var systemOutputRow: some View {
        if model.virtualDevice == nil {
            Text("Install the StereoLink driver, then choose it as the sound output.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isSystemOutput {
            Label("StereoLink is the system output. Volume keys control it.", systemImage: "speaker.wave.2.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Spacer()
                Button("Use StereoLink as System Output") { model.useAsSystemOutput() }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .off:
            Label("Inactive. Choose StereoLink as the sound output.", systemImage: "circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .running:
            Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting(let message):
            Label(message, systemImage: "hourglass").foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func devicePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(model.speakerDevices) { device in
                Text("\(device.name) (\(device.outputChannels) ch)").tag(Optional(device.uid))
            }
            // Keep a remembered but disconnected device selectable so the choice survives unplugging.
            if let uid = selection.wrappedValue, !model.speakerDevices.contains(where: { $0.uid == uid }) {
                Text("\(model.displayName(for: uid)) (disconnected)").tag(Optional(uid))
            }
        }
    }
}
