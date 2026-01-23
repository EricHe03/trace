//
//  ScriptLibrary.swift
//  TraceFeatures
//
//  Created by Justin on 2026/01/21.
//

import Foundation

public enum ScriptLibrary {
    public static var templates: [ScriptTemplate] {
        [
            ScriptTemplate(
                name: "Add CORS Headers",
                category: .response,
                description: "Add permissive CORS headers to responses.",
                code: """
                response.headers['Access-Control-Allow-Origin'] = '*';
                response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS';
                response.headers['Access-Control-Allow-Headers'] = '*';
                """
            ),
            ScriptTemplate(
                name: "Inject Auth Token",
                category: .authentication,
                description: "Add Authorization header to requests.",
                code: """
                request.headers['Authorization'] = 'Bearer YOUR_TOKEN';
                """
            ),
            ScriptTemplate(
                name: "Force JSON Response",
                category: .response,
                description: "Replace response body with JSON.",
                code: """
                response.headers['Content-Type'] = 'application/json';
                response.body = JSON.stringify({ status: 'ok' });
                """
            ),
            ScriptTemplate(
                name: "Log Request URL",
                category: .debugging,
                description: "Log request URL to console.",
                code: """
                console.log('Request URL: ' + request.url);
                """
            ),
            ScriptTemplate(
                name: "Rewrite Query Param",
                category: .request,
                description: "Replace query parameter value.",
                code: """
                request.url = setQueryParam(request.url, 'debug', '1');
                """
            )
        ]
    }
}

public struct ScriptTemplate {
    public var name: String
    public var category: ScriptCategory
    public var description: String
    public var code: String

    public init(name: String, category: ScriptCategory, description: String, code: String) {
        self.name = name
        self.category = category
        self.description = description
        self.code = code
    }
}

public enum ScriptCategory: String {
    case request
    case response
    case authentication
    case debugging
    case security
}
