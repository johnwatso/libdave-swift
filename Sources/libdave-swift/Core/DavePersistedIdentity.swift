import Foundation

/// Management for the MLS signature identities that the native library
/// persists when a session is created with an `authSessionId`.
///
/// The native implementation writes one key file per identity into
/// `Discord Key Storage/` beneath `$XDG_CONFIG_HOME` (falling back to
/// `~/.config`), named after the `authSessionId` it belongs to. Those files
/// hold long-lived MLS signature private keys: they are what lets a client
/// keep a stable identity across reconnects, and anyone who can read them can
/// impersonate that identity in a DAVE group.
///
/// The native library creates the key files `0600` but leaves the containing
/// directory `0755`, which lets any local user enumerate which identities
/// exist. ``hardenStoragePermissions()`` tightens the directory to `0700` and
/// re-asserts `0600` on the key files; ``DaveSession`` calls it automatically
/// whenever a session is created with a persistent identity.
public enum DavePersistedIdentityStore {
    /// Name of the directory the native library uses inside the config home.
    private static let storageDirectoryName = "Discord Key Storage"
    /// Extension the native library gives persisted signature key files.
    private static let keyFileExtension = "key"

    /// Directory holding persisted MLS signature identities for this user.
    ///
    /// This resolves the same way the native backend does, including
    /// `XDG_CONFIG_HOME`, so it is read at call time rather than cached.
    public static var directoryURL: URL {
        let configHome: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configHome = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            configHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return configHome.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    /// Key files currently persisted, optionally narrowed to one identity.
    ///
    /// - Parameter authSessionId: When supplied, only files belonging to that
    ///   identity are returned. When `nil`, every persisted identity is listed.
    public static func identityFileURLs(authSessionId: String? = nil) -> [URL] {
        let directory = directoryURL
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        // The native backend names files "<authSessionId>-<generation>-<index>.key".
        // Match on that prefix so purging one identity cannot remove another
        // whose id merely starts with the same characters.
        let prefix = authSessionId.map { "\($0)-" }
        return names
            .filter { $0.hasSuffix(".\(keyFileExtension)") }
            .filter { prefix.map($0.hasPrefix) ?? true }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Deletes the persisted signature identity for one `authSessionId`.
    ///
    /// Call this on logout or account switch: without it, the signature key
    /// outlives the credential it was created for. The client transparently
    /// generates a new identity the next time that `authSessionId` is used.
    ///
    /// - Returns: The number of key files removed.
    @discardableResult
    public static func purge(authSessionId: String) throws -> Int {
        try validate(authSessionId: authSessionId)
        return try remove(identityFileURLs(authSessionId: authSessionId))
    }

    /// Deletes every persisted signature identity for this user account.
    ///
    /// - Returns: The number of key files removed.
    @discardableResult
    public static func purgeAll() throws -> Int {
        try remove(identityFileURLs())
    }

    /// Restricts the identity directory to the current user.
    ///
    /// Best-effort and non-throwing: a host that cannot tighten permissions
    /// (an unusual mount, a directory owned by another user) should still be
    /// able to run, and the native key files are already created `0600`.
    /// Returns whether every applicable path now has the intended mode.
    @discardableResult
    public static func hardenStoragePermissions() -> Bool {
        let fileManager = FileManager.default
        let directory = directoryURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            // Nothing persisted yet. The directory is created by native code on
            // first use, and hardening runs again on the next session creation.
            return true
        }

        var allApplied = applyPermissions(0o700, to: directory.path, using: fileManager)
        for url in identityFileURLs() {
            allApplied = applyPermissions(0o600, to: url.path, using: fileManager) && allApplied
        }
        return allApplied
    }

    /// Rejects `authSessionId` values that are unsafe as a filename component.
    ///
    /// The native backend interpolates this value straight into a path inside
    /// the key store, so a value containing a path separator or `..` would
    /// place (or delete) a key file outside the intended directory.
    internal static func validate(authSessionId: String) throws {
        let scalars = authSessionId.unicodeScalars
        guard !authSessionId.isEmpty,
              authSessionId.utf8.count <= 128,
              !authSessionId.contains("/"),
              !authSessionId.contains("\\"),
              !authSessionId.contains(".."),
              authSessionId != ".",
              !scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw DaveError.invalidAuthSessionId(authSessionId)
        }
    }

    private static func remove(_ urls: [URL]) throws -> Int {
        var removed = 0
        for url in urls {
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private static func applyPermissions(
        _ mode: Int,
        to path: String,
        using fileManager: FileManager
    ) -> Bool {
        let current = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        if current?.intValue == mode {
            return true
        }
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}
