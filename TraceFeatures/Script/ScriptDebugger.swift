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
    func log(_ message: JSValue)
    func error(_ message: JSValue)
    func warn(_ message: JSValue)
    func info(_ message: JSValue)
}

@objc private final class DebugConsole: NSObject, DebugConsoleExports {
    var messages: [ScriptDebugger.ConsoleMessage] = []

    func log(_ message: JSValue) {
        messages.append(.init(level: .debug, message: stringify(message)))
    }

    func error(_ message: JSValue) {
        messages.append(.init(level: .error, message: stringify(message)))
    }

    func warn(_ message: JSValue) {
        messages.append(.init(level: .warning, message: stringify(message)))
    }

    func info(_ message: JSValue) {
        messages.append(.init(level: .info, message: stringify(message)))
    }

    private func stringify(_ value: JSValue) -> String {
        if value.isNull {
            return "null"
        }
        if value.isUndefined {
            return "undefined"
        }
        if value.isString || value.isNumber || value.isBoolean {
            return value.toString()
        }

        if let context = value.context,
           let json = context.objectForKeyedSubscript("JSON"),
           let stringify = json.objectForKeyedSubscript("stringify"),
           let jsonString = stringify.call(withArguments: [value])?.toString(),
           jsonString != "undefined" {
            return jsonString
        }

        return value.toString()
    }
}
