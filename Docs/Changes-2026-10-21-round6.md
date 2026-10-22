# 2026-10-21 — Round 6: everything from the roadmap at once

REBUILD THE LIBRARY FIRST: ChiakiShim changed (VP_CHIAKI_API_VERSION 2).
    cd /Volumes/2T/APPTest/PS5 && ./Tools/build_libchiaki_visionos.sh
    xcodegen generate && open PS5VisionCapture.xcodeproj

## Controller (DualSense)
- Haptics: the PS5 sends DualSense haptics as 3 kHz stereo audio. New shim haptics_cb → ControllerFeedback converts each 10 ms block to intensity + sharpness (zero-crossing rate) for the left/right actuators (CoreHaptics, GCHapticsLocality.leftHandle/.rightHandle; single engine fallback), updated every 20 ms on a private queue. Strength slider 20–150 %.
  Note: with DualSense mode on, PS5 games send haptics INSTEAD of rumble events, so before this change most PS5 games had no vibration at all.
- Adaptive triggers: VP_EVENT_TRIGGER_EFFECTS → AdaptiveTriggerTranslator maps DS5 effect bytes (0x01/02/06, 0x21/22/23/25/26/27) to GCDualSenseAdaptiveTrigger feedback/weapon/vibration modes; reset on stop.
- Light bar: VP_EVENT_LED_COLOR → GCController.light.
- Touchpad: two fingers (touchpadPrimary/Secondary → PS 1920×942 space), the shim allocates chiaki touch ids.
- Motion: GCMotion gyro/accel remapped to the PS frame, ≤120 Hz; orientation is integrated in the shim (chiaki orientation tracker). Toggle "Motion Controls (Gyro)".
- Settings › Controller section: Haptic Feedback + Strength, Adaptive Triggers, Motion Controls.

## HDR
- Setting "HDR (10-bit)" (needs HEVC, PS5): requests CHIAKI_CODEC_H265_HDR, VideoToolbox outputs x420 (10-bit), the renderer reads r16/rg16 planes.
- Colour info comes from the buffer attachments: BT.2020 matrix, PQ or HLG transfer → shader decodes PQ/HLG to nits, tone-maps (extended Reinhard on max channel, 203-nit white, 1000-nit peak), converts BT.2020→BT.709. Output stays SDR so the window and the RealityKit theater keep their sRGB path. True EDR output is a later step.

## Network
- LAN search without the multicast entitlement: LANScanner sends the PlayStation SRCH request by unicast to every host of the /24 (ports 9302/987, 3 rounds, 5 s) and merges with chiaki's broadcast discovery. Add Console starts a search automatically when no console is paired and pre-fills the first result.
- Stats: shim vp_session_get_stats → console-measured bitrate, RTT (measured at session start), congestion-control packet loss, shown in Stats › Remote Play Stream.

## Theater
- Screen presets: Desk / Living Room / Cinema / IMAX.
- Room Dimming slider: an inside-out black sphere (r = 40 m) with OpacityComponent dims passthrough around the screen (default 60 %).

## Localization
- German, Spanish, French, Japanese and Korean now cover every UI string (0 missing), plus the two Info.plist permission texts.

## Not included
- PSN internet holepunch (remote play outside home) and the clean-room protocol rewrite: separate projects.
- Microphone / party chat: needs the Opus encoder path in the shim; next shim round.

## Round 6b — theater polish (same day)
- Screen edge aliasing: the theater texture now has mipmaps (generated after each blit), and the screen uses a rounded-rectangle alpha mask with a 3-texel soft edge (transparent blending), so the hard polygon edge no longer stair-steps. Corner radius ≈ 3 % of the screen height. Dim sphere and screen share a ModelSortGroup (sphere first).
- Immersive controls are fixed in space (BillboardComponent removed).
- Immersive bar: new Stats panel (StatsSections, shared with the window sheet). Stop = end stream + go Home + leave theater (red, white text). "Exit Theater" is now a labelled button: back to the window, stream keeps running.
- 2D control bar: removed the back chevron (it did the same as Stop), Stop text is white, Theater icon is mountain.2.fill.
- Reconnect after Stop: the console keeps the old session a few seconds and reported "in use". start() now waits until 4 s after the last session ended and allows one automatic retry.
- Round 6c: immersive controls tilted back 30° (orientation about X).
- Round 6d: StrapSetup art replaced with the holographic style (option 2).
- Round 6e: RemoteHero art replaced with the holographic style (option B).

- Round 6f: app renamed to Couchport (display name, Home title, strings, privacy texts). New 3-layer icon (ring + sofa middle, pill controller front).

## Round 6g (2026-10-22) — trademark hygiene
- Home footer: independent-app / trademark notice (7 locales). README "Trademarks" section.
- Replaced every `playstation.logo` SF Symbol (console cards → gamecontroller.fill, PS button → button.programmable).
- Hero tagline now "Play your console…"; "PS REMOTE PLAY" eyebrow → "REMOTE PLAY"; fallback title "Console".
- Descriptive PS5/PS4 model labels and setup instructions are kept (nominative use).
- Home art: RemoteHero and StrapSetup replaced with generic console / standalone developer strap (no PS5, no Vision Pro). Sources in work/art/generic.
- Home header mark: PS-style shape grid replaced by the Couchport icon (AppMark.imageset).
- Home tagline: "Sit back. Step in." / 窝进沙发，一步入战。
