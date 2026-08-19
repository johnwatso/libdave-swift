# Releasing libdave-swift

`libdave-swift` uses plain SemVer Git tags (`1.3.1`, not `v1.3.1`) as its
package version. `Package.swift` has no duplicate version field, so the tag,
release notes, bundled framework, and checksums must describe the same commit.

## Version choice

Use a patch version only for a compatible bug fix with no new public contract.
Use a minor version for an additive API that leaves existing source, persisted
data, and documented runtime behavior compatible. Use a major version when an
existing client needs a code or deployment migration — including a new public
enum case that breaks an exhaustive switch, a change to persisted diagnostics
data, a change to media-readiness or gateway action delivery, or a raised
toolchain or platform requirement.

Pre-release tags such as `3.0.0-rc.1` are **not** supported by the release
pipeline: the tag check in CI requires plain SemVer. Validate a candidate from
its commit SHA, or from a branch, rather than from a pre-release tag.

## Before tagging

Perform the following on an Apple Silicon Mac running macOS 26 or later, from
the release candidate commit:

1. Move the `Unreleased` section in [CHANGELOG.md](../CHANGELOG.md) to the
   intended version and date. The notes must describe observable behavior, not
   implementation guesses.
2. Verify the working tree only contains intended changes and has no whitespace
   errors:

   ```sh
   git status --short
   git diff --check
   ```

3. Validate source and test builds from the candidate:

   ```sh
   swift build -c release
   swift test
   ```

4. Validate the shipped binary exactly as consumers will receive it:

   ```sh
   plutil -lint Frameworks/Dave.xcframework/Info.plist
   shasum -a 256 -c Frameworks/Dave.xcframework/SHA256SUMS
   lipo Frameworks/Dave.xcframework/macos-arm64/libdave_merged.a -archs
   ```

   The final command must report `arm64`. If the framework changed, regenerate
   its checksum manifest and update [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
   with the available provenance; do not invent component versions or licenses.

5. Run the real Voice gateway integration fixture described in
   [MLS_INTEGRATION_FIXTURES.md](MLS_INTEGRATION_FIXTURES.md), if one is
   available. Unit tests alone cannot validate unrelated MLS artifacts.

   No such fixture exists yet, and that document explains why a captured one
   cannot cover the whole path: a Welcome is sealed to an HPKE init key that is
   regenerated on every call and never persisted, so key ratchets, re-keys, and
   encrypted media cannot be exercised from captured bytes. Until that gap is
   closed, treat a release that changes the media or MLS transition paths as
   unvalidated there, and verify it against a real client in a disposable Voice
   channel before rolling it out.
6. Confirm the CI build-and-test job has passed for the exact candidate SHA.
   Its consumer smoke test verifies that a fresh Swift package can link and run
   against the bundled framework.

## Tag and publish

After all checks pass, create an annotated tag on the verified commit and push
the branch and tag:

```sh
git tag -a 3.0.0 -m "libdave-swift 3.0.0"
git push origin main 3.0.0
```

Wait for the tag-triggered CI run to pass, then create the GitHub release using
the matching changelog section. Keep the release notes explicit about the
supported platform: Apple Silicon macOS 26+ only.

## After publishing

Verify a clean consumer resolves the immutable tag, rather than the local
checkout:

```swift
.package(url: "https://github.com/johnwatso/libdave-swift.git", exact: "3.0.0")
```

For SwiftBot, land its dependency and integration update only after that tag
and consumer verification have succeeded. This makes a bot rollback a normal
package-version rollback rather than a source-tree recovery exercise.
