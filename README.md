<p align="center">
  <img src="openxwebcam.svg" width="160" alt="OpenXWebcam logo">
</p>

# OpenXWebcam

Open-source macOS app that turns a Fujifilm camera into a system webcam over USB.
A replacement for Fujifilm's "FUJIFILM X Webcam" app, which no longer works on current macOS.

## How it works

Fujifilm X cameras have no UVC webcam mode, so the video has to be pulled over
USB PTP. macOS's `ptpcamerad` normally holds the camera's USB interface; OpenXWebcam
takes it over and runs the Fuji live-view sequence itself:

```
camera ──USB/PTP──> menu bar app ──> CMIO camera extension ──> Zoom / Meet / OBS
                    (claims the interface, starts live view,
                     decodes the JPEG stream)
```

## Camera support

The live-view protocol is the same across modern X and GFX bodies. The app
adapts at runtime: it reads what the connected camera advertises and only
offers settings the camera actually has.

| Camera | Status |
| --- | --- |
| X-T30 | works, tested |
| X-T1, X-T2, X-T3, X-T4, X-T5, X-Pro2, X-Pro3, X-E3, X-H1, X-H2, X-S10, X100V, X-M5, GFX 50S, GFX 50R, GFX 100, GFX 100S, GFX 100 II | expected to work — same protocol, live view confirmed by the libgphoto2 project |
| X-H2S, X-E4, X-E5, X100VI, X-T30 II, X-S20, older X bodies | should work, unconfirmed |

Have an unconfirmed body? Try it and open an issue with the output of
"Copy Diagnostics" from the settings menu.

## Camera setup

- USB MODE: `X WEBCAM` (MENU → CONNECTION SETTING → USB MODE).
- Auto Power Off: OFF.
- Focus: the camera's own AF settings stay in charge while streaming. Set the
  focus switch to AF-C for hands-free focus; half-pressing the shutter refocuses
  too. The menu also has an autofocus button, and face detection is enabled
  automatically when streaming starts.

## Troubleshooting

- Use a data-capable USB cable. Charge-only cables look like "no camera".
- Set Auto Power Off to OFF, or the camera drops off the bus mid-stream.
- After unplugging mid-session the X-T30 sometimes won't re-enumerate until
  you power it off and on with the cable connected, or replug the cable.
- The USB MOVIE SHOOTING modes don't connect to a computer at all (they're
  for gimbals and remotes). Use `X WEBCAM`.

## License

MIT — see [LICENSE](LICENSE).

---

## X-T3 fork

This fork makes OpenXWebcam usable on the Fujifilm X-T3 and adds back the two
buttons Fujifilm's own X Webcam had. The upstream-worthy changes are proposed
in [#1](https://github.com/antonyshyn/OpenXWebcam/pull/1) (stability) and
[#2](https://github.com/antonyshyn/OpenXWebcam/pull/2) (controls). Measured on an
X-T3 (firmware 4.30), macOS 15.7.9: a 60 minute soak delivered 135,136 frames at
37.5 fps with no freezes and flat memory.

### What was wrong

- **A memory leak** — every USB read leaked about 5 MB, taking the app past 3 GB
  in half a minute until macOS killed it. Being killed mid-stream is what freezes
  the camera. Affects every body.
- **`DeleteObject` blocked.** It advances the live view buffer, so it can't be
  skipped, but the X-T3 often never answers it. Now sent without waiting:
  0.1 fps → ~37 fps.
- **Empty packets and stray fragments** were read as responses and restarted the
  stream about 24 times an hour.
- **Late replies** were taken as the answer to the next command, putting the
  session permanently off by one. Responses are now matched to their transaction.
- **Stale captures and a retry budget that never refilled** turned small glitches
  into a permanent error.

### Restored controls

- **Autofocus** — `0xD208 = 0x9300`, poll `AFStatus` (`0xD209`), release `0x0005`.
- **AE lock** — `0xD208 = 0x9000`, release `0x0002`, state in `0xD212`.
- **Face detection** enabled at stream start (`0xD020`), so autofocus aims at you.
- **Release Camera** hands control back to the body after a crash.

The code pairs come from traces of Fujifilm's X Webcam recorded in libgphoto2's
ptp2 driver. `0xD173`, `0xD174` and `0xD020` work despite being absent from the
X-T3's advertised property list.

### If the camera freezes

Its USB firmware has hung, and nothing on the Mac can reach it — no USB request,
reset or re-enumeration brings it back. Switch the camera **off**, check that the
back screen goes dark, wait five seconds, and switch it on. If the screen stays
lit, the camera is holding itself on for USB: remove the battery instead.

### Building without Xcode

`build.sh` compiles the app with the Command Line Tools and produces an ad-hoc
signed app. It builds the **app only** and drives the upstream-signed camera
extension that the official release installs, so no Developer ID is needed.
Install the official release first, then:

    ./build.sh
    open buildout/OpenXWebcam.app

If `swiftc` fails with *redefinition of module 'SwiftBridging'*, your Command
Line Tools install has a stale duplicate modulemap:

    sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
            /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled

`run-logged.sh` runs the app with its engine log kept on disk.
`tools/soak.swift` is the long-running stability test: it streams through
`CameraManager`, exercises autofocus and AE lock, and reports frame rate, stalls
and every error. See the comment at the top of the file for how to build it.
