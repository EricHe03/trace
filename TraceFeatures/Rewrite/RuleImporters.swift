//
//  RuleImporters.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation
import TraceCore

public enum ProxymanRuleParser {
    public static func parse(_ data: Data) -> [RewriteRule] {
        // TODO: Implement Proxyman import format.
        []
    }
}

public enum CharlesRuleParser {
    public static func parse(_ data: Data) -> [RewriteRule] {
        // TODO: Implement Charles import format.
        []
    }
}

public enum FiddlerRuleParser {
    public static func parse(_ data: Data) -> [RewriteRule] {
        // TODO: Implement Fiddler import format.
        []
    }
}

public enum HARToRuleConverter {
    public static func convert(_ data: Data) -> [RewriteRule] {
        // TODO: Implement HAR conversion.
        []
    }
}
