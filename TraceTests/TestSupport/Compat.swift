//
//  Compat.swift
//  TraceTests
//
//  Compatibility shims for older test helpers.
//

import Foundation
@testable import TraceCore
@testable import TraceFeatures

typealias HTTPHeader = TraceHTTPHeader

extension BodyStorage {
    static func text(_ string: String, charset: String? = "utf-8") -> BodyStorage {
        .inline(Data(string.utf8), charset: charset, compressionInfo: nil)
    }

    static func data(_ data: Data) -> BodyStorage {
        .inline(data, charset: nil, compressionInfo: nil)
    }
}

extension HTTPMethod {
    static var GET: HTTPMethod { .get }
    static var POST: HTTPMethod { .post }
    static var PUT: HTTPMethod { .put }
    static var DELETE: HTTPMethod { .delete }
    static var PATCH: HTTPMethod { .patch }
    static var HEAD: HTTPMethod { .head }
    static var OPTIONS: HTTPMethod { .options }
    static var CONNECT: HTTPMethod { .connect }
}

extension RewriteManager {
    func createRule(_ rule: RewriteRule) {
        addRule(rule)
    }
}
