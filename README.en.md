# MacPolish

[中文](./README.md)

MacPolish is a native macOS cleaning utility for wiping down a MacBook while protecting both the display and keyboard input. It combines screen cleaning and keyboard cleaning into one app, with dedicated modes for the whole Mac, the screen only, or the keyboard only.

## Features

- Native macOS `SwiftUI + AppKit` app
- Three cleaning modes: `Whole Mac`, `Screen Only`, and `Keyboard Only`
- `Whole Mac` mode blacks out the display and blocks local keyboard input
- `Screen Only` mode blacks out the display while leaving the keyboard usable
- `Keyboard Only` mode keeps the screen visible and globally blocks keyboard input with Input Monitoring permission
- Automatic UI localization based on the macOS preferred language list
- Localized UI support for English, Simplified Chinese, Traditional Chinese, Japanese, Korean, French, German, Spanish, Italian, and Brazilian Portuguese
- Built-in packaging script for `.app`, `.pkg`, `.dmg`, and `.zip`

## Development

```bash
swift build
swift run MacPolishVerification
swift run MacPolish
```

## Packaging

```bash
./scripts/package_release.sh
```

Generated artifacts are written to `dist/`.
