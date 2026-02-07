//
//  DetailActionModel.swift
//  Trace
//
//  Created by Justin on 2026/02/06.
//

import Foundation

enum DetailAction: String, Identifiable, CaseIterable {
    case replay
    case copyURL
    case copyCurl
    case shareFullRequest
    case editAndSend
    case shareResponseBody
    case shareRequestBody

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .replay:
            "Replay Request"
        case .copyURL:
            "Copy URL"
        case .copyCurl:
            "Copy as cURL"
        case .shareFullRequest:
            "Share Full Request"
        case .editAndSend:
            "Edit & Send"
        case .shareResponseBody:
            "Share Response Body"
        case .shareRequestBody:
            "Share Request Body"
        }
    }

    var systemImage: String {
        switch self {
        case .replay:
            "arrow.clockwise"
        case .copyURL:
            "doc.on.doc"
        case .copyCurl:
            "terminal"
        case .shareFullRequest:
            "square.and.arrow.up"
        case .editAndSend:
            "pencil"
        case .shareResponseBody:
            "arrow.down.doc"
        case .shareRequestBody:
            "arrow.up.doc"
        }
    }
}

enum DetailActionModel {
    static let primaryActions: [DetailAction] = [
        .replay,
        .copyURL,
        .copyCurl,
        .shareFullRequest
    ]

    static func overflowActions(hasRequestBody: Bool, hasResponseBody: Bool) -> [DetailAction] {
        var actions: [DetailAction] = [.editAndSend]

        if hasResponseBody {
            actions.append(.shareResponseBody)
        }

        if hasRequestBody {
            actions.append(.shareRequestBody)
        }

        return actions
    }
}
