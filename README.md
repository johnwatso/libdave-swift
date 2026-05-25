# libdave-swift

A Swift Package wrapping **Discord's Audio & Video End-to-End Encryption (DAVE) Protocol**. 

This package was developed to support **`swiftbot`** with native end-to-end encryption capabilities on Apple platforms.

---

> [!NOTE]
> **Development Note**
> This Swift Package was generated with the assistance of an AI coding agent. While the codebase compiles successfully, passes its initial unit tests, and implements standard memory-safe wrappers, it is recommended to perform standard validation and testing before deploying in production environments.

---

## Features

* **Self-Contained Integration:** All C++ core logic, Cisco's MLS library (`mlspp`), and OpenSSL 3.0 are statically precompiled into a unified `Dave.xcframework`. No external build tools (like CMake or vcpkg) are required by client applications.
* **Type-Safe Swift Interfaces:** Raw C pointers and manual allocations are mapped behind standard Swift classes (`DaveSession`, `DaveEncryptor`, `DaveDecryptor`).
* **Lifecycle Management:** C++ session handles are managed automatically, freeing resources in `deinit` to prevent memory leaks.
* **Callback Routing:** C-style function pointer callbacks are bridged to standard Swift closures.

---

## Installation

Add the dependency to your project in Xcode, or append it to your `Package.swift` manifest:

```swift
dependencies: [
    .package(url: "https://github.com/johnwatso/libdave-swift.git", branch: "main")
]
```

Then add the product target `LibDave` as a dependency in your application:

```swift
.target(
    name: "MyTarget",
    dependencies: ["LibDave"]
)
```

---

## Quick Start Guide

Here is a basic example of how to initialize a session and process frames:

```swift
import Foundation
import LibDave

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
1. **`Frameworks/Dave.xcframework`**: Merged static libraries for Apple platforms.
2. **`CDave` Target**: Maps low-level C headers (`dave.h`) to a system module map.
3. **`LibDave` Target**: The Swift API and closure bridging wrappers.

---

## Rebuilding the Framework (For Authors)

If the underlying C++ library changes and you need to regenerate the static framework binary, you can run the helper script in the core C++ repository:
* Script Path: `libdave/cpp/build_xcframework.sh`

```bash
cd libdave/cpp
bash build_xcframework.sh
```
It will re-merge the static libraries, rebuild `Dave.xcframework`, and update the `libdave-swift/Frameworks/` directory. Commit the updated framework to push changes live.
