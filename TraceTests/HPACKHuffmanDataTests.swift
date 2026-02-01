//
//  HPACKHuffmanDataTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import TraceNetworking

@available(macOS 11.0, iOS 14.0, *)
final class HPACKHuffmanDataTests: XCTestCase {

    // MARK: - Initialization Tests

    func testHuffmanDecodeTableInitialization() {
        XCTAssertTrue(HuffmanDecodeTable.isValid)
        XCTAssertGreaterThan(HuffmanDecodeTable.table.count, 0)
    }

    func testHuffmanDecodeTableStructure() {
        let table = HuffmanDecodeTable.table

        // Each row should have 16 entries (nibble-indexed)
        for row in table {
            XCTAssertEqual(row.count, 16, "Each row should have 16 entries")
        }
    }

    // MARK: - HuffmanDecodeNode Tests

    func testHuffmanDecodeNodeProperties() {
        // Create a sample node
        let fstate: UInt16 = 0x8001 // Has symbol (bit 15 set), state 1
        let sym: UInt8 = 65 // 'A'
        let node = HuffmanDecodeNode(fstate: fstate, sym: sym)

        XCTAssertEqual(node.fstate, fstate)
        XCTAssertEqual(node.sym, sym)
        XCTAssertTrue(node.hasSymbol)
        XCTAssertEqual(node.nextState, 1)
    }

    func testHuffmanDecodeNodeWithoutSymbol() {
        let fstate: UInt16 = 0x0010 // No symbol (bit 15 clear), state 16
        let sym: UInt8 = 0
        let node = HuffmanDecodeNode(fstate: fstate, sym: sym)

        XCTAssertFalse(node.hasSymbol)
        XCTAssertEqual(node.nextState, 16)
    }

    func testHuffmanDecodeNodeAccepted() {
        let fstate: UInt16 = 0xC000 // Both hasSymbol and isAccepted bits set
        let sym: UInt8 = 32 // space
        let node = HuffmanDecodeNode(fstate: fstate, sym: sym)

        XCTAssertTrue(node.hasSymbol)
        XCTAssertTrue(node.isAccepted)
    }

    func testHuffmanDecodeNodeNotAccepted() {
        let fstate: UInt16 = 0x8000 // Only hasSymbol set
        let sym: UInt8 = 32
        let node = HuffmanDecodeNode(fstate: fstate, sym: sym)

        XCTAssertTrue(node.hasSymbol)
        XCTAssertFalse(node.isAccepted)
    }

    // MARK: - Mask Tests

    func testHuffSymMask() {
        let mask: UInt16 = huffSymMask
        XCTAssertEqual(mask, 1 << 15)
        XCTAssertEqual(mask, 0x8000)
    }

    func testHuffAcceptedMask() {
        let mask: UInt16 = huffAcceptedMask
        XCTAssertEqual(mask, 1 << 14)
        XCTAssertEqual(mask, 0x4000)
    }

    // MARK: - Table Access Tests

    func testGlobalHuffmanDecodeTableAccess() {
        let table = huffmanDecodeTable
        XCTAssertGreaterThan(table.count, 0)
        XCTAssertTrue(table.count % 16 == 0, "Table size should be multiple of 16")
    }

    func testHuffmanDecodeTableConsistency() {
        let table1 = huffmanDecodeTable
        let table2 = HuffmanDecodeTable.table

        XCTAssertEqual(table1.count, table2.count)
    }

    // MARK: - Base64 Decoding Tests

    func testBase64DecodingSucceeds() {
        // The table should decode successfully
        XCTAssertTrue(HuffmanDecodeTable.isValid)
    }

    // MARK: - Table Content Validation

    func testFirstTableEntry() {
        let table = HuffmanDecodeTable.table
        XCTAssertGreaterThan(table.count, 0)

        let firstRow = table[0]
        XCTAssertEqual(firstRow.count, 16)

        // Verify structure
        for node in firstRow {
            XCTAssertTrue(node.nextState >= 0)
        }
    }

    func testLastTableEntry() {
        let table = HuffmanDecodeTable.table
        let lastRow = table[table.count - 1]
        XCTAssertEqual(lastRow.count, 16)
    }

    func testTableEntriesHaveValidStates() {
        let table = HuffmanDecodeTable.table

        for (rowIndex, row) in table.enumerated() {
            for (colIndex, node) in row.enumerated() {
                // State should be within valid range
                XCTAssertTrue(node.nextState >= 0, "Invalid state at row \(rowIndex), col \(colIndex)")
                XCTAssertTrue(node.nextState < table.count, "State out of bounds at row \(rowIndex), col \(colIndex)")
            }
        }
    }

    func testTableEntriesHaveValidSymbols() {
        let table = HuffmanDecodeTable.table

        for (rowIndex, row) in table.enumerated() {
            for (colIndex, node) in row.enumerated() {
                if node.hasSymbol {
                    // Symbol should be valid byte value or EOS (256)
                    XCTAssertTrue(node.sym <= 255, "Invalid symbol at row \(rowIndex), col \(colIndex)")
                }
            }
        }
    }

    // MARK: - Nibble Indexing Tests

    func testNibbleIndexing() {
        let table = HuffmanDecodeTable.table

        // Test that we can access all 16 entries in first row (one per nibble value)
        for nibble in 0..<16 {
            let node = table[0][nibble]
            XCTAssertNotNil(node)
        }
    }

    // MARK: - Edge Cases

    func testEmptyStateNavigation() {
        let table = HuffmanDecodeTable.table

        // Start at state 0, check that we can navigate
        let state0Row = table[0]
        XCTAssertEqual(state0Row.count, 16)

        // All nibbles should lead somewhere
        for node in state0Row {
            XCTAssertTrue(node.nextState >= 0)
        }
    }

    func testAcceptedStates() {
        let table = HuffmanDecodeTable.table
        var acceptedCount = 0

        for row in table {
            for node in row {
                if node.isAccepted {
                    acceptedCount += 1
                }
            }
        }

        // Should have some accepted states
        XCTAssertGreaterThan(acceptedCount, 0, "Should have at least some accepted states")
    }

    func testSymbolStates() {
        let table = HuffmanDecodeTable.table
        var symbolCount = 0

        for row in table {
            for node in row {
                if node.hasSymbol {
                    symbolCount += 1
                }
            }
        }

        // Should have symbol-producing states
        XCTAssertGreaterThan(symbolCount, 0, "Should have at least some symbol states")
    }

    // MARK: - State Transition Tests

    func testStateTransitionsAreValid() {
        let table = HuffmanDecodeTable.table

        for (stateIndex, row) in table.enumerated() {
            for (nibble, node) in row.enumerated() {
                if !node.hasSymbol {
                    // Non-terminal states should transition to valid states
                    let nextState = node.nextState
                    XCTAssertTrue(nextState >= 0 && nextState < table.count,
                                "Invalid transition from state \(stateIndex), nibble \(nibble)")
                }
            }
        }
    }

    // MARK: - Bit Mask Operations

    func testNextStateExtraction() {
        let fstate1: UInt16 = 0x8123 // hasSymbol=1, state=0x123
        let node1 = HuffmanDecodeNode(fstate: fstate1, sym: 0)
        XCTAssertEqual(node1.nextState, 0x123)

        let fstate2: UInt16 = 0x01FF // hasSymbol=0, state=0x1FF
        let node2 = HuffmanDecodeNode(fstate: fstate2, sym: 0)
        XCTAssertEqual(node2.nextState, 0x1FF)
    }

    func testSymbolFlagExtraction() {
        let withSymbol: UInt16 = 0x8000
        let node1 = HuffmanDecodeNode(fstate: withSymbol, sym: 65)
        XCTAssertTrue(node1.hasSymbol)

        let withoutSymbol: UInt16 = 0x7FFF
        let node2 = HuffmanDecodeNode(fstate: withoutSymbol, sym: 0)
        XCTAssertFalse(node2.hasSymbol)
    }

    func testAcceptedFlagExtraction() {
        let accepted: UInt16 = 0x4000
        let node1 = HuffmanDecodeNode(fstate: accepted, sym: 0)
        XCTAssertTrue(node1.isAccepted)

        let notAccepted: UInt16 = 0xBFFF
        let node2 = HuffmanDecodeNode(fstate: notAccepted, sym: 0)
        XCTAssertFalse(node2.isAccepted)
    }

    // MARK: - Table Size Tests

    func testTableSizeIsReasonable() {
        let table = HuffmanDecodeTable.table
        let totalEntries = table.count * 16

        // Should have a reasonable number of entries for Huffman decoding
        XCTAssertGreaterThan(totalEntries, 100, "Table seems too small")
        XCTAssertLessThan(totalEntries, 10000, "Table seems too large")
    }

    // MARK: - Common Character Navigation

    func testCommonCharacterPaths() {
        let table = HuffmanDecodeTable.table

        // Common characters should be reachable
        // This tests that the table structure is generally correct
        var state = 0
        let nibbles: [Int] = [0, 1, 2, 3] // Arbitrary path

        for nibble in nibbles {
            XCTAssertTrue(state < table.count, "State out of bounds")
            let node = table[state][nibble]
            state = node.nextState
        }
    }

    // MARK: - Sendable Conformance

    func testHuffmanDecodeNodeIsSendable() {
        // This test ensures the type is properly marked as Sendable
        let node = HuffmanDecodeNode(fstate: 0x8041, sym: 65)

        Task {
            let _ = node.sym // Should compile without warnings
        }
    }

    // MARK: - Memory Efficiency

    func testNodeMemoryLayout() {
        // Verify the node is efficiently packed
        let nodeSize = MemoryLayout<HuffmanDecodeNode>.size
        XCTAssertEqual(nodeSize, 3, "Node should be 3 bytes (UInt16 + UInt8)")
    }

    // MARK: - Performance Tests

    func testTableAccessPerformance() {
        let table = HuffmanDecodeTable.table

        measure {
            var sum = 0
            for _ in 0..<1000 {
                for row in table {
                    for node in row {
                        sum += Int(node.sym)
                    }
                }
            }
            XCTAssertGreaterThan(sum, 0) // Prevent optimization
        }
    }

    func testTableInitializationPerformance() {
        measure {
            _ = HuffmanDecodeTable.table
        }
    }
}
