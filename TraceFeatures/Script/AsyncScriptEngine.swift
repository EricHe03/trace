//
//  AsyncScriptEngine.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import JavaScriptCore
import TraceCore

extension JSValue: @unchecked Sendable {}

@MainActor
public final class AsyncScriptEngine {
    private let context: JSContext
    private var lastError: String?
    private var nextTimerId: Int = 1
    private var timers: [Int: DispatchWorkItem] = [:]

    public init?() {
        guard let jsContext = JSContext() else { return nil }
        context = jsContext
        context.exceptionHandler = { [weak self] _, exception in
            if let exception {
                self?.lastError = exception.toString()
            }
        }
        configureContext(context)
    }

    public func executeAsync(_ script: String, timeout: TimeInterval) async throws -> JSValue {
        lastError = nil
        cancelAllTimers()
        defer { cancelAllTimers() }

        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let isExpressionOnly = shouldWrapAsExpression(trimmed)

        let wrapped = if isExpressionOnly {
            "(async function(){ return (\(trimmed)); })()"
        } else {
            "(async function(){ \(script) })()"
        }

        guard let value = context.evaluateScript(wrapped) else {
            throw ScriptError.invalidScript
        }

        if let error = lastError {
            throw ScriptError.executionFailed(error)
        }

        if value.isObject, value.hasProperty("then") {
            return try await awaitPromise(value, timeout: timeout)
        }

        return value
    }

    private func awaitPromise(_ promise: JSValue, timeout: TimeInterval) async throws -> JSValue {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            func resumeSuccess(_ value: JSValue) {
                guard !completed else { return }
                completed = true
                continuation.resume(returning: value)
            }
            func resumeFailure(_ error: Error) {
                guard !completed else { return }
                completed = true
                continuation.resume(throwing: error)
            }
            let resolve: @convention(block) (JSValue) -> Void = { value in
                Task { @MainActor in
                    resumeSuccess(value)
                }
            }
            let reject: @convention(block) (JSValue) -> Void = { error in
                Task { @MainActor in
                    resumeFailure(ScriptError.executionFailed(error.toString() ?? "Promise rejected"))
                }
            }
            promise.invokeMethod("then", withArguments: [resolve])
            promise.invokeMethod("catch", withArguments: [reject])

            if timeout > 0 {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    resumeFailure(ScriptError.executionFailed("Script timed out"))
                }
            }
        }
    }

    private func configureContext(_ context: JSContext) {
        let console = ConsoleAPI()
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, milliseconds in
            guard let self else { return 0 }
            let timerId = self.nextTimerId
            self.nextTimerId += 1

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                _ = callback.call(withArguments: [])
                self.timers[timerId] = nil
            }

            self.timers[timerId] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + (milliseconds / 1000.0), execute: workItem)
            return timerId
        }

        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] timerId in
            guard let self else { return }
            if let workItem = self.timers[timerId] {
                workItem.cancel()
                self.timers[timerId] = nil
            }
        }

        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
    }

    private func cancelAllTimers() {
        for (_, workItem) in timers {
            workItem.cancel()
        }
        timers.removeAll(keepingCapacity: true)
    }

    private func shouldWrapAsExpression(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("\n"), !trimmed.contains(";") else { return false }

        let start = trimmed.drop(while: { $0.isWhitespace })
        guard let first = start.first else { return false }

        if first.isLetter || first == "_" || first == "$" {
            let firstWord = String(start.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }).lowercased()
            let statementKeywords: Set<String> = [
                "await", "break", "class", "const", "continue", "debugger", "do", "export", "for",
                "function", "if", "import", "let", "return", "switch", "throw", "try", "var", "while"
            ]
            if statementKeywords.contains(firstWord) {
                return false
            }
        }

        // If the user wrote an explicit return/await anywhere, treat it as a script body.
        if trimmed.contains("return ") || trimmed.hasPrefix("return") { return false }
        if trimmed.contains("await ") || trimmed.hasPrefix("await") { return false }

        return true
    }
}
