# Contributing to SEAM

Pull requests, bug reports, and device compatibility reports are welcome! SEAM is built to stay lightweight, native, and non-root across platforms.

## Ways to Contribute

- **Windows Host Support:** Help bring SEAM's `SEAM-Wire v1` host experience (edge crossing, cursor decoupling, clipboard sync, and system tray UI) to Windows 11.
- **Android Device Testing:** Test SEAM across different Android 11-15+ devices and OEM ROMs (Samsung One UI, Pixel, Xiaomi HyperOS, OnePlus OxygenOS, TECNO HiOS) and report any `/dev/uhid`, pointer velocity, scroll, or `IClipboard` quirks.
- **macOS UI & Ergonomics:** Refine the Liquid Glass menu-bar popover, drag arrangement, or keyboard shortcut mappings.
- **Transport & Protocol Improvements:** Optimize USB ADB socket throughput, Wi-Fi UDP fast-path reliability, or mDNS auto-discovery.
- **Documentation:** Clarify setup steps, architecture diagrams, or troubleshooting guides.

## Development Setup

### Prerequisites
- **macOS 14+** (Apple Silicon `arm64`) with **Xcode** (for `Swift 6`, `Icon Composer` / `ictool` / `actool`)
- **JDK 17+** (`javac`)
- **Android SDK** (`adb`, `d8`, and `platforms/android-35/android.jar` under `~/Library/Android/sdk`)
- An **Android 11-15+ device** with USB Debugging or Wireless Debugging enabled

### Build & Run Locally

```bash
git clone https://github.com/Ferousco-dev/Seam.git
cd Seam

# Build dist/seam-agent.jar, dist/seam-host, and dist/SEAM.app
make build

# Launch SEAM in the macOS Menu Bar
open dist/SEAM.app
```

### Verification Commands

Before opening a pull request, run `make build` and verify any area your change touches:

```bash
make build          # Full Android DEX + macOS Swift release build
make usb-test       # Verify USB ADB socket auth, RTT, and input streaming
make wifi-test      # Verify Wi-Fi TCP control + 42-byte signed UDP fast-path
make switch-test    # Verify live USB <-> Wi-Fi failover without cursor reset
make device-info    # Check /dev/uhid permissions and display telemetry
make self-test      # Run on-device /dev/uhid mouse & keyboard self-test
```

## Pull Request Process

1. **Fork the repository** and create a focused branch from `main`:
   ```bash
   git checkout -b feat/your-feature-name
   ```
2. **Keep changes clean and scoped:**
   - Avoid committing generated files under `build/` or `dist/`.
   - Match the existing Swift 6 (`macos-host/`) and Java 17 (`android-agent/`) code style.
   - Keep zero-root and non-intrusive phone behavior intact (never suppress Android's on-screen touch keyboard).
3. **Test on real hardware** whenever changing input, scrolling, clipboard, or transport code, and note your macOS version, Android version, and device model in the PR description.
4. **Open a Pull Request** against `main` describing what changed, why, and how you tested it.

## Reporting Issues

When opening an issue, please include:
- macOS version and Mac model
- Android version and phone model
- Transport in use (USB, Wi-Fi, or both)
- Relevant output from `adb shell cat /data/local/tmp/seam-agent.log` if applicable

## License

By contributing to SEAM, you agree that your contributions will be licensed under the [MIT License](LICENSE).
