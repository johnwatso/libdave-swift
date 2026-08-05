# Native Framework Provenance and Third-Party Inventory

This is a checksum-backed, evidence-limited inventory for the committed `Dave.xcframework`. It is intentionally **not** presented as a complete source SBOM or a substitute for upstream license texts: the repository does not contain the upstream source revisions, dependency lockfiles, compiler command line, or license/notice files used to build the archive. Do not infer a component version or license from this document.

## Shipped artifact

| Property | Recorded value |
| --- | --- |
| Framework | `Frameworks/Dave.xcframework` |
| Platform/slice | macOS `arm64` only (`macos-arm64`) |
| Package deployment target | macOS 26.0 (`Package.swift`) |
| Static archive | `macos-arm64/libdave_merged.a` |
| Archive SHA-256 | `70d60aff259d0785e24f316420cc9785e83607d766e32657d0a3029d5cf3e3ac` |
| Last framework-changing commit | `336b481f17c9eeb880ecf2a793777b32f2976167` (2026-07-03) |

All framework-file digests are in [`Frameworks/Dave.xcframework/SHA256SUMS`](Frameworks/Dave.xcframework/SHA256SUMS). Verify them from the repository root with:

```bash
shasum -a 256 -c Frameworks/Dave.xcframework/SHA256SUMS
```

## Component inventory

| Component | Evidence in this repository | Version and license status |
| --- | --- | --- |
| Discord libdave | The last framework-changing commit says the archive was compiled from `discord/libdave`; archive members include `bindings_capi.cpp.o`, `encryptor.cpp.o`, `session.cpp.o`, and related DAVE objects. | Exact source revision and license text: **not recorded**. |
| mlspp | The same commit records mlspp headers pinned by that project's vcpkg overlay; headers/symbols and archive members contain the `mlspp` namespace and MLS implementation object names. | Exact source revision and license text: **not recorded**. |
| OpenSSL/libcrypto | The archive has `libcrypto-*` object members. | Exact OpenSSL release, build options, and license/notice text: **not recorded**. |

The archive alone does not establish the exact versions or licenses of those components. A binary refresh must not reuse this table as a license assertion.

## Required workflow for a binary refresh

1. Record the exact upstream repository URLs and immutable source revisions, plus the vcpkg manifest/lock or equivalent dependency resolution.
2. Preserve the build script, Xcode/SDK version, architecture, and deployment target used to create the archive.
3. Collect and commit the applicable upstream license and notice texts before distributing the refreshed framework.
4. Regenerate `Frameworks/Dave.xcframework/SHA256SUMS`, update this inventory, and run the CI framework-integrity check.
5. Produce a complete SPDX or CycloneDX SBOM from the locked source inputs. Until then, this inventory is deliberately limited to what the checked-in artifact proves.
