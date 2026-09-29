<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="iPhoneMirror icon">
</p>

# iPhoneMirror

Free, open-source iPhone mirroring and control for Mac, including in the EU.
I built it for myself because other tools didn’t work for me.

**Early preview. USB, or Wi-Fi once set up over USB.**

<p align="center">
  <img src="Resources/demo.gif" width="480" alt="iPhoneMirror demo: mirroring and controlling an iPhone from a Mac">
</p>

<p align="center">
  <a href="https://buymeacoffee.com/gdelataillade"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="40" alt="Buy Me a Coffee"></a>
</p>

## Features

- Mouse, keyboard, scrolling and text paste.
- Drag an image from the Mac onto the mirror to paste it into whatever's focused on the iPhone (e.g. an iMessage compose field).
- Screenshots and silent screen recording.
- Audio playback with mute and volume control.
- Remote rotation, Home, App Switcher, Spotlight and Control Center.
- Optional iPhone bezels, Always on Top and automatic reconnection.
- Wi-Fi (experimental): keeps mirroring when you unplug the cable, on the same network. USB is faster: connections use it when it's plugged in, and plugging in during a Wi-Fi session offers to switch (**Reconnect Now**, ⇧⌘R).
- Opt-in local [API and MCP tools](docs/AUTOMATION.md) for AI-agent device testing.

## Setup

- Apple silicon Mac: **macOS 27**. iPhone: **iOS 27**.
- Install [Xcode 27](https://developer.apple.com/xcode/resources/) and open it once so it installs Apple's developer components. You don't need to use Xcode after that.
- Connect by USB and [trust your Mac](https://support.apple.com/en-us/109054).
- Enable [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). If the setting is missing, **iPhone → Setup Check…** can show it.

iPhoneMirror prepares the iPhone itself when it needs to (this uses the internet: Apple signs the developer image for each iPhone), and **Setup Check** shows anything still missing.

To mirror without the cable, turn on the iPhone's Wi-Fi connections once while it's plugged in (**Setup Check → Wi-Fi connections**, or Finder's "Show this iPhone when on Wi-Fi"), and keep both on the same network. Wi-Fi adds some latency and needs a network that lets devices see each other (many guest, hotel and office networks don't). **iPhone → Use Wi-Fi When Unplugged** turns it off.

## Try it

[**Download the latest release**](https://github.com/gdelataillade/phone-mirror/releases/latest), open the DMG, and drag iPhoneMirror to Applications.

The app checks for updates automatically and can check on demand (app menu → Check for Updates…).

Keep your iPhone unlocked, click **Mirror iPhone**, then click the picture to control it.

## AI agents (MCP)

Let Claude Code, Codex or another MCP client see and operate your iPhone to test apps: screenshots, taps, typing, buttons, and launching apps by bundle ID.

1. While mirroring, choose **Automation → Enable Agent Access**.
2. Register the bridge once, from this repository:
   `claude mcp add --scope user iphonemirror -- python3 "$PWD/scripts/iphonemirror_mcp.py"` (or `codex mcp add iphonemirror -- …`)
3. Start a new agent session and ask, e.g. *"Use the iphone tools to open Settings and search for Wi-Fi."*

Details: [MCP bridge](docs/MCP-BRIDGE.md) · [HTTP API](docs/AUTOMATION.md)

[Help & limitations](VALIDATION.md) · [Development](docs/DEVELOPMENT.md) · [MIT license](LICENSE)
