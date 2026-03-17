import Foundation
@testable import TraceCore

func makeThrottlingState(
    enabled: Bool = true,
    latency: Int = 100,
    downloadSpeed: Int = 1024,
    uploadSpeed: Int = 512,
    packetLoss: Double = 0.0
) -> NetworkThrottlingState {
    let condition = NetworkCondition.custom(
        download: downloadSpeed,
        upload: uploadSpeed,
        latency: latency,
        packetLoss: packetLoss
    )
    return NetworkThrottlingState(enabled: enabled, condition: condition)
}
