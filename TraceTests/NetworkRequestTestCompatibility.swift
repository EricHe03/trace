//
//  NetworkRequestTestCompatibility.swift
//  TraceTests
//
//  Created by Justin on 2026/01/08.
//

@testable import Trace
@testable import TraceCore

extension NetworkRequest {
    // Test-only compatibility aliases for legacy response accessors.
    var headers: [TraceHTTPHeader] {
        get { responseHeaders }
        set { responseHeaders = newValue }
    }

    var body: BodyStorage {
        get { responseBody }
        set { responseBody = newValue }
    }
}
