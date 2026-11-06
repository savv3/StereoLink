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
            HStack {
                Text("StereoLink").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            statusLine

            Divider()

            Picker("Source", selection: $model.sourceMode) {
                ForEach(AppModel.SourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if model.sourceMode == .virtualDevice {
                systemOutputRow
            }

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

            if model.sourceMode == .systemTap {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
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
    }

    @ViewBuilder
    private var systemOutputRow: some View {
        if model.virtualDevice == nil {
            Text("Install the StereoLink driver to use it as an output device.")
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
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
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
