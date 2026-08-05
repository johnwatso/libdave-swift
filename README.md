<p align="center">
  <img src="assets/libdaveswift.png" alt="libdave-swift logo" width="240">
</p>

<h1 align="center">libdave-swift</h1>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9-orange.svg" alt="Swift 5.9"></a>
  <a href="https://www.swift.org/package-manager/"><img src="https://img.shields.io/badge/SPM-compatible-brightgreen.svg" alt="Swift Package Manager compatible"></a>
  <a href="Package.swift"><img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="Platform: macOS 26+"></a>
</p>

A Swift Package wrapping **Discord's Audio & Video End-to-End Encryption (DAVE) Protocol**. 

This package was developed to support **[`swiftbot`](https://github.com/johnwatso/SwiftBot)** with native end-to-end encryption capabilities on macOS.

---

> [!NOTE]
> **Development Note**
> This Swift Package was generated with the assistance of an AI coding agent. While the codebase compiles successfully, passes its initial unit tests, and implements standard memory-safe wrappers, it is recommended to perform standard validation and testing before deploying in production environments.

---

## Features

* **Self-Contained Integration:** The bundled `Dave.xcframework` contains the native DAVE/MLS/libcrypto implementation, so client applications need no CMake or vcpkg installation. Its checksum-backed, evidence-limited component inventory is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
* **Type-Safe Swift Interfaces:** Raw C pointers and manual allocations are mapped behind standard Swift classes (`DaveSession`, `DaveEncryptor`, `DaveDecryptor`).
* **High-Level Coordinator:** `DaveSessionCoordinator` is an `actor` that orchestrates the session, key ratchets, and media crypto behind one async API, exposing handshake state and `DaveDiagnostics`.
* **Persistent Signature Identity:** Passing an `authSessionId` gives the session a persisted MLS signature key pair (stored under `$XDG_CONFIG_HOME`/`~/.config` in `Discord Key Storage/`), so the client keeps a stable identity across reconnects — matching official Discord clients. Passing `nil` uses a fresh ephemeral identity per session.
* **Full-Duplex Media:** The coordinator handles both directions — `encryptDiscordAudioFrame` for outbound audio and `decryptDiscordAudioFrame(_:from:)` for inbound, with one decryptor per remote speaker kept in step with the MLS roster after every welcome/commit.
* **Discord Action Flow:** Coordinator helpers emit typed outbound actions for Discord Voice gateway messages such as MLS key packages, commit/welcome payloads, transition-ready, and invalid commit/welcome recovery.
* **Recovery Diagnostics:** Typed recovery hints, external sender state, pending epoch/transition tracking, and a media-readiness watchdog make stalled DAVE transitions visible without parsing logs.
* **Contained Concurrency:** The coordinator runs on its own dedicated serial executor, so the synchronous, blocking native MLS calls underneath can never starve the host's shared cooperative thread pool — a stalled native call stays contained to that one thread.
* **Strict-Concurrency Clean:** The package builds warning-free with strict concurrency checking enabled. The low-level wrappers (`DaveSession`, `DaveEncryptor`, `DaveDecryptor`) are intentionally **not `Sendable`** because the native state underneath is not thread-safe; serialize access through one actor or queue — the coordinator does this for you.
* **Lifecycle Management:** C++ session handles are managed automatically, freeing resources in `deinit` to prevent memory leaks.
* **Callback Routing:** C-style function pointer callbacks are bridged to standard Swift closures.

---

## Installation

> [!IMPORTANT]
> **Apple Silicon only.** The bundled framework has one `macos-arm64` slice: use it on Apple Silicon Macs running macOS 26 or later. Intel Macs and x86_64 Rosetta targets are unsupported.

**Requirements:** macOS 26+ on Apple Silicon (the bundled `Dave.xcframework` is built with a macOS 26 deployment target).

Add the dependency to your project in Xcode, or append it to your `Package.swift` manifest. Pinning to a tagged release is recommended:

```swift
dependencies: [
    .package(url: "https://github.com/johnwatso/libdave-swift.git", exact: "2.0.0")
]
```

Then add the product target `libdave-swift` as a dependency in your application:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "libdave-swift", package: "libdave-swift")
    ]
)
```

The package version is the plain SemVer Git tag (for example, `2.0.0`), not a
field inside `Package.swift`. For production deployments, pin a verified tag;
see [CHANGELOG.md](CHANGELOG.md) for behavior changes and
[Docs/MIGRATING_TO_2.0.md](Docs/MIGRATING_TO_2.0.md) for the 2.0 integration
contract, and [Docs/RELEASING.md](Docs/RELEASING.md) for release verification.

---

## Quick Start: Coordinator-First

Use `DaveSessionCoordinator` for Discord Voice. The outline below deliberately has no made-up payloads: MLS external-sender, welcome, commit, and proposal bytes must come from the real Discord Voice gateway, and every user ID must be a non-zero decimal Discord Snowflake. It is an integration shape, not a standalone encryption demo.

```swift
import Foundation
import libdave_swift

let coordinator = DaveSessionCoordinator(authSessionId: persistentSessionID)

// `guildID`, `selfUserID`, and `daveVersion` are supplied by your Discord
// Voice session. `selfUserID` is a decimal Snowflake string.
let configured = try await coordinator.configureDiscordVoiceSession(
    groupId: guildID,
    selfUserId: selfUserID,
    protocolVersion: daveVersion
)
try await sendToVoiceGateway(configured.outboundActions)

// Use the replay-safe gateway-event API. Its action envelopes stay pending
// until the WebSocket write succeeds and each one is acknowledged.
func deliver(_ result: DiscordDaveGatewayResult) async throws {
    for envelope in result.pendingActions {
        try await sendToVoiceGateway(envelope.action)
        await coordinator.acknowledgeDiscordGatewayAction(envelope.id)
    }
}

// Supply the serialized external sender exactly as received from Discord.
// This queues the initial key package; there is no safe fallback before it.
let registered = try await coordinator.consumeDiscordGatewayEvent(
    .externalSender(externalSenderBytes)
)
try await deliver(registered)

// On a gateway Welcome, pass the serialized Welcome and its numeric roster IDs.
let transition = try await coordinator.consumeDiscordGatewayEvent(
    .welcome(
        welcomeBytes,
        transitionId: transitionID,
        recognizedUserIds: rosterSnowflakeIDs
    )
)
try await deliver(transition) // sends Transition Ready or recovery actions

// Wait for Discord's matching Execute Transition event. Do not process media first.
let executed = try await coordinator.consumeDiscordGatewayEvent(
    .executeTransition(transitionID)
)
try await deliver(executed)
guard executed.mediaReady else { throw DaveError.mediaNotReady }

// Only now: encrypt outbound Opus before RTP packetization, and decrypt inbound payloads.
let ciphertext = try await coordinator.encryptDiscordAudioFrame(opusFrame, ssrc: audioSSRC)
let plaintext = try await coordinator.decryptDiscordAudioFrame(incomingEncryptedPayload, from: remoteSnowflakeID)
```

`sendToVoiceGateway(_:)` is your adapter for `DiscordDaveOutboundAction`: map `.mlsKeyPackage`, `.mlsCommitWelcome`, `.transitionReady`, and `.invalidCommitWelcome` to the corresponding Voice gateway opcodes. On a failed write, do **not** acknowledge the envelope: ask `pendingDiscordGatewayActions()` for the same ordered bytes after reconnect. Commits and epoch preparation use the same `consumeDiscordGatewayEvent(_:)` flow. Handle `result.recoveryHint` and `result.needsRecovery`; the coordinator returns the ordered invalid-transition recovery actions when applicable.

The coordinator rejects media before the matching Execute Transition by throwing `DaveError.mediaNotReady`. If a frame races a later MLS transition, treat its `.retryLater` recovery hint as a drop-and-continue condition. For an established group, send Discord's Prepare Epoch as `.prepareEpoch(protocolVersion:epoch:transitionId:)`; deliver its `.transitionReady(transitionID)` action, then wait for the matching `.executeTransition(transitionID)` before outbound media switches to the staged epoch.

> [!WARNING]
> The C setter for an external sender returns `void`, but the coordinator drains a native failure reported synchronously through its callback and throws `DaveError.externalSenderRejected` before it can issue a key package. A later native failure still fails the session closed. Successful registration is not a substitute for a genuine end-to-end MLS fixture; see the [MLS integration fixture contract](Docs/MLS_INTEGRATION_FIXTURES.md).

---

## Architecture

The repository contains:
1. **`Frameworks/Dave.xcframework`**: Merged static libraries for macOS (arm64).
2. **`CDave` Target**: Maps low-level C headers (`dave.h`) to a system module map.
3. **`libdave-swift` Target**: The Swift module containing the public API and closure bridging wrappers. Import it in Swift as `libdave_swift`, because Swift module names cannot contain hyphens. It layers a high-level `DaveSessionCoordinator` (`Coordination/`) over the low-level `DaveSession`/`DaveEncryptor`/`DaveDecryptor` wrappers (`Core/`); most integrations should prefer the coordinator.

---

## Rebuilding the Framework (For Authors)

If the underlying C++ library changes and you need to regenerate the static framework binary, you can run the helper script in the core C++ repository:
* Script Path: `libdave/cpp/build_xcframework.sh`

```bash
cd libdave/cpp
bash build_xcframework.sh
```
It will re-merge the static libraries, rebuild `Dave.xcframework`, and update the `libdave-swift/Frameworks/` directory. Commit the updated framework to push changes live.
