//
//  CookieStore.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/23.
//

import Foundation

public protocol CookieStore {
    func cookies(for url: URL) -> [HTTPCookie]
}

public struct DefaultCookieStore: CookieStore {
    public init() {}

    public func cookies(for url: URL) -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(for: url) ?? []
    }
}
