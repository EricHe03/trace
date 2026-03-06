//
//  Favorite+Samples.swift
//  TraceCore
//
//  Created by Justin on 2026/03/06.
//

import Foundation

public extension Favorite {
    static var sample: Favorite {
        Favorite(
            requestId: UUID(),
            name: "Login API Call",
            notes: "Important: This shows the authentication flow"
        )
    }
}
