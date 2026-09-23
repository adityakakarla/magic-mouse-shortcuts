# Magic Mouse Shortcuts

A tiny menu bar app that adds **tap to click** and **pinch to zoom** to the Apple Magic Mouse.

- **One-finger tap** → left click (tap twice quickly for a double-click)
- **Two-finger tap** → right click (can be turned off)
- **Two-finger pinch** → zoom in/out, just like a trackpad pinch (Safari, Maps, Preview, Photos, …)
- Physical clicks, scrolls/swipes, and taps while you're moving the mouse are ignored
- Only Magic Mice are affected, not your trackpad

## Build & install

```bash
./build.sh             # builds build/MagicMouseShortcuts.app
./build.sh --install   # also copies it to /Applications and launches it
```

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

On first launch, macOS asks for **Accessibility** access (System Settings → Privacy & Security →
Accessibility). Turn on Magic Mouse Shortcuts, because it can't send clicks without it. The app is signed
ad hoc, so after a rebuild you may have to remove Magic Mouse Shortcuts from that list and add it again.

## Menu

Click the cursor icon in the menu bar to toggle tap to click, two-finger right click, pinch to zoom, and launch
at login, or to rescan for devices. The app picks up the mouse again when it reconnects or the Mac
wakes from sleep.

## Tuning & debugging

Run `build/MagicMouseShortcuts.app/Contents/MacOS/MagicMouseShortcuts --debug` to log detected devices and every touch
(finger count, duration, whether it moved) and pinch start/end, and to see why a tap was or wasn't
turned into a click. The thresholds are at the top of `TapEngine` and `ZoomEngine` in `Sources/main.swift`:

| Setting | Default | Meaning |
|---|---|---|
| `maxTapDuration` | 0.22 s | Longer touches count as resting fingers, not taps |
| `maxFingerTravel` | 2 mm | Finger movement allowed before it counts as a scroll |
| `maxCursorTravel` | 8 pt | Cursor movement allowed during a tap |
| `startThreshold` | 4 mm | How far the fingers must spread/close before a pinch starts |
| `sensitivity` | 0.03 | Zoom amount per mm of pinch; raise it for faster zooming |

## How it works

It reads raw touch frames from Apple's private `MultitouchSupport.framework` (the same approach
used by MagicPrefs, BetterTouchTool and MiddleClick). When a short touch that doesn't move ends, it
posts a click with `CGEvent`. A pinch posts the same zoom gesture
events a trackpad sends, and the mouse's own scroll events are blocked while you pinch. Because the framework is private, a future macOS update could break it.
