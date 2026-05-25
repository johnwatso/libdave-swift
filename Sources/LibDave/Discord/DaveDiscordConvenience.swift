import Foundation

/// Represents the transition states in the Discord Voice MLS protocol.
public enum DiscordTransition: Sendable {
    /// Join a group by processing a Welcome message.
    /// Parameters:
    ///   - welcomeData: Serialized MLS welcome message bytes.
    ///   - recognizedUserIds: Roster user IDs recognized by the client.
    case welcome(Data, recognizedUserIds: [String])

    /// Advance the MLS epoch by processing an incoming Commit message.
    /// Parameters:
    ///   - commitData: Serialized MLS commit message bytes.
    case commit(Data)
}
