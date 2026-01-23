//
//  FeatureLog.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/11.
//
//

import OSLog
import TraceCore

// MARK: - Features Module Logging

/// Features module logging namespace following Trace Logging Standard v1.0
///
/// **Subsystem:** `com.trace.TraceFeatures`
///
/// ## Categories
/// | Logger | Category | Use Case |
/// |--------|----------|----------|
/// | `capture` | Feature.Capture | Request capture operations |
/// | `rewrite` | Feature.Rewrite | Request/response rewriting |
/// | `script` | Feature.Script | JavaScript scripting |
/// | `breakpoint` | Feature.Breakpoint | Breakpoint debugging |
/// | `hosts` | Feature.Hosts | Hosts file management |
/// | `export` | Feature.Export | HAR/cURL export |
/// | `vpn` | Feature.VPN | VPN management from app |
/// | `profile` | Feature.Profile | Profile management |
/// | `rulePack` | Feature.RulePack | Rule pack import/export |
///
/// ## Usage
/// ```swift
/// // Request capture
/// FeatureLog.capture.info("event=capture.request_stored id=\(requestId, privacy: .public) size=\(size)")
///
/// // Rewrite rules
/// FeatureLog.rewrite.info("event=rewrite.rule_applied rule_id=\(ruleId, privacy: .public) type=\(type, privacy: .public)")
///
/// // Script execution
/// FeatureLog.script.debug("event=script.execute script_id=\(scriptId, privacy: .public)")
/// FeatureLog.script.error("event=script.error outcome=failure script_id=\(id) error=\(error, privacy: .public)")
/// ```
///
/// ## Console Filtering
/// ```
/// subsystem:com.trace.TraceFeatures category:Feature.Capture
/// ```
public enum FeatureLog {
    /// Request capture operations
    ///
    /// Log levels:
    /// - `.info`: Request stored, session started/stopped
    /// - `.error`: Storage failed
    /// - `.debug`: Individual capture events
    public static let capture = TraceLog.make(
        module: .features,
        category: .featureCapture
    )

    /// Request/response rewriting
    ///
    /// Log levels:
    /// - `.info`: Rule applied, configuration changed
    /// - `.warning`: Rule matched but modification failed
    /// - `.debug`: Rule evaluation details
    public static let rewrite = TraceLog.make(
        module: .features,
        category: .featureRewrite
    )

    /// JavaScript scripting
    ///
    /// Log levels:
    /// - `.info`: Script executed successfully
    /// - `.warning`: Script returned unexpected result
    /// - `.error`: Script execution failed
    /// - `.debug`: Script input/output (sanitized)
    public static let script = TraceLog.make(
        module: .features,
        category: .featureScript
    )

    /// Breakpoint debugging
    ///
    /// Log levels:
    /// - `.info`: Breakpoint hit, resumed
    /// - `.debug`: Breakpoint evaluation
    public static let breakpoint = TraceLog.make(
        module: .features,
        category: .featureBreakpoint
    )

    /// Hosts file management
    ///
    /// Log levels:
    /// - `.info`: Hosts entry added/removed
    /// - `.debug`: DNS override applied
    public static let hosts = TraceLog.make(
        module: .features,
        category: .featureHosts
    )

    /// Data export (HAR, cURL, etc.)
    ///
    /// Log levels:
    /// - `.info`: Export complete
    /// - `.error`: Export failed
    /// - `.debug`: Export progress
    public static let export = TraceLog.make(
        module: .features,
        category: .featureExport
    )

    /// VPN management from main app
    ///
    /// Log levels:
    /// - `.info`: VPN started/stopped
    /// - `.error`: VPN operation failed
    /// - `.debug`: VPN status checks
    public static let vpn = TraceLog.make(
        module: .features,
        category: .featureVPN
    )

    /// Request mapping/mocking
    ///
    /// Log levels:
    /// - `.info`: Map matched, mock response served
    /// - `.error`: Mock response generation failed
    /// - `.debug`: Map evaluation details
    public static let requestMap = TraceLog.make(
        module: .features,
        category: .featureRequestMap
    )

    /// Profile management
    ///
    /// Log levels:
    /// - `.info`: Profile created/activated
    /// - `.error`: Profile persistence failed
    public static let profile = TraceLog.make(
        module: .features,
        category: .featureProfile
    )

    /// Rule pack management
    ///
    /// Log levels:
    /// - `.info`: Import/export success
    /// - `.error`: Import/export failure
    public static let rulePack = TraceLog.make(
        module: .features,
        category: .featureRulePack
    )

    /// Notifications
    ///
    /// Log levels:
    /// - `.info`: Notification sent, user action received
    /// - `.error`: Notification delivery failed
    /// - `.debug`: Notification scheduling details
    public static let notification = TraceLog.make(
        module: .features,
        category: .featureNotification
    )

    /// Data storage and cleanup
    ///
    /// Log levels:
    /// - `.info`: Cleanup completed, storage limits enforced
    /// - `.warning`: Storage limit exceeded
    /// - `.error`: Cleanup operation failed
    /// - `.debug`: Cleanup progress details
    public static let storage = TraceLog.make(
        module: .features,
        category: .featureStorage
    )

    /// Widget operations
    ///
    /// Log levels:
    /// - `.info`: Live Activity started/ended
    /// - `.error`: Widget update failed
    /// - `.debug`: Widget data updates
    public static let widget = TraceLog.make(
        module: .features,
        category: .widget
    )
}

// MARK: - Feature Event Domains

/// Pre-defined event builders for common feature operations
public extension LogEvent {
    /// Create a capture event
    /// - Parameter action: The action (e.g., "request_stored", "session_start", "cleanup")
    static func capture(_ action: String) -> LogEvent {
        LogEvent(domain: "capture", action: action)
    }

    /// Create a rewrite event
    /// - Parameter action: The action (e.g., "rule_applied", "rule_matched", "config_load")
    static func rewrite(_ action: String) -> LogEvent {
        LogEvent(domain: "rewrite", action: action)
    }

    /// Create a script event
    /// - Parameter action: The action (e.g., "execute", "compile", "timeout")
    static func script(_ action: String) -> LogEvent {
        LogEvent(domain: "script", action: action)
    }

    /// Create a breakpoint event
    /// - Parameter action: The action (e.g., "hit", "resume", "config_load")
    static func breakpoint(_ action: String) -> LogEvent {
        LogEvent(domain: "breakpoint", action: action)
    }

    /// Create a hosts event
    /// - Parameter action: The action (e.g., "entry_added", "match_found", "config_load")
    static func hosts(_ action: String) -> LogEvent {
        LogEvent(domain: "hosts", action: action)
    }

    /// Create an export event
    /// - Parameter action: The action (e.g., "har_export", "csv_export", "import")
    static func export(_ action: String) -> LogEvent {
        LogEvent(domain: "export", action: action)
    }

    /// Create a VPN event (from app)
    /// - Parameter action: The action (e.g., "start", "stop", "status_change")
    static func vpn(_ action: String) -> LogEvent {
        LogEvent(domain: "vpn", action: action)
    }

    /// Create a request map event
    /// - Parameter action: The action (e.g., "match_found", "mock_served", "config_load")
    static func requestMap(_ action: String) -> LogEvent {
        LogEvent(domain: "request_map", action: action)
    }

    /// Create a notification event
    /// - Parameter action: The action (e.g., "sent", "action_received", "authorization")
    static func notification(_ action: String) -> LogEvent {
        LogEvent(domain: "notification", action: action)
    }

    /// Create a storage event
    /// - Parameter action: The action (e.g., "cleanup_start", "cleanup_complete", "limit_exceeded")
    static func storage(_ action: String) -> LogEvent {
        LogEvent(domain: "storage", action: action)
    }

    /// Create a widget event
    /// - Parameter action: The action (e.g., "live_activity_start", "update", "action_handled")
    static func widget(_ action: String) -> LogEvent {
        LogEvent(domain: "widget", action: action)
    }
}
