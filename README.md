<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="PhoneMirror icon">
</p>

# PhoneMirror

Free, open-source iPhone mirroring and control for Mac, including in the EU.
I built it for myself because other tools didn’t work for me.

**Early preview; USB only, no audio.**

## Features

- Mouse, keyboard, scrolling and text paste.
- Screenshots and silent screen recording.
- Remote rotation, Home and App Switcher.
- Optional iPhone bezels, Always on Top and automatic reconnection.

## Incoming features

- Easier setup and a downloadable app.
- AI-agent access for real-device testing.
- Audio and Wi-Fi support (under investigation).

## Setup

- Apple silicon Mac: **macOS 27**. iPhone: **iOS 27**.
- Install [Xcode 27](https://developer.apple.com/xcode/resources/) and complete its initial setup.
- Connect by USB, [trust your Mac](https://support.apple.com/en-us/109054), and [pair/prepare the phone in Xcode](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
- Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
- Install [Rust 1.95+](https://rustup.rs/).

## Try it

No downloadable app yet. Build locally:

```sh
git clone https://github.com/gdelataillade/phone-mirror.git
cd phone-mirror
./scripts/build.sh
open build/PhoneMirror.app
```

Keep your iPhone unlocked, click **Mirror iPhone**, then click the picture to control it.

[Help & limitations](VALIDATION.md) · [Development](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
