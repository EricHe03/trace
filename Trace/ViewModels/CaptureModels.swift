//
//  CaptureModels.swift
//  Trace
//
//  Created by Justin on 2026/03/06.
//

import Foundation
import TraceCore

enum SearchScope: String, CaseIterable, Sendable {
    case all = "All"
    case url = "URL"
    case headers = "Headers"
    case body = "Body"
}

enum ResponseTimeFilter: String, CaseIterable, Sendable {
    case fast = "Fast"
    case normal = "Normal"
    case slow = "Slow"

    var range: ClosedRange<TimeInterval> {
        switch self {
        case .fast: 0 ... 0.1
        case .normal: 0.1 ... 1.0
        case .slow: 1.0 ... Double.infinity
        }
    }

    var displayName: String {
        switch self {
        case .fast: "Fast (< 100ms)"
        case .normal: "Normal (100ms - 1s)"
        case .slow: "Slow (> 1s)"
        }
    }

    var icon: String {
        switch self {
        case .fast: "hare.fill"
        case .normal: "gauge.medium"
        case .slow: "tortoise.fill"
        }
    }
}

enum ContentTypeFilter: String, CaseIterable, Sendable {
    case json = "JSON"
    case html = "HTML"
    case xml = "XML"
    case image = "Image"
    case javascript = "JavaScript"
    case css = "CSS"
    case plainText = "Plain Text"
    case binary = "Binary"

    var mimeTypes: [String] {
        switch self {
        case .json: ["application/json", "text/json"]
        case .html: ["text/html"]
        case .xml: ["application/xml", "text/xml"]
        case .image: [
                "image/png",
                "image/jpeg",
                "image/gif",
                "image/webp",
                "image/svg+xml",
                "image/heic",
                "image/heif",
                "image/avif",
                "image/tiff",
                "image/bmp",
                "image/x-ms-bmp",
                "image/x-icon",
                "image/vnd.microsoft.icon"
            ]
        case .javascript: ["application/javascript", "text/javascript"]
        case .css: ["text/css"]
        case .plainText: ["text/plain"]
        case .binary: ["application/octet-stream", "binary/octet-stream", "octet-stream"]
        }
    }

    var icon: String {
        switch self {
        case .json: "curlybraces"
        case .html: "doc.text"
        case .xml: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .javascript: "scroll"
        case .css: "paintbrush"
        case .plainText: "text.alignleft"
        case .binary: "doc.zipper"
        }
    }
}

enum RequestGroupingMode: String, CaseIterable, Codable {
    case none = "None"
    case byDomain = "By Domain"
    case bySession = "By Session"
    case hierarchical = "Hierarchical"

    var icon: String {
        switch self {
        case .none: "list.bullet"
        case .byDomain: "globe"
        case .bySession: "clock"
        case .hierarchical: "list.bullet.indent"
        }
    }

    var description: String {
        switch self {
        case .none: "Flat list of all requests"
        case .byDomain: "Group by domain"
        case .bySession: "Group by capture session"
        case .hierarchical: "Group by session, then domain"
        }
    }
}

struct DomainGroup: Identifiable {
    let id: String
    let domain: String
    let requests: [NetworkRequest]

    init(id: String? = nil, domain: String, requests: [NetworkRequest]) {
        self.id = id ?? domain
        self.domain = domain
        self.requests = requests
    }

    var requestCount: Int {
        requests.count
    }

    var totalSize: Int64 {
        requests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
    }

    var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

struct SessionGroup: Identifiable {
    let session: CaptureSession
    let requests: [NetworkRequest]
    let domainGroups: [DomainGroup]

    var id: UUID {
        session.id
    }

    var requestCount: Int {
        requests.count
    }

    var totalSize: Int64 {
        requests.reduce(0) { $0 + Int64($1.responseSize ?? 0) }
    }

    var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

struct GroupedRequests {
    let mode: RequestGroupingMode
    let domainGroups: [DomainGroup]
    let sessionGroups: [SessionGroup]

    init(mode: RequestGroupingMode, domainGroups: [DomainGroup] = [], sessionGroups: [SessionGroup] = []) {
        self.mode = mode
        self.domainGroups = domainGroups
        self.sessionGroups = sessionGroups
    }

    var isEmpty: Bool {
        domainGroups.isEmpty && sessionGroups.isEmpty
    }
}

struct SavedFilterPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var filterMethod: String?
    var filterStatusCode: Int?
    var filterDomains: [String]
    var filterFavoritesOnly: Bool
    var filterContentTypes: [String]
    var filterNetworkEventTypes: [String]?
    var filterMinSize: Int?
    var filterMaxSize: Int?
    var filterMinDuration: TimeInterval?
    var filterMaxDuration: TimeInterval?
    var filterRegexPattern: String?
    var filterResponseTime: String?
    var filterShowDuplicatesOnly: Bool
    var filterShowErrorsOnly: Bool

    init(
        id: UUID = UUID(),
        name: String,
        filterMethod: HTTPMethod? = nil,
        filterStatusCode: Int? = nil,
        filterDomains: [String] = [],
        filterFavoritesOnly: Bool = false,
        filterContentTypes: [ContentTypeFilter] = [],
        filterNetworkEventTypes: [NetworkEventType]? = nil,
        filterMinSize: Int? = nil,
        filterMaxSize: Int? = nil,
        filterMinDuration: TimeInterval? = nil,
        filterMaxDuration: TimeInterval? = nil,
        filterRegexPattern: String? = nil,
        filterResponseTime: ResponseTimeFilter? = nil,
        filterShowDuplicatesOnly: Bool = false,
        filterShowErrorsOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.filterMethod = filterMethod?.rawValue
        self.filterStatusCode = filterStatusCode
        self.filterDomains = filterDomains
        self.filterFavoritesOnly = filterFavoritesOnly
        self.filterContentTypes = filterContentTypes.map(\.rawValue)
        self.filterNetworkEventTypes = filterNetworkEventTypes?.map(\.rawValue)
        self.filterMinSize = filterMinSize
        self.filterMaxSize = filterMaxSize
        self.filterMinDuration = filterMinDuration
        self.filterMaxDuration = filterMaxDuration
        self.filterRegexPattern = filterRegexPattern
        self.filterResponseTime = filterResponseTime?.rawValue
        self.filterShowDuplicatesOnly = filterShowDuplicatesOnly
        self.filterShowErrorsOnly = filterShowErrorsOnly
    }
}
