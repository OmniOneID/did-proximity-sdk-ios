/*
 * Copyright 2026 OmniOne.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import os

/// How much the SDK logs. Each level includes the ones above it.
public enum MdocLogLevel: Int, Comparable, CustomStringConvertible {
    /// Nothing is logged (default).
    case off = 0
    /// Failures that end a session.
    case error
    /// Recoverable problems — a fallback taken, a candidate transport lost, an offer refused.
    case warning
    /// Session lifecycle — state changes, engagement, the transport chosen, messages sent and received.
    case info
    /// Link-level detail — candidate transport events, transfer progress, NFC APDU status words.
    case debug

    public static func < (lhs: MdocLogLevel, rhs: MdocLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }
}

/// The part of the SDK an entry comes from. Also used as the `os.Logger` category.
public enum MdocLogCategory: String, CaseIterable {
    case session
    case engagement
    case transport
    case ble
    case nfc
    case verify
}

public struct MdocLogEntry {
    public let date: Date
    public let level: MdocLogLevel
    public let category: MdocLogCategory
    public let message: String

    /// `2026-11-06T09:12:03.120Z [INFO] [session] …`
    public var formatted: String {
        "\(MdocLogEntry.timestamp.string(from: date)) [\(level)] [\(category.rawValue)] \(message)"
    }

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The SDK logger. Off by default — the app turns it on to capture what led up to a problem.
///
/// ```swift
/// MdocLog.level = .debug
/// MdocLog.handler = { entry in myLogFile.append(entry.formatted) }
/// ```
///
/// **What is never logged:** keys, shared secrets, the SessionTranscript, message contents
/// (encrypted or not), data element values and certificates. Entries carry states, kinds, lengths and
/// status codes only, so they are safe to collect at every level.
///
/// - Entries go to Apple's unified logging (subsystem `com.omnione.mdocproximity`, visible in Console.app)
///   unless `systemLogEnabled` is `false`.
/// - `handler` is called on an SDK-internal serial queue, in the order the entries were made.
///   It never runs on the caller's thread or inside SDK locks, so it may call back into the SDK.
public enum MdocLog {

    public static let subsystem = "com.omnione.mdocproximity"

    public static var level: MdocLogLevel {
        get { storage.read { $0.level } }
        set { storage.write { $0.level = newValue } }
    }

    public static var handler: ((MdocLogEntry) -> Void)? {
        get { storage.read { $0.handler } }
        set { storage.write { $0.handler = newValue } }
    }

    /// Whether entries also go to `os.Logger`. Default `true`.
    public static var systemLogEnabled: Bool {
        get { storage.read { $0.systemLogEnabled } }
        set { storage.write { $0.systemLogEnabled = newValue } }
    }

    // MARK: - SDK side

    @_spi(MdocInternal)
    public static func isEnabled(_ level: MdocLogLevel) -> Bool {
        level != .off && level <= self.level
    }

    /// The message is built only when `level` passes, so a disabled logger costs one comparison.
    @_spi(MdocInternal)
    public static func log(_ level: MdocLogLevel, _ category: MdocLogCategory,
                           _ message: @autoclosure () -> String) {
        guard level != .off else { return }
        let (current, handler, system) = storage.read { ($0.level, $0.handler, $0.systemLogEnabled) }
        guard level <= current else { return }
        let entry = MdocLogEntry(date: Date(), level: level, category: category, message: message())
        if system { systemLog(entry) }
        if let handler { queue.async { handler(entry) } }
    }

    @_spi(MdocInternal) public static func error(_ c: MdocLogCategory, _ m: @autoclosure () -> String) { log(.error, c, m()) }
    @_spi(MdocInternal) public static func warning(_ c: MdocLogCategory, _ m: @autoclosure () -> String) { log(.warning, c, m()) }
    @_spi(MdocInternal) public static func info(_ c: MdocLogCategory, _ m: @autoclosure () -> String) { log(.info, c, m()) }
    @_spi(MdocInternal) public static func debug(_ c: MdocLogCategory, _ m: @autoclosure () -> String) { log(.debug, c, m()) }

    /// Waits until every entry made so far has reached `handler`.
    @_spi(MdocInternal)
    public static func flush() { queue.sync {} }

    // MARK: -

    private static let storage = Storage()
    private static let queue = DispatchQueue(label: "com.omnione.mdocproximity.log")
    private static let loggers: [MdocLogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: MdocLogCategory.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) })

    private static func systemLog(_ entry: MdocLogEntry) {
        guard let logger = loggers[entry.category] else { return }
        // `.public` is safe only because entries never carry sensitive data (see the type comment).
        // `.private` would show `<private>` in Console on a device in the field, defeating the purpose.
        switch entry.level {
        case .error:   logger.error("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        case .info:    logger.info("\(entry.message, privacy: .public)")
        case .debug:   logger.debug("\(entry.message, privacy: .public)")
        case .off:     break
        }
    }

    private final class Storage: @unchecked Sendable {
        struct Values {
            var level: MdocLogLevel = .off
            var handler: ((MdocLogEntry) -> Void)?
            var systemLogEnabled = true
        }
        private let lock = NSLock()
        private var values = Values()
        func read<T>(_ body: (Values) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(values) }
        func write(_ body: (inout Values) -> Void) { lock.lock(); defer { lock.unlock() }; body(&values) }
    }
}

@_spi(MdocInternal)
extension TransportEvent {
    /// The event without its payload — a message is reported by length only.
    public var logDescription: String {
        switch self {
        case .ready: return "ready"
        case .message(let d): return "message(\(d.count)B)"
        case .progress(let sent, let total): return "progress(\(sent)/\(total))"
        case .downgradedToGatt(let reason): return "downgradedToGatt(\(reason))"
        case .peerClosed(let reason): return "peerClosed(\(reason))"
        case .failed(let e): return "failed(\(e))"
        }
    }

    /// The level an event is logged at — failures and fallbacks stand out, traffic stays at debug.
    public var logLevel: MdocLogLevel {
        switch self {
        case .failed: return .error
        case .downgradedToGatt: return .warning
        case .ready, .peerClosed: return .info
        case .message, .progress: return .debug
        }
    }
}
