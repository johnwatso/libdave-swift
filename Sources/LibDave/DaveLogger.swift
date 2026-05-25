import Foundation
import CDave

/// Internal bridge class to store the global logger closure.
internal class DaveLogCallbackBridge {
    let minSeverity: DaveLoggingSeverity
    let callback: (DaveLoggingSeverity, String, Int, String) -> Void

    init(minSeverity: DaveLoggingSeverity, callback: @escaping (DaveLoggingSeverity, String, Int, String) -> Void) {
        self.minSeverity = minSeverity
        self.callback = callback
    }
}

/// Global logging manager for the DAVE library.
public class DaveLogger {
    private static var activeBridge: DaveLogCallbackBridge? = nil

    /// Sets a global callback to receive log messages from the DAVE library.
    /// - Parameters:
    ///   - minSeverity: The minimum severity level of logs to route to the callback.
    ///   - callback: A closure invoked for each log message, providing severity, source file, line number, and message.
    public static func setLogSink(
        minSeverity: DaveLoggingSeverity = .info,
        callback: @escaping (DaveLoggingSeverity, String, Int, String) -> Void
    ) {
        let bridge = DaveLogCallbackBridge(minSeverity: minSeverity, callback: callback)
        DaveLogger.activeBridge = bridge

        daveSetLogSinkCallback { severity, file, line, message in
            guard let bridge = DaveLogger.activeBridge else { return }
            let swiftSeverity = DaveLoggingSeverity(severity)
            
            // Check if log meets the minimum severity threshold
            if swiftSeverity.rawValue >= bridge.minSeverity.rawValue {
                let fileStr = file.flatMap { String(cString: $0) } ?? "Unknown"
                let messageStr = message.flatMap { String(cString: $0) } ?? ""
                bridge.callback(swiftSeverity, fileStr, Int(line), messageStr)
            }
        }
    }

    /// Disables the global logging sink and stops receiving log messages.
    public static func removeLogSink() {
        daveSetLogSinkCallback(nil)
        DaveLogger.activeBridge = nil
    }
}
