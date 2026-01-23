//
//  ScriptDebugger.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import JavaScriptCore
import TraceCore

public struct ScriptDebugger {
    public struct ConsoleMessage: Sendable {
        public var level: LogLevel
        public var message: String
        public var timestamp: Date

        public init(level: LogLevel, message: String, timestamp: Date = Date()) {
            self.level = level
            self.message = message
            self.timestamp = timestamp
        }
    }

    public struct ScriptErrorInfo: Sendable {
        public var message: String
        public var stack: String?
        public var lineNumber: Int?
    }

    public init() {}

    public func captureConsoleLogs(_ script: String) -> [ConsoleMessage] {
        guard let context = JSContext() else { return [] }
        let console = DebugConsole()
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        _ = context.evaluateScript(script)
        return console.messages
    }

    public func captureErrors(_ script: String) -> [ScriptErrorInfo] {
        guard let context = JSContext() else { return [] }
        var errors: [ScriptErrorInfo] = []
        context.exceptionHandler = { _, exception in
            if let exception {
                let lineValue = exception.forProperty("line")
                let lineNumber = lineValue.map { Int($0.toInt32()) }
                errors.append(ScriptErrorInfo(
                    message: exception.toString() ?? "Unknown error",
                    stack: exception.forProperty("stack")?.toString(),
                    lineNumber: lineNumber
                ))
            }
        }
        _ = context.evaluateScript(script)
        return errors
    }
}

@objc private protocol DebugConsoleExports: JSExport {
    func log(_ message: String)
    func error(_ message: String)
    func warn(_ message: String)
    func info(_ message: String)
}

@objc private final class DebugConsole: NSObject, DebugConsoleExports {
    var messages: [ScriptDebugger.ConsoleMessage] = []

    func log(_ message: String) {
        messages.append(.init(level: .debug, message: message))
    }

    func error(_ message: String) {
        messages.append(.init(level: .error, message: message))
    }

    func warn(_ message: String) {
        messages.append(.init(level: .warning, message: message))
    }

    func info(_ message: String) {
        messages.append(.init(level: .info, message: message))
    }
}
