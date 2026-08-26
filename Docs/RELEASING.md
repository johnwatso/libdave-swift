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
   Scripts/verify-native-provenance.sh
   ```

   This validates checksums, pinned build metadata, the `arm64` slice, and the
   embedded OpenSSL version. If the framework changed, rebuild it with
   `Scripts/build-native-framework.sh` and update the inventory, licenses, and
   SBOM together.

5. Rebuild the immutable native inputs and run the live MLS loopback described
   in [MLS_INTEGRATION_FIXTURES.md](MLS_INTEGRATION_FIXTURES.md):

   ```sh
   Scripts/build-native-framework.sh
   DAVE_EXTERNAL_SENDER_HELPER="$PWD/.build/native-rebuild/build/integration/dave_external_sender_helper" \
     swift test --filter RuntimeMLSIntegrationTests
   ```

   This is required for changes to MLS transitions, rosters, ratchets, or media.
   A disposable real Voice-channel run remains valuable for gateway integration
   changes that the external-sender protocol does not model.
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
