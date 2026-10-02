# MacPolish

[中文](./README.md)

MacPolish is a native macOS cleaning utility for wiping down a MacBook while protecting both the display and keyboard input. It combines screen cleaning and keyboard cleaning into one app, with dedicated modes for the whole Mac, the screen only, or the keyboard only.

## Download and install

[Download the latest release](https://github.com/JiGuangYa/MacPolish/releases/latest). Requires macOS 13 or later; each package includes Apple silicon and Intel builds.

Open `MacPolish.dmg` and drag MacPolish into Applications, or use the `.pkg` installer. Releases also include a `.zip`, SHA-256 checksums, and a build manifest. Packages currently use a local ad-hoc signature and are not Apple notarized.

## Features

- Native macOS `SwiftUI + AppKit` app
- Three cleaning modes: `Whole Mac`, `Screen Only`, and `Keyboard Only`
- `Whole Mac` mode blacks out all displays and blocks local keyboard input, adding system-wide capture when available
- `Screen Only` mode blacks out the display while leaving the keyboard usable
- `Keyboard Only` mode keeps the screen visible and globally blocks keyboard input with Accessibility permission
- Settings for remembering the last mode, returning to the main window, exit hints, and control fade timing
- Menu bar access to start or finish cleaning and reopen the main window, always available during a session
- A dedicated active-session view with elapsed time and actual keyboard protection scope, plus explanations after automatic exits
- A monotonic session timer and startup click guard that are unaffected by wall-clock changes
- A fixed exit button and hold-to-exit countdown in the main window, reachable without scrolling even at its minimum size
- Vertically resizable settings with a named accessibility slider, values in seconds, and 0.1-second adjustments
- Persistent shield exit controls while VoiceOver or Switch Control is active, with the saved fade delay restored afterward
- Periodic global capture checks that end the session if permission is revoked or capture stops working
- Detects macOS Secure Input and offers recovery guidance without unnecessary permission requests or relaunches
- Ends local-only protection when another app takes focus
- Safe app reopening: waits for a new instance to finish launching, keeps this instance open on failure, and prevents duplicate requests
- Automatic session cleanup when the app is hidden, the system or displays sleep, the user session switches away, or the display configuration changes
- Display interruptions require an actual identity, size, position, or scale change; menu bar item changes do not end a session
- Automatic UI localization based on the macOS preferred language list
- Localized UI support for English, Simplified Chinese, Traditional Chinese, Japanese, Korean, French, German, Spanish, Italian, and Brazilian Portuguese
- Universal `.app`, `.pkg`, `.dmg`, and `.zip` packages containing both Apple silicon and Intel builds
- Release checks for architectures, signatures, localization, and archive contents, with SHA-256 checksums and preservation of the previous output on failure

## Usage and exit controls

Requires macOS 13 or later.

| Mode | Keyboard behavior | How to finish |
| --- | --- | --- |
| Whole Mac | Blocks keys within the app; adds system-wide capture when available | Move the pointer and click Done, or hold Control + Option + Esc for three seconds |
| Screen Only | Leaves the keyboard usable | Click the screen; Esc also works while MacPolish is in the foreground |
| Keyboard Only | Blocks keys system-wide; requires Accessibility access | Click Exit Cleaning, use the menu bar icon, or hold Control + Option + Esc for three seconds |

Screen Only briefly ignores repeated launch clicks and their releases for the system double-click interval (at least 0.45 seconds). A fresh click then ends cleaning. Esc remains available while MacPolish is in the foreground.

Whole Mac and Keyboard Only actions from the menu bar or Cleaning menu first open the main window and wait until it is visible and focused on the current desktop. This also ensures Whole Mac can provide local keyboard protection when global capture is unavailable. You can cancel while waiting. If it is not ready within five seconds, the keyboard stays available and the app explains the failure. Keyboard Only permission and refresh commands also restore the window, but do not automatically begin cleaning when access becomes ready. Screen Only does not need to restore the main window.

In either keyboard-blocking mode, hold **Control + Option + Esc for three seconds** to finish. A countdown appears while holding. Releasing a chord key, pressing another key, or a capture interruption cancels it; the next hold requires three fresh seconds. Ordinary Escape stays blocked to avoid accidental exits while wiping. Disabling exit hints does not hide an active countdown. The countdown continues while a menu is open or a control is being dragged.

Before using Keyboard Only, enable MacPolish in System Settings → Privacy & Security → Accessibility. Authorization buttons use the same Accessibility name as macOS. MacPolish does not save or upload what you type; this is also explained beside the permission controls in the main window and settings. If the app asks you to relaunch, reopen it before starting a session. Reopening shows progress and waits for the new instance to finish launching before the current one quits. A failure or 15-second timeout keeps the current app usable and shows a retry message in the main window and settings.

Keyboard Only also ends when its main window closes, minimizes, or is left on another desktop after a Space change, so capture stops when its exit button disappears. Changing Spaces on another display preserves cleaning if the main window remains available. Leaving the target desktop also cancels a pending window-opening request. Cleanup caused by closing or hiding the app, sleep, user switching, Space changes, or display changes does not reopen the window or bring the app to the foreground. Start a new session manually after returning.

If global keyboard protection fails during cleaning, the session ends with recovery guidance; returning to the main window follows your setting. Capture loss, revoked permission, and Secure Input detection continue while menus are open or controls are being dragged. Whole Mac without global capture is labeled Local protection because system shortcuts may still work. A local-only session ends when another app takes focus, without bringing MacPolish back to the foreground.

macOS Secure Input, used by password fields and some apps, can prevent keyboard interception even with Accessibility access ([Apple technical note](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)). MacPolish detects this temporary block and ends affected sessions without taking focus away from password entry. Finish entering your password or close the app using Secure Input, then refresh the status. Keyboard cleaning becomes available again when the block clears; screen cleaning and Whole Mac with local protection remain available in the meantime.

## Development

```bash
swift build
swift run MacPolishVerification
swift run MacPolish
```

`MacPolishVerification` checks permission flows, session interruptions, failure cleanup, settings persistence, and localization. It also exercises the production keyboard service with injected permission/tap providers and real, unposted `CGEvent` values, including modifier/media filtering, timeout recovery, Secure Input, stale callbacks, and resource ownership. Hidden native windows verify input handling, mouse exits, repeated or queued launch-click suppression, and fixed shield geometry, including negative display origins; real timers verify hint and control fading. Menu-start checks cover delayed window readiness, timeout, cancellation, duplicate actions, permission changes, and stale requests. Emergency-exit checks cover the three-second boundary, key release, repeats, stale sessions, both global and local input routes, and the live countdown timer. Nested event loops verify hold-to-exit and protection monitoring during menu/drag tracking, including timer cleanup after key release, session stop, or owner release. Relaunch checks cover failure, startup readiness, timeouts, stale callbacks, duplicate requests, and continued usability after failure. It does not request permissions, install a global event tap, post system input, or show desktop windows. Sleep, focus loss, and display changes use injected notifications. Hidden windows simulate Space membership to check loss of the exit window, preserved visibility on an active Space, and cancellation of pending starts. Local protection also verifies rejection without foreground focus. Assistive technology changes use injected state and real fade timers; the system observer is checked read-only without switching VoiceOver or Switch Control on or off. Actual spoken feedback, switch-device use, Space transitions, and hardware behavior still need manual confirmation on macOS.

Render the actual SwiftUI views offscreen:

```bash
./scripts/render_previews.sh                 # English, Simplified Chinese, German
./scripts/render_previews.sh ja ko zh-Hant   # Specific supported languages
```

Each language produces 70 light/dark previews covering first-use and denied permissions, active cleaning, screen shields and hold-to-exit countdowns, capture loss, Secure Input, the Space-change exit notice, app and main-window reopening progress/failure, compact windows, minimum-height cleaning and countdown views, settings, fully expanded fade controls, persistent controls during assistive technology use, and high-contrast variants in `.build/previews/`. The renderer uses fake services, never shows desktop windows, and verifies the effective language so English fallback cannot conceal layout problems. The minimum-size first-use preview scrolls to the bottom to check the keyboard card's explanation and button.

High-contrast previews use underscored SwiftUI environment overrides only in the verification target to inject contrast, reduced transparency, and reduced motion, then check the effective values. The shipping app does not use these overrides, and system preferences stay unchanged. Real system-toggle and assistive-device interactions still require manual verification.

Verify the actual macOS app-launching path in a logged-in desktop session:

```bash
./scripts/verify_relaunch.sh
```

This builds a temporary background-only probe app, launches two distinct instances through the production relauncher, confirms startup and handoff, then terminates the probes. It does not launch MacPolish, request permissions, intercept input, or quit the verification process. A 20-second fallback timer also exits a probe if the test is interrupted. CI runs the ordinary verification suite in both Debug and Release; the native launcher probe is a separate local check.

Verify actual window and menu actions in a logged-in desktop session:

```bash
python3 scripts/verify_window_flow.py
python3 scripts/verify_window_flow.py --configuration release
python3 scripts/verify_window_flow.py --settings-only --output .build/settings-verification.json
python3 scripts/verify_window_flow.py --shield-only --output .build/shield-verification.json
```

This separate opt-in check briefly shows test windows and menus using the same SwiftUI scenes as the shipping app. Thirteen checks cover menu start/stop, reopening a closed window, restoring a minimized window, cleanup on close/minimize, the Escape menu binding, permission recovery, restoring foreground focus before Whole Mac cleaning, temporary menu bar insertion, and Settings slider accessibility, adjustments, disabled state, and window resizing. Accessibility checks query only the probe app’s own nodes and change its isolated preferences. The production shield view is rendered inside an ordinary small window to verify persistent accessibility under simulated assistive technology, restored fading afterward, and an accessibility press that invokes the exit callback. Keyboard capture, screen shields, and permission services are simulated: it never intercepts keys, covers displays, requests permissions, or posts system input. It uses isolated settings and closes itself when finished; if still in the foreground, it requests a return to the previously active app.

Keep the probe in the foreground and avoid running other UI tests concurrently; failure to obtain focus is reported as a failed check, with the keyboard remaining usable. Results are saved to `.build/window-verification.json` with the build configuration, verification time, and window diagnostics; use `--output` to choose a path. Ordinary verification and CI do not run this visible UI check. Global keyboard interception and physical display changes still require hardware testing.

## Packaging

```bash
./scripts/package_release.sh
```

The script can run from any working directory. It first builds an `arm64 + x86_64` universal app targeting macOS 13 in a temporary directory, then inspects the actual app inside each DMG, PKG, and ZIP. Checks cover architectures, minimum OS version, system-library dependencies, all ten languages, signatures, installation paths, and identical app contents. Only a fully verified release replaces the files in `dist/`. Build or validation failures leave the previous output in place; file replacement failures roll back.

Set the version and build number when needed:

```bash
APP_VERSION=1.2.0 APP_BUILD=3 ./scripts/package_release.sh
```

The version must have three numeric components and the build number must be a positive integer. `dist/release-manifest.json` records the version, architectures, source revision and dirty state, signing status, and archive checksums. Existing output can be checked independently:

```bash
python3 scripts/verify_release.py dist
(cd dist && shasum -a 256 -c SHA256SUMS)
python3 scripts/test_release_tools.py
```

Packages currently use a local ad-hoc signature; **they are not Developer ID signed or Apple notarized**. A successful check confirms file and signature integrity, not Developer ID trust or notarization. CI builds and inspects universal packages; this does not replace runtime validation on the target macOS versions and real Intel hardware.
