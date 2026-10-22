# Couchport: notices

Copyright © 2026 The Couchport Authors.

Couchport is free software, licensed under the **GNU Affero General Public
License, version 3** (see `LICENSE`). It comes with **no warranty**.

## Why AGPL

Couchport's Remote Play layer links code from Chiaki, chiaki-ng and Pylux, all
licensed AGPL-3.0 (with the OpenSSL linking exception, see
`LICENSES/AGPL-3.0-only-OpenSSL.txt` in those projects). The app as a whole is
therefore distributed under the AGPL-3.0, including the visionOS/iOS app code,
the ChiakiShim C API and the Couchport Pro purchase code.

## Third-party components

| Component | License | Source |
|---|---|---|
| Chiaki | AGPL-3.0 + OpenSSL exception | https://git.sr.ht/~thestr4ng3r/chiaki |
| chiaki-ng | AGPL-3.0 + OpenSSL exception | https://github.com/streetpea/chiaki-ng |
| Pylux (pinned commit in `Tools/build_libchiaki_visionos.sh`) | AGPL-3.0 + OpenSSL exception | https://github.com/ForWard-Technologies-LLC/Pylux |
| Mbed TLS 2.28.0 | Apache-2.0 | https://github.com/Mbed-TLS/mbedtls |
| Opus | BSD-3-Clause | https://opus-codec.org |
| json-c 0.17 | MIT | https://github.com/json-c/json-c |
| miniupnpc | BSD-3-Clause | https://github.com/miniupnp/miniupnp |
| curl | curl License | https://curl.se |
| nanopb | zlib | https://github.com/nanopb/nanopb |
| Jerasure | BSD-3-Clause | https://github.com/tsuraan/Jerasure |
| GF-Complete | BSD-3-Clause | https://github.com/ceph/gf-complete |

The exact versions are whatever the pinned Pylux commit and its submodules /
FetchContent declarations resolve to. `Tools/build_libchiaki_visionos.sh`
copies each component's own license file into `Resources/Licenses/`, and the
app's About screen shows them.

## Trademarks

Couchport is an independent app and is not affiliated with, endorsed by, or
sponsored by Sony Interactive Entertainment, Microsoft, or Apple. PlayStation,
PS5 and PS4 are trademarks of Sony Interactive Entertainment Inc. Other names
are trademarks of their respective owners and are used only to describe
compatibility. The AGPL does not grant any trademark rights; the Couchport name
and icon are not licensed for use by forks.
