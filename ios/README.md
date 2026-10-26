# Waterline for iOS

Draws a forecast water level on the camera view at the Ferry Building seawall. **v0 is marker mode:** you tap a seawall mark whose elevation you know, enter its height in ft MLLW, and pick a scenario. The water plane then sits at (scenario − mark) above that point, and LiDAR iPhones hide it behind people and bollards. Absolute anchoring with ARCore Geospatial terrain anchors comes next (`plan/ar-anchoring.md`).

Bundle `com.craigmerry.waterline`, team WYGG3JXWMG, 1.0. Builds run on the MacInCloud Mac over SSH from the Pi; there is no GitHub Actions job.

```bash
SSHOPTS="-i ~/.ssh/macincloud_ed25519 -o BatchMode=yes"
MAC=user273508@LA688.macincloud.com
rsync -az --delete -e "ssh $SSHOPTS" ios/ $MAC:waterline-ios/
ssh $SSHOPTS $MAC 'cd waterline-ios && ~/bin/xcodegen generate && xcodebuild -project Waterline.xcodeproj -scheme Waterline -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"'
```

That unsigned build is the free compile check. A signed archive goes to TestFlight, one upload per working session; unlock the keychain in the same SSH connection as the archive.

## Gotchas

- ARKit doesn't run in the Simulator; test on a device.
- Marker mode is only as good as the mark's elevation. Use a surveyed point or the lidar plaza grade (10.1 ft MLLW), and say which one you used on screen.
- `Waterline.xcodeproj` is generated, so edit `project.yml`, not the project file.
