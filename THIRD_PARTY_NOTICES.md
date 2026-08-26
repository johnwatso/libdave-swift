# Native Framework Provenance and Third-Party Inventory

The committed `Dave.xcframework` is built from immutable inputs by
`Scripts/build-native-framework.sh`. Machine-readable build metadata, an SPDX
2.3 SBOM, license texts, and file digests are shipped inside the framework.

## Shipped artifact

| Property | Recorded value |
| --- | --- |
| Framework | `Frameworks/Dave.xcframework` |
| Platform/slice | macOS `arm64` only (`macos-arm64`) |
| Deployment target | macOS 26.0 |
| Static archive | `macos-arm64/libdave_merged.a` |
| Archive SHA-256 | `f83079a354aa6ba00d68da155c21382a672e26fc4c4198a04392c577e7ec7e0d` |
| Compiler | Xcode 26.6 (17F113) |

Verify every bundled file, its pinned inputs, architecture, and embedded
OpenSSL version from the repository root:

```bash
Scripts/verify-native-provenance.sh
```

## Native inputs

| Component | Immutable version | License |
| --- | --- | --- |
| Discord libdave | tag `v1.1.1/cpp`, commit `52cd56dc550f447fb354b3a06c9e2d2e2a4309c6` | MIT |
| Cisco mlspp | commit `1cc50a124a3bc4e143a787ec934280dc70c1034d` | BSD-2-Clause |
| OpenSSL/libcrypto | 3.0.7 | Apache-2.0 |
| nlohmann/json | 3.11.3#1 | MIT |

Dependency resolution uses libdave's vcpkg submodule at
`16c71a39e5a0fc0bdb3fad03beef8f38ee00ee3b` and its OpenSSL-3 manifest baseline
`d07689ef165f033de5c0710e4f67c193a85373e1`. Build tooling is pinned in
`Native/versions.env`; the script currently enforces Xcode 26.6 (17F113), CMake
3.30.1, Ninja 1.12.1, and pkgconf 2.4.3.

The source license copies are in `ThirdPartyLicenses/` and duplicated under
`Frameworks/Dave.xcframework/Licenses/`. The component inventory is available
as `Frameworks/Dave.xcframework/SBOM.spdx.json`, while exact build metadata is
in `Frameworks/Dave.xcframework/BUILD-METADATA.json`.

## Rebuilding

On an Apple Silicon Mac with Xcode 26.6 or a deliberately reviewed successor:

```bash
Scripts/build-native-framework.sh
DAVE_FRAMEWORK_ROOT="$PWD/.build/native-rebuild/output/Dave.xcframework" \
  Scripts/verify-native-provenance.sh
DAVE_EXTERNAL_SENDER_HELPER="$PWD/.build/native-rebuild/build/integration/dave_external_sender_helper" \
  swift test --filter RuntimeMLSIntegrationTests
```

The build works in the dedicated `.build/native-rebuild` directory and checks
out the exact libdave and vcpkg revisions on every run. The local patch enables
libdave's generic persisted-key backend on Apple platforms and removes
test-only dependency resolution from the production native manifest; it is
validated against the pinned source before application.

Before committing a refreshed artifact, copy the verified output into
`Frameworks/Dave.xcframework`, rerun the default provenance verifier, and update
this file if any recorded input or digest changed.
