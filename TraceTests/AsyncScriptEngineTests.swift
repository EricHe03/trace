//
//  AsyncScriptEngineTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import JavaScriptCore
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

@MainActor
final class AsyncScriptEngineTests: XCTestCase {

    var engine: AsyncScriptEngine!

    override func setUp() async throws {
        try await super.setUp()
        engine = AsyncScriptEngine()
    }

    override func tearDown() async throws {
        engine = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        // Arrange & Act
        let engine = AsyncScriptEngine()

        // Assert
        XCTAssertNotNil(engine)
    }

    func testInitializationFailure() {
        // Note: JSContext() can return nil in some cases
        // This test documents expected behavior
        let engine = AsyncScriptEngine()
        XCTAssertNotNil(engine, "Engine should initialize successfully in normal conditions")
    }

    // MARK: - Simple Script Execution Tests

    func testExecuteSimpleScript() async throws {
        // Arrange
        let script = "1 + 1"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 2)
    }

    func testExecuteScriptWithStringReturn() async throws {
        // Arrange
        let script = "'hello world'"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "hello world")
    }

    func testExecuteScriptWithBooleanReturn() async throws {
        // Arrange
        let script = "true"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.toBool())
    }

    func testExecuteScriptWithNumberReturn() async throws {
        // Arrange
        let script = "42.5"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toDouble(), 42.5, accuracy: 0.001)
    }

    func testExecuteScriptWithArrayReturn() async throws {
        // Arrange
        let script = "[1, 2, 3]"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.isArray)
        XCTAssertEqual(result.toArray().count, 3)
    }

    func testExecuteScriptWithObjectReturn() async throws {
        // Arrange
        let script = "({ key: 'value', number: 42 })"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.isObject)
        if let dict = result.toDictionary() as? [String: Any] {
            XCTAssertEqual(dict["key"] as? String, "value")
            XCTAssertEqual(dict["number"] as? Int, 42)
        } else {
            XCTFail("Failed to convert result to dictionary")
        }
    }

    // MARK: - Async Script Execution Tests

    func testExecuteAsyncScriptWithAwait() async throws {
        // Arrange
        let script = """
        await new Promise(resolve => {
            setTimeout(() => resolve(42), 10);
        });
        return 42;
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
    }

    func testExecuteAsyncScriptWithPromise() async throws {
        // Arrange
        let script = "return Promise.resolve(100);"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 100)
    }

    func testExecuteAsyncScriptWithDelayedPromise() async throws {
        // Arrange
        let script = """
        return new Promise(resolve => {
            setTimeout(() => resolve('completed'), 50);
        });
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "completed")
    }

    func testExecuteAsyncScriptWithMultipleAwaits() async throws {
        // Arrange
        let script = """
        const a = await Promise.resolve(10);
        const b = await Promise.resolve(20);
        return a + b;
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 30)
    }

    // MARK: - Error Handling Tests

    func testExecuteInvalidScript() async throws {
        // Arrange
        let script = "this is not valid javascript }{"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error for invalid script")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed:
                XCTAssertTrue(true)
            case .invalidScript:
                XCTAssertTrue(true)
            default:
                XCTFail("Unexpected error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExecuteScriptWithRuntimeError() async throws {
        // Arrange
        let script = "throw new Error('Test error');"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed(let message):
                XCTAssertTrue(message.contains("Error"))
            default:
                XCTFail("Unexpected error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExecuteScriptWithUndefinedVariable() async throws {
        // Arrange
        let script = "undefinedVariable.someMethod();"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error for undefined variable")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed:
                XCTAssertTrue(true)
            default:
                XCTFail("Unexpected error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExecuteScriptWithSyntaxError() async throws {
        // Arrange
        let script = "const x = ;"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error for syntax error")
        } catch {
            XCTAssertTrue(error is ScriptError)
        }
    }

    func testExecuteScriptWithRejectedPromise() async throws {
        // Arrange
        let script = "return Promise.reject('rejected');"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error for rejected promise")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed(let message):
                XCTAssertTrue(message.contains("rejected"))
            default:
                XCTFail("Unexpected error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExecuteScriptWithAsyncError() async throws {
        // Arrange
        let script = """
        return new Promise((resolve, reject) => {
            setTimeout(() => reject('async error'), 10);
        });
        """
        let timeout: TimeInterval = 1.0

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should throw error for async error")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed(let message):
                XCTAssertTrue(message.contains("async error"))
            default:
                XCTFail("Unexpected error type")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Timeout Tests

    func testExecuteScriptWithTimeout() async throws {
        // Arrange
        let script = """
        return new Promise(resolve => {
            setTimeout(() => resolve('done'), 2000);
        });
        """
        let timeout: TimeInterval = 0.1

        // Act & Assert
        do {
            _ = try await engine.executeAsync(script, timeout: timeout)
            XCTFail("Should timeout")
        } catch let error as ScriptError {
            switch error {
            case .executionFailed(let message):
                XCTAssertTrue(message.contains("timeout") || message.contains("timed out"))
            default:
                XCTFail("Should be execution failed error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExecuteScriptWithZeroTimeout() async throws {
        // Arrange
        let script = "return 42;"
        let timeout: TimeInterval = 0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 42)
    }

    func testExecuteScriptWithNegativeTimeout() async throws {
        // Arrange
        let script = "return 42;"
        let timeout: TimeInterval = -1

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert - Negative timeout should be treated as no timeout
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 42)
    }

    func testExecuteScriptWithLongTimeout() async throws {
        // Arrange
        let script = "return 42;"
        let timeout: TimeInterval = 10.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 42)
    }

    // MARK: - Console API Tests

    func testConsoleLogAvailable() async throws {
        // Arrange
        let script = """
        console.log('test message');
        return 'done';
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "done")
    }

    func testConsoleErrorAvailable() async throws {
        // Arrange
        let script = """
        console.error('error message');
        return 'done';
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "done")
    }

    func testConsoleWarnAvailable() async throws {
        // Arrange
        let script = """
        console.warn('warning message');
        return 'done';
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "done")
    }

    func testConsoleInfoAvailable() async throws {
        // Arrange
        let script = """
        console.info('info message');
        return 'done';
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "done")
    }

    // MARK: - Complex Script Tests

    func testExecuteScriptWithFunctionDeclaration() async throws {
        // Arrange
        let script = """
        function add(a, b) {
            return a + b;
        }
        return add(10, 20);
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 30)
    }

    func testExecuteScriptWithArrowFunction() async throws {
        // Arrange
        let script = """
        const multiply = (a, b) => a * b;
        return multiply(5, 6);
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 30)
    }

    func testExecuteScriptWithLoops() async throws {
        // Arrange
        let script = """
        let sum = 0;
        for (let i = 1; i <= 10; i++) {
            sum += i;
        }
        return sum;
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 55)
    }

    func testExecuteScriptWithConditionals() async throws {
        // Arrange
        let script = """
        const value = 10;
        if (value > 5) {
            return 'greater';
        } else {
            return 'lesser';
        }
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "greater")
    }

    func testExecuteScriptWithArrayMethods() async throws {
        // Arrange
        let script = """
        const numbers = [1, 2, 3, 4, 5];
        return numbers.map(n => n * 2).reduce((a, b) => a + b, 0);
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 30) // (2+4+6+8+10)
    }

    func testExecuteScriptWithJSON() async throws {
        // Arrange
        let script = """
        const obj = { name: 'test', value: 42 };
        const json = JSON.stringify(obj);
        const parsed = JSON.parse(json);
        return parsed.value;
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 42)
    }

    // MARK: - Edge Cases

    func testExecuteEmptyScript() async throws {
        // Arrange
        let script = ""
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
    }

    func testExecuteScriptWithOnlyComments() async throws {
        // Arrange
        let script = """
        // This is a comment
        /* This is a
           multi-line comment */
        """
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
    }

    func testExecuteScriptWithUnicodeCharacters() async throws {
        // Arrange
        let script = "return '你好世界 🌍';"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toString(), "你好世界 🌍")
    }

    func testExecuteScriptWithEscapedStrings() async throws {
        // Arrange
        let script = "return 'Line 1\\nLine 2\\tTabbed';"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.toString()?.contains("\n") ?? false)
    }

    func testExecuteScriptWithLargeNumber() async throws {
        // Arrange
        let script = "return 999999999999999;"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result.toDouble(), 0)
    }

    func testExecuteScriptWithNull() async throws {
        // Arrange
        let script = "return null;"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.isNull)
    }

    func testExecuteScriptWithUndefined() async throws {
        // Arrange
        let script = "return undefined;"
        let timeout: TimeInterval = 1.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertTrue(result.isUndefined)
    }

    // MARK: - Concurrency Tests

    func testExecuteMultipleScriptsConcurrently() async throws {
        // Arrange
        let script1 = "return 1;"
        let script2 = "return 2;"
        let script3 = "return 3;"
        let timeout: TimeInterval = 1.0

        // Act
        async let result1 = engine.executeAsync(script1, timeout: timeout)
        async let result2 = engine.executeAsync(script2, timeout: timeout)
        async let result3 = engine.executeAsync(script3, timeout: timeout)

        let results = try await [result1, result2, result3]

        // Assert
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Memory Tests

    func testExecuteScriptMultipleTimes() async throws {
        // Arrange
        let script = "return 42;"
        let timeout: TimeInterval = 1.0

        // Act & Assert
        for _ in 0..<10 {
            let result = try await engine.executeAsync(script, timeout: timeout)
            XCTAssertEqual(result.toInt32(), 42)
        }
    }

    func testExecuteScriptWithLargeDataStructure() async throws {
        // Arrange
        let script = """
        const largeArray = Array.from({ length: 1000 }, (_, i) => i);
        return largeArray.length;
        """
        let timeout: TimeInterval = 2.0

        // Act
        let result = try await engine.executeAsync(script, timeout: timeout)

        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result.toInt32(), 1000)
    }
}
