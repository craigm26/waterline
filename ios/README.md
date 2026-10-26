# Waterline for iOS

Draws a forecast water level on the camera view at the Ferry Building seawall. **v0 is marker mode:** you tap a seawall mark whose elevation you know, enter its height in ft MLLW, and pick a scenario. The water plane then sits at (scenario − mark) above that point, and LiDAR iPhones hide it behind people and bollards. Absolute anchoring with ARCore Geospatial terrain anchors comes next (`plan/ar-anchoring.md`).

```bash
brew install xcodegen
cd ios && xcodegen generate && open Waterline.xcodeproj   # set your Team in Signing, run on a device
```

CI (`.github/workflows/ios-build.yml`) compiles every push on a macOS runner, unsigned. That's the compile loop when the code is written on a machine without Xcode.

## Gotchas

- ARKit doesn't run in the Simulator; test on a device.
- Marker mode is only as good as the mark's elevation. Use a surveyed point or the lidar plaza grade (10.1 ft MLLW), and say which one you used on screen.
- `Waterline.xcodeproj` is generated, so edit `project.yml`, not the project file.
