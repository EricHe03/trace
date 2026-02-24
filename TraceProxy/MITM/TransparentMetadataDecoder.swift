//
//  TransparentMetadataDecoder.swift
//  TraceProxy
//
//  Created by Codex on 2026/02/24.
//

import Foundation
import NIOCore
import TraceCore

/// Phase-5 scaffolding wrapper around transparent metadata prefix parsing.
struct TransparentMetadataDecoder: Sendable {
    func decodePrefix(from buffer: ByteBuffer) -> TransparentProxyMetadata.DecodeResult {
        TransparentProxyMetadata.decodeUpstreamHintPrefix(from: buffer)
    }
}
