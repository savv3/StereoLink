# StereoLink

A menu bar app that turns two displays with built-in speakers into one stereo pair.
The left channel plays on **both** speakers of one display; the right channel plays on both speakers of the other.

Requires macOS 14.4+.

## How it works

1. A **process tap** captures all system audio (excluding StereoLink itself) and mutes the original output while it's being read.
2. A **private aggregate device** combines the two displays: the left one drives the clock, the right one is drift-corrected.
3. A real-time **IOProc** copies L to every channel of the left display and R to every channel of the right, applying a smoothed gain.
4. The app watches for device changes and sleep/wake, and rebuilds the chain when displays disappear and come back.

### The StereoLink output device

macOS's volume keys only work on an output that has a volume control, which display speakers and aggregate devices often lack. The driver adds a "StereoLink" output device that has one. It discards any audio sent to it and has no input, so it never records anything. StereoLink reads that device's volume and mute and applies them to the split audio. The volume keys, the menu bar slider and the slider in StereoLink's menu all control the same level.


## Build and run

```bash
scripts/build-app.sh
```

```bash
open build/StereoLink.app
```

On the first run, macOS asks for permission to capture system audio. You can manage this later under System Settings → Privacy & Security → Screen & System Audio Recording. Builds are ad-hoc signed, so a rebuild may ask again. Set `SIGN_IDENTITY` to a real identity to avoid that.

To install the volume driver (asks for your password and briefly restarts audio):

```bash
scripts/install-driver.sh
```

StereoLink is active exactly when the "StereoLink" device is the system output. Pick it in System Settings → Sound, from the menu bar, or with **Use StereoLink as System Output** in the menu. Choosing another output turns splitting off, so macOS's automatic output switching works as you'd expect. When you quit StereoLink, the system output switches back to what it was before. To remove the driver, run `scripts/install-driver.sh --uninstall`.

You can also open `Package.swift` in Xcode to edit and debug. Run the bundled app from `build/`, though: the audio-capture permission needs the `Info.plist` that the build script adds.

## Channel test

Hold **Option** while clicking the menu bar icon to show the channel test. It plays the macOS "Ping" sound on one channel of one display at a time, with everything else silenced, so you can check each speaker. **Test All** goes through every channel in turn.

## Code layout

- `Driver/StereoLinkDriver.c`: the volume device (AudioServerPlugIn): output only, with volume and mute
- `Sources/StereoLink/CoreAudioSupport.swift`: device enumeration, volume, property listeners, errors
- `Sources/StereoLink/SplitEngine.swift`: tap, aggregate device, channel test and real-time render callback
- `Sources/StereoLink/AppModel.swift`: settings, device churn, sleep/wake, volume sync, state reconciliation
- `Sources/StereoLink/StereoLinkApp.swift`: menu bar UI

## Not yet

- Per-app sources and a general channel-routing UI

## License

StereoLink is free software, released under the [GNU General Public License v3.0 or later](LICENSE).
