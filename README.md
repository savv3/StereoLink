# StereoLink

A menu bar app that turns two displays with built-in speakers into one stereo pair.
The left channel plays on **both** speakers of one display; the right channel plays on both speakers of the other.

Requires macOS 14.4+.

## Sources

- **StereoLink output device (recommended):** an optional driver adds a "StereoLink" output you can pick in System Settings → Sound. The volume keys and the menu bar volume slider work as normal.
- **All system audio:** captures whatever plays on the current output with a Core Audio process tap. No driver is needed, but the volume keys don't control it; use the slider in the StereoLink menu.

## How it works

1. The source is either the StereoLink device's loopback input (the driver applies the system volume before looping audio back) or a **process tap** on all system audio (excluding StereoLink itself), which mutes the original output while it's being read.
2. A **private aggregate device** combines the two displays: the left one drives the clock, the right one is drift-corrected.
3. A real-time **IOProc** copies L to every channel of the left display and R to every channel of the right, applying a smoothed software gain.
4. The app watches for device changes and sleep/wake, and rebuilds the chain when displays disappear and come back.

## Build and run

```bash
scripts/build-app.sh
```

```bash
open build/StereoLink.app
```

To install the StereoLink output device (asks for your password and briefly restarts audio):

```bash
scripts/install-driver.sh
```

To remove it again, run `scripts/install-driver.sh --uninstall`.

Then choose **StereoLink output device** as the source in the menu and click **Use StereoLink as System Output**. When you quit StereoLink, the system output switches back to what it was before.

With the **All system audio** source, macOS asks on the first run for permission to capture system audio. You can manage this later under System Settings → Privacy & Security → Screen & System Audio Recording. Builds are ad-hoc signed, so a rebuild may ask again. Set `SIGN_IDENTITY` to a real identity to avoid that.

You can also open `Package.swift` in Xcode to edit and debug. Run the bundled app from `build/`, though: the audio-capture permission needs the `Info.plist` that the build script adds.

## Code layout

- `Driver/StereoLinkDriver.c`: the virtual output device (AudioServerPlugIn), with loopback, volume and mute
- `Sources/StereoLink/CoreAudioSupport.swift`: device enumeration, property listeners, errors
- `Sources/StereoLink/SplitEngine.swift`: tap, aggregate device and real-time render callback
- `Sources/StereoLink/AppModel.swift`: settings, device churn, sleep/wake, state reconciliation
- `Sources/StereoLink/StereoLinkApp.swift`: menu bar UI

## Not yet

- Per-app sources, a general channel-routing UI, and virtual input devices (these need a HAL plug-in)

## License

StereoLink is free software, released under the [GNU General Public License v3.0 or later](LICENSE).
