# libdave-swift

A premium, object-oriented, and memory-safe Swift Package wrapping **Discord's Audio & Video End-to-End Encryption (DAVE) Protocol**. 

Developed specifically to empower **`swiftbot`** with high-performance end-to-end encryption without requiring any platform dependencies.

---

> [!WARNING]
> **Vibe Coding Disclaimer 🎵**
> This repository was fully vibe-coded by an AI coding assistant. While it is built on robust, enterprise-grade Swift memory-management architectures, maps callbacks safely, compiles flawlessly, and passes its automated unit tests with flying colors, please treat it with lighthearted developer caution. Consider this an FYI for any downstream production applications!

---

## 🚀 Key Features

* **Zero-Dependency Integration:** All C++ core code, Cisco's MLS library (`mlspp`), and OpenSSL 3.0 are statically precompiled into a unified `Dave.xcframework`. **No Homebrew, CMake, or vcpkg are required by developers or end-users consuming this package.**
* **Type-Safe Swift Interfaces:** Raw C pointers, manual allocations, and callback bridges are hidden behind safe, Swifty models and classes (`DaveSession`, `DaveEncryptor`, `DaveDecryptor`).
* **Automatic Memory Management:** Internal C++ handles are cleaned up automatically in Swift's `deinit` method, avoiding standard C++ pointer leaks.
* **Flawless Closure Routing:** C-style function pointer callbacks are bridged natively to standard Swift closures.

---

## 🛠️ Installation

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

## 📖 Quick Start Guide

Here is how easily you can use the package inside `swiftbot`:

```swift
import Foundation
import LibDave

do {
    // 1. Initialize a secure DAVE Session
    // Any MLS protocol failures are routed directly to this Swift closure
    let session = try DaveSession { source, reason in
        print("[-] MLS failure in \(source): \(reason)")
    }
    
    // Initialize the session with protocol version, group ID, and local user ID
    session.initialize(version: 1, groupId: 998877, selfUserId: "swiftbot-client")
    print("[+] Session initialized. Protocol version: \(session.protocolVersion)")

    // 2. Create a Media Frame Encryptor
    let encryptor = try DaveEncryptor()
    
    // Assign synchronization source (SSRC) to standard Opus audio codec
    let audioSsrc: UInt32 = 112233
    encryptor.assignSsrcToCodec(ssrc: audioSsrc, codec: .opus)

    // Retrieve the user's key ratchet and set it on the encryptor
    if let keyRatchet = session.getKeyRatchet(userId: "swiftbot-client") {
        encryptor.setKeyRatchet(keyRatchet)
        print("[+] Encryptor loaded with session key ratchet")
    }

    // 3. Encrypt an Audio Frame
    let rawAudioFrame = Data([0x01, 0x02, 0x03, 0x04])
    
    // Encrypt the payload using the session's active keys
    let encryptedFrame = try encryptor.encrypt(
        mediaType: .audio,
        ssrc: audioSsrc,
        frame: rawAudioFrame
    )
    print("[+] Encrypted \(rawAudioFrame.count) bytes into \(encryptedFrame.count) bytes")

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
    print("[+] Decrypted payload: \(decryptedFrame.map { String(format: "%02hhx", $0) }.joined())")

} catch {
    print("[-] DAVE Protocol Error: \(error.localizedDescription)")
}
```

---

## 🏗️ Architecture Under the Hood

The repository contains:
1. **`Frameworks/Dave.xcframework`**: Merged static libraries for Apple platforms.
2. **`CDave` Target**: Maps low-level C headers (`dave.h`) to a system-accessible module map.
3. **`LibDave` Target**: The clean Swift classes and type-safe bridging wrappers.

---

## 🔄 Rebuilding the Framework (For Authors)

If the underlying C++ library changes and you need to regenerate the static framework binary, we have included a helper script in the core C++ repository:
* Script Path: `libdave/cpp/build_xcframework.sh`

Simply run the script on your developer machine:
```bash
cd libdave/cpp
bash build_xcframework.sh
```
It will re-merge the static libraries, rebuild `Dave.xcframework`, and automatically update your `libdave-swift/Frameworks/` directory. Commit the updated framework to push changes live!
