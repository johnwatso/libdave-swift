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

* **Self-Contained Integration:** All C++ core logic, Cisco's MLS library (`mlspp`), and OpenSSL 3.0 are statically precompiled into a unified `Dave.xcframework`. No external build tools (like CMake or vcpkg) are required by client applications.
* **Type-Safe Swift Interfaces:** Raw C pointers and manual allocations are mapped behind standard Swift classes (`DaveSession`, `DaveEncryptor`, `DaveDecryptor`).
* **High-Level Coordinator:** `DaveSessionCoordinator` is an `actor` that orchestrates the session, key ratchets, and encryptor behind one async API, exposing handshake state and `DaveDiagnostics`.
* **Contained Concurrency:** The coordinator runs on its own dedicated serial executor, so the synchronous, blocking native MLS calls underneath can never starve the host's shared cooperative thread pool — a stalled native call stays contained to that one thread.
* **Lifecycle Management:** C++ session handles are managed automatically, freeing resources in `deinit` to prevent memory leaks.
* **Callback Routing:** C-style function pointer callbacks are bridged to standard Swift closures.

---

## Installation

**Requirements:** macOS 26+ (the bundled `Dave.xcframework` is built with a macOS 26 deployment target).

Add the dependency to your project in Xcode, or append it to your `Package.swift` manifest. Pinning to a tagged release is recommended:

```swift
dependencies: [
    .package(url: "https://github.com/johnwatso/libdave-swift.git", from: "1.1.0")
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

---

## Quick Start Guide

The example below uses the low-level wrappers to show the raw session/encrypt/decrypt flow. For application integration, prefer the high-level `DaveSessionCoordinator`, which manages session lifecycle, ratchet transitions, and diagnostics behind one async API.

```swift
import Foundation
import libdave_swift

do {
    // 1. Initialize a secure DAVE Session
    let session = try DaveSession { source, reason in
        print("MLS failure in \(source): \(reason)")
    }
    
    // Initialize the session with version, group ID, and local user ID
    session.initialize(version: 1, groupId: 998877, selfUserId: "swiftbot-client")
    print("Session initialized. Protocol version: \(session.protocolVersion)")

    // 2. Create a Media Frame Encryptor
    let encryptor = try DaveEncryptor()
    
    // Assign synchronization source (SSRC) to standard Opus audio codec
    let audioSsrc: UInt32 = 112233
    encryptor.assignSsrcToCodec(ssrc: audioSsrc, codec: .opus)

    // Retrieve the user's key ratchet and set it on the encryptor
    if let keyRatchet = session.getKeyRatchet(userId: "swiftbot-client") {
        encryptor.setKeyRatchet(keyRatchet)
    }

    // 3. Encrypt an Audio Frame
    let rawAudioFrame = Data([0x01, 0x02, 0x03, 0x04])
    
    let encryptedFrame = try encryptor.encrypt(
        mediaType: .audio,
        ssrc: audioSsrc,
        frame: rawAudioFrame
    )
    print("Encrypted \(rawAudioFrame.count) bytes into \(encryptedFrame.count) bytes")

    // 4. Create a Media Frame Decryptor
    let decryptor = try DaveDecryptor()
    
    if let receiverRatchet = session.getKeyRatchet(userId: "swiftbot-client") {
        decryptor.transitionToKeyRatchet(receiverRatchet)
    }

    // Decrypt the payload back to plaintext
    let decryptedFrame = try decryptor.decrypt(
        mediaType: .audio,
        encryptedFrame: encryptedFrame
    )
    print("Decrypted payload: \(decryptedFrame.map { String(format: "%02hhx", $0) }.joined())")

} catch {
    print("DAVE Protocol Error: \(error.localizedDescription)")
}
```

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
