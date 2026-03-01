//
//  IngressClassifier.swift
//  TraceProxy
//
//  Created by Justin on 2026/02/24.
//

import Foundation
import NIOCore
import TraceCore

enum IngressClassification: Equatable, Sendable {
    case transparentTLS
    case httpProxy
}

/// Phase-5 scaffolding component that classifies inbound bytes before
/// the MITM pipeline is installed.
struct IngressClassifier: Sendable {
    func classify(_ buffer: ByteBuffer) -> IngressClassification? {
        var working = buffer
        let decode = TransparentProxyMetadata.decodeUpstreamHintPrefix(from: working)
        switch decode {
        case .needMore:
            return nil
        case .invalid:
            return nil
        case let .value(_, consumedBytes):
            working.moveReaderIndex(forwardBy: consumedBytes)
        case .absent:
            break
        }

        guard let firstByte = working.getInteger(at: working.readerIndex, as: UInt8.self) else {
            return nil
        }
        if firstByte == 0x16 {
            return .transparentTLS
        }
        return .httpProxy
    }
}
