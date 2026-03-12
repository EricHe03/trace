//
//  MITMEngine.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/24.
//

import Foundation
import TraceCore

protocol MITMEngine: AnyObject {
    @discardableResult
    func start() throws -> NIOMITMProxyEngine.Endpoint
    func stop()
    func activeConnectionCount() -> Int
}

extension NIOMITMProxyEngine: MITMEngine {}
