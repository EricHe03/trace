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
        let wrapped = "(async function(){ \(script) })()"

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
    }
}
