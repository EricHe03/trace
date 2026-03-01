import SwiftUI
import TraceCore

public extension DesignSystem.Colors {
    static func methodColor(for method: HTTPMethod) -> Color {
        switch method {
        case .get: accent
        case .post: success
        case .put: warning
        case .delete: danger
        case .patch: accentAlt
        case .connect: muted
        default: muted
        }
    }

    static func statusColor(for statusColor: StatusColor) -> Color {
        switch statusColor {
        case .success: success
        case .redirect: accent
        case .clientError: warning
        case .serverError: danger
        case .info: info
        case .warning: favorite
        case .unknown: muted
        }
    }

    static func statusColor(for statusCode: Int) -> Color {
        switch statusCode {
        case 200 ..< 300: success
        case 300 ..< 400: accent
        case 400 ..< 500: warning
        case 500...: danger
        default: muted
        }
    }

    static func eventTypeColor(for type: NetworkEventType) -> Color {
        switch type {
        case .http: accent
        case .webSocket: accentAlt
        case .sse: warning
        case .tcp: info
        case .udp: accent
        case .dns: accentAlt
        case .mdns: success
        case .ntp: warning
        case .dhcpv4: favorite
        case .dhcpv6: favorite
        case .snmp: danger
        case .quic: success
        case .transport: muted
        }
    }
}
