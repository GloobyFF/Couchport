# 2026-11-04 — chiaki-ng v1.10.1 fixes ported onto Pylux

Pylux stays pinned at `ca87a49a` (2026-08-13). Upstream lib fixes from chiaki-ng
v1.10.1 (released 2026-11-03) are carried as one patch,
`Tools/patches/pylux-chiaki-ng-1.10.1.patch`, which
`Tools/build_libchiaki_visionos.sh` applies after resetting the pinned tree.
No Swift or shim API changes.

## Ported

| chiaki-ng commit | What it fixes | How |
|---|---|---|
| 4382c1c, bfbb296, c938844, bc397a7, 698e0ec | Buttons that stay held or stop working mid-stream (lost release packet, event count in header, one event per packet, sequence numbering, release → touch → press order) | Manual merge: v1.10.1 `feedbacksender.c` + `chiaki_feedback_history_buffer_record_state()`, keeping Pylux's PS chord (raw state → chord transform → history). The thread wakes every 16 ms while a chord is held. |
| 3e1a24d | Lost reliable Takion packets not resent (buffer 16 → 1024) | Manual |
| e5f1dd8 | Crash when a sender pushes into the Takion send buffer after the receive loop ended | Manual (`send_buffer_active` + mutex) |
| 06051d1 | Registration search packet sent only once (pairing by IP/port could time out) | Manual: resend every 500 ms within the 3 s window |
| db6f547 | HTTP header receive could overwrite its buffer | Manual |
| 727917c | Reorder queue left dropped entries behind | Clean apply |
| 65583ae | PSN control channel closed on a bad packet | Clean apply |
| 27ab96f | Ask a PS5 for trigger effects the controller can apply | Clean apply |
| a138ab3, 473364a, a7831ec, 6fd9082 | Bounds checks for STUN, PS4 wakeup and PSN HTTP data | Clean apply |
| 15098e4 | Quiet microphone frames dropped | Clean apply (we do not send mic yet) |
| 728d2b6 | Login PIN in verbose logs | Clean apply |

## Not ported, and why

- **8134f45, lost IDR → freeze.** Pylux's video receiver predates chiaki-ng's
  "wait for requested IDR" state. It reports corrupt frames and repairs
  reference frames, so this freeze doesn't exist in our engine. That's also why
  `vp_session_request_idr` is still a no-op.
- **0212445, ac7a284, 30ad76c (PSN ctrl heartbeat and error pause), c7072e4
  (UPnP), AIA certificate recovery.** These cover PSN internet play only, and
  Couchport doesn't do that yet. Port them together with PSN holepunch.
- **8d18ad6.** Log wording only.
- **Renderer, haptics, macOS, Qt and packaging changes.** They live in the
  chiaki-ng GUI, not in the lib.

## Checks

- `zig cc` compiles feedbacksender, feedback, takion, takionsendbuffer, http,
  regist, ctrl, reorderqueue, audiosender, and the shim against the patched
  headers.
- `git apply --check` passes on a clean `ca87a49a`.
- Not built for Apple yet. On the Mac, run `./Tools/build_libchiaki_visionos.sh`,
  which prints `=== applying pylux-chiaki-ng-1.10.1.patch`.

## Device test

Release buttons quickly while moving a stick or trigger, and on a lossy Wi-Fi
link, to confirm no button sticks.
