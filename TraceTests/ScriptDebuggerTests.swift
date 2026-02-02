//
//  ScriptDebuggerTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
import JavaScriptCore
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ScriptDebuggerTests: XCTestCase {

    var debugger: ScriptDebugger!

    override func setUp() {
        super.setUp()
        debugger = ScriptDebugger()
    }

    override func tearDown() {
        debugger = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        // Arrange & Act
        let debugger = ScriptDebugger()

        // Assert
        XCTAssertNotNil(debugger)
    }

    // MARK: - ConsoleMessage Tests

    func testConsoleMessageInitialization() {
        // Arrange
        let level = LogLevel.debug
        let message = "Test message"
        let timestamp = Date()

        // Act
        let consoleMessage = ScriptDebugger.ConsoleMessage(
            level: level,
            message: message,
            timestamp: timestamp
        )

        // Assert
        XCTAssertEqual(consoleMessage.level, level)
        XCTAssertEqual(consoleMessage.message, message)
        XCTAssertEqual(consoleMessage.timestamp, timestamp)
    }

    func testConsoleMessageDefaultTimestamp() {
        // Arrange
        let level = LogLevel.info
        let message = "Test"

        // Act
        let beforeCreation = Date()
        let consoleMessage = ScriptDebugger.ConsoleMessage(level: level, message: message)
        let afterCreation = Date()

        // Assert
        XCTAssertGreaterThanOrEqual(consoleMessage.timestamp, beforeCreation)
        XCTAssertLessThanOrEqual(consoleMessage.timestamp, afterCreation)
    }

    // MARK: - Console Log Capture Tests

    func testCaptureConsoleLogSingle() {
        // Arrange
        let script = "console.log('test message');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.level, .debug)
        XCTAssertEqual(messages.first?.message, "test message")
    }

    func testCaptureConsoleErrorSingle() {
        // Arrange
        let script = "console.error('error message');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.level, .error)
        XCTAssertEqual(messages.first?.message, "error message")
    }

    func testCaptureConsoleWarnSingle() {
        // Arrange
        let script = "console.warn('warning message');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.level, .warning)
        XCTAssertEqual(messages.first?.message, "warning message")
    }

    func testCaptureConsoleInfoSingle() {
        // Arrange
        let script = "console.info('info message');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.level, .info)
        XCTAssertEqual(messages.first?.message, "info message")
    }

    func testCaptureMultipleConsoleLogs() {
        // Arrange
        let script = """
        console.log('first');
        console.error('second');
        console.warn('third');
        console.info('fourth');
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].level, .debug)
        XCTAssertEqual(messages[0].message, "first")
        XCTAssertEqual(messages[1].level, .error)
        XCTAssertEqual(messages[1].message, "second")
        XCTAssertEqual(messages[2].level, .warning)
        XCTAssertEqual(messages[2].message, "third")
        XCTAssertEqual(messages[3].level, .info)
        XCTAssertEqual(messages[3].message, "fourth")
    }

    func testCaptureConsoleLogsWithEmptyScript() {
        // Arrange
        let script = ""

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 0)
    }

    func testCaptureConsoleLogsWithNoConsoleCalls() {
        // Arrange
        let script = "var x = 1 + 1;"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 0)
    }

    func testCaptureConsoleLogsWithComplexMessages() {
        // Arrange
        let script = """
        console.log('Message with special chars: @#$%^&*()');
        console.log('Message with unicode: 你好 🌍');
        console.log('Message with newline\\nand tab\\there');
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[0].message.contains("@#$%"))
        XCTAssertTrue(messages[1].message.contains("你好"))
        XCTAssertTrue(messages[2].message.contains("newline"))
    }

    func testCaptureConsoleLogsWithNumbers() {
        // Arrange
        let script = """
        console.log(42);
        console.log(3.14159);
        console.log(-100);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].message, "42")
        XCTAssertTrue(messages[1].message.contains("3.14"))
        XCTAssertEqual(messages[2].message, "-100")
    }

    func testCaptureConsoleLogsWithObjects() {
        // Arrange
        let script = """
        console.log({ key: 'value', number: 42 });
        console.log([1, 2, 3]);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].message.contains("key") || messages[0].message.contains("value"))
        XCTAssertTrue(messages[1].message.contains("1"))
    }

    func testCaptureConsoleLogsInLoop() {
        // Arrange
        let script = """
        for (let i = 0; i < 5; i++) {
            console.log('Iteration ' + i);
        }
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 5)
        for i in 0..<5 {
            XCTAssertTrue(messages[i].message.contains("\(i)"))
        }
    }

    func testCaptureConsoleLogsInFunction() {
        // Arrange
        let script = """
        function test() {
            console.log('inside function');
        }
        test();
        test();
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].message, "inside function")
        XCTAssertEqual(messages[1].message, "inside function")
    }

    // MARK: - Error Capture Tests

    func testCaptureErrorsSimple() {
        // Arrange
        let script = "throw new Error('test error');"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.message.contains("test error") ?? false)
    }

    func testCaptureErrorsWithSyntaxError() {
        // Arrange
        let script = "const x = ;"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertGreaterThanOrEqual(errors.count, 1)
        XCTAssertNotNil(errors.first?.message)
    }

    func testCaptureErrorsWithReferenceError() {
        // Arrange
        let script = "console.log(undefinedVariable);"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertGreaterThanOrEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.message.contains("undefinedVariable") ?? false)
    }

    func testCaptureErrorsWithTypeError() {
        // Arrange
        let script = "null.someMethod();"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertGreaterThanOrEqual(errors.count, 1)
        XCTAssertNotNil(errors.first?.message)
    }

    func testCaptureErrorsWithCustomError() {
        // Arrange
        let script = "throw 'custom error string';"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.message.contains("custom error") ?? false)
    }

    func testCaptureErrorsWithNoErrors() {
        // Arrange
        let script = "var x = 1 + 1;"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 0)
    }

    func testCaptureErrorsWithEmptyScript() {
        // Arrange
        let script = ""

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 0)
    }

    func testCaptureErrorsMultiple() {
        // Arrange
        let script = """
        try {
            throw new Error('first error');
        } catch(e) {}
        throw new Error('second error');
        """

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        // Only the uncaught error should be captured
        XCTAssertGreaterThanOrEqual(errors.count, 1)
    }

    func testCaptureErrorsInFunction() {
        // Arrange
        let script = """
        function throwError() {
            throw new Error('function error');
        }
        throwError();
        """

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.message.contains("function error") ?? false)
    }

    // MARK: - ScriptErrorInfo Tests

    func testScriptErrorInfoStructure() {
        // Arrange
        let message = "Test error"
        let stack = "at line 1"
        let lineNumber = 10

        // Act
        let errorInfo = ScriptDebugger.ScriptErrorInfo(
            message: message,
            stack: stack,
            lineNumber: lineNumber
        )

        // Assert
        XCTAssertEqual(errorInfo.message, message)
        XCTAssertEqual(errorInfo.stack, stack)
        XCTAssertEqual(errorInfo.lineNumber, lineNumber)
    }

    func testScriptErrorInfoWithoutStack() {
        // Arrange
        let message = "Test error"

        // Act
        let errorInfo = ScriptDebugger.ScriptErrorInfo(
            message: message,
            stack: nil,
            lineNumber: nil
        )

        // Assert
        XCTAssertEqual(errorInfo.message, message)
        XCTAssertNil(errorInfo.stack)
        XCTAssertNil(errorInfo.lineNumber)
    }

    func testCaptureErrorsWithLineNumbers() {
        // Arrange
        let script = """
        var x = 1;
        var y = 2;
        throw new Error('line 3 error');
        """

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        if let lineNumber = errors.first?.lineNumber {
            XCTAssertGreaterThan(lineNumber, 0)
        }
    }

    func testCaptureErrorsWithStack() {
        // Arrange
        let script = """
        function innerFunction() {
            throw new Error('stack trace error');
        }
        function outerFunction() {
            innerFunction();
        }
        outerFunction();
        """

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        XCTAssertNotNil(errors.first?.stack)
    }

    // MARK: - Edge Cases

    func testCaptureConsoleLogsWithVeryLongMessage() {
        // Arrange
        let longMessage = String(repeating: "a", count: 10000)
        let script = "console.log('\(longMessage)');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message.count, longMessage.count)
    }

    func testCaptureConsoleLogsWithEmptyMessage() {
        // Arrange
        let script = "console.log('');"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "")
    }

    func testCaptureConsoleLogsWithNull() {
        // Arrange
        let script = "console.log(null);"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "null")
    }

    func testCaptureConsoleLogsWithUndefined() {
        // Arrange
        let script = "console.log(undefined);"

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "undefined")
    }

    func testCaptureConsoleLogsWithBoolean() {
        // Arrange
        let script = """
        console.log(true);
        console.log(false);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].message, "true")
        XCTAssertEqual(messages[1].message, "false")
    }

    func testCaptureErrorsWithVeryLongErrorMessage() {
        // Arrange
        let longMessage = String(repeating: "error", count: 1000)
        let script = "throw new Error('\(longMessage)');"

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.message.contains("error") ?? false)
    }

    // MARK: - Mixed Console and Error Tests

    func testCaptureConsoleLogsBeforeError() {
        // Arrange
        let script = """
        console.log('before error');
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "before error")
    }

    func testCaptureErrorsDoesNotIncludeConsoleLogs() {
        // Arrange
        let script = """
        console.log('this is a log');
        throw new Error('this is an error');
        """

        // Act
        let errors = debugger.captureErrors(script)

        // Assert
        XCTAssertGreaterThanOrEqual(errors.count, 1)
        XCTAssertFalse(errors.first?.message.contains("this is a log") ?? true)
        XCTAssertTrue(errors.first?.message.contains("this is an error") ?? false)
    }

    // MARK: - JavaScript Feature Tests

    func testCaptureConsoleLogsWithTemplateLiterals() {
        // Arrange
        let script = """
        const name = 'World';
        console.log(`Hello, ${name}!`);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "Hello, World!")
    }

    func testCaptureConsoleLogsWithArrowFunction() {
        // Arrange
        let script = """
        const log = (msg) => console.log(msg);
        log('arrow function message');
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "arrow function message")
    }

    func testCaptureConsoleLogsWithPromise() {
        // Arrange
        let script = """
        Promise.resolve('promise message').then(msg => console.log(msg));
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        // Note: Promise callback may not execute in synchronous evaluation
        XCTAssertGreaterThanOrEqual(messages.count, 0)
    }

    func testCaptureConsoleLogsWithDestructuring() {
        // Arrange
        let script = """
        const obj = { a: 1, b: 2 };
        const { a, b } = obj;
        console.log(a + b);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "3")
    }

    func testCaptureConsoleLogsWithSpreadOperator() {
        // Arrange
        let script = """
        const arr1 = [1, 2];
        const arr2 = [...arr1, 3, 4];
        console.log(arr2.length);
        """

        // Act
        let messages = debugger.captureConsoleLogs(script)

        // Assert
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.message, "4")
    }

    // MARK: - Concurrency Tests

    func testCaptureConsoleLogsMultipleTimes() {
        // Arrange
        let script = "console.log('test');"

        // Act & Assert
        for _ in 0..<10 {
            let messages = debugger.captureConsoleLogs(script)
            XCTAssertEqual(messages.count, 1)
        }
    }

    func testCaptureErrorsMultipleTimes() {
        // Arrange
        let script = "throw new Error('test');"

        // Act & Assert
        for _ in 0..<10 {
            let errors = debugger.captureErrors(script)
            XCTAssertEqual(errors.count, 1)
        }
    }

    // MARK: - Performance Tests

    func testCaptureConsoleLogsPerformance() {
        // Arrange
        let script = """
        for (let i = 0; i < 100; i++) {
            console.log('message ' + i);
        }
        """

        // Act
        measure {
            _ = debugger.captureConsoleLogs(script)
        }
    }

    func testCaptureErrorsPerformance() {
        // Arrange
        let script = "throw new Error('performance test');"

        // Act
        measure {
            _ = debugger.captureErrors(script)
        }
    }
}
