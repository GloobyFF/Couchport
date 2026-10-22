# 2026-10-22 — Couchport Pro (StoreKit 2)

Product: `com.glooby.UVCTheater.pro` (non-consumable, Family Sharing on).

## Free vs Pro
| | Free | Pro |
|---|---|---|
| Remote Play session | 10 min of streaming per Play (connecting/waking not counted) | Unlimited |
| Resolution | 720p | 720p / 1080p |
| Bitrate | 10 / 15 / 20 Mbps | Auto, 5–50 Mbps |
| HDR (10-bit) | — | ✓ |
| Picture enhancement (upscale, sharpen, colour presets) | — (Original grade) | ✓ |
| Capture card / Developer Strap mode | — | ✓ |

Orientation flips and colour matrix/range stay free (they are corrections, not enhancement).

## Code
- `Store/PurchaseManager.swift` — StoreKit 2: product load, `PurchaseAction` purchase (visionOS scene-aware), restore (`AppStore.sync`), `Transaction.updates` listener, `currentEntitlements` check. `isPro` is cached in UserDefaults so a Pro user is never downgraded while StoreKit answers. `FreeTier` holds the limits. `paywallRequest` opens the paywall from anywhere.
- `Store/PaywallView.swift` — paywall sheet (comparison grid, buy, restore), `ProBadge`, `ProUpsellRow`, `FreeTimeChip`.
- `AppModel` — free-session clock (runs only while `.streaming`), 1-minute warning, auto stop + paywall at 0, `applyFreeTierLimits()` once StoreKit confirms no purchase.
- `RemotePlayManager.connect` — clamps resolution / bitrate / HDR at connect time too.
- Home: crown button (top right, left of Stream Settings) opens the paywall; capture card shows PRO and "Unlock with Pro".
- Settings: 1080p hidden, HDR disabled, bitrate list 10–20 for free users; Enhance panel upscale/sharpen/preset disabled with an upsell row.
- Player: "Free · m:ss" chip; alert at 1 minute left. Immersive theater: chip + warning card above the bar; any paywall request exits the theater and shows the paywall in the window.
- `UVC Theater.storekit` now contains the product (9.99 placeholder); `project.yml` scheme uses it for local testing.

## Cleanup
Removed from the tree: DerivedData, __MACOSX, icon/, OPTIMIZATION_SUMMARY.md, xcuserdata, .DS_Store, and 20 unused strings in Localizable.xcstrings.
