# 2026-11-05 — Theater reflection, touchpad, recline; iOS big touchpad

## visionOS theater (TheaterScene.swift, ImmersiveTheaterView.swift)
- **Floor reflection** = the screen mesh mirrored about the floor (S·R(t) = R(−t)·S).
  The floor is y = 0, or just below the screen's bottom edge if the screen reaches lower,
  so it no longer disappears at big sizes. Texture = `theaterReflection` kernel (Shaders.metal):
  a half-res rgba16Float copy blurred more the further it is from the screen (mip LOD) and
  rippled. The opacity mask fades gradually over the full height (pow 1.8).
- **Ripples** = GamepadBridge.buttonPresses (rising edges). Each press drops a ring; the presses
  in the last 2 s set the amplitude and the ambient swell. Setting: RemotePlaySettings.waterRipples.
- **Touchpad**: the screen has Collision (box, then the exact static mesh) + InputTarget.
  A pinch-drag on it calls GamepadBridge.setTouchpadFinger (entity-local x/y → 0…1).
  A pinch under 0.3 s without moving = touchpad click. A cursor dot shows under the finger.
  Dock toggle "Touchpad" (RenderOptions.theaterTouchpad). The window ornament's "Touchpad"
  shows an alert that offers Enter Theater.
- **Recline** (RenderOptions.theaterRecline 0…85°): the seated offset from the eye
  (Height − 1.2, −Distance) rotates about the head (ARKit WorldTrackingProvider device anchor,
  captured at the start and on Recenter). The screen and dock rotate with it. The reflection is
  off at ≥ 10°. UI: Sit / Recline / Lie Down presets, a slider and Recenter in Screen, and a
  dock "Recline" toggle (0 ↔ 60°).

## Grade
- Free tier now stays on **Gaming** instead of Original. A one-time migration moves saved
  Original → Gaming (UserDefaults presetGamingMigrated).

## iOS
- Small touchpads have an enlarge button → BigTouchpad (1920:942 shape, centred). The corner
  handle resizes it (rp.touchpad.bigScale 0.35…1); the shrink button closes it.

Not compiled (no Apple toolchain); the Swift was checked with tree-sitter. Shaders.metal is unchecked.
