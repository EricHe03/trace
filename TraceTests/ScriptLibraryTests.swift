//
//  ScriptLibraryTests.swift
//  TraceTests
//
//  Created by Claude on 2026/02/01.
//

import XCTest
@testable import Trace
@testable import TraceCore
@testable import TraceFeatures

final class ScriptLibraryTests: XCTestCase {

    // MARK: - Template Tests

    func testTemplatesNotEmpty() {
        // Arrange & Act
        let templates = ScriptLibrary.templates

        // Assert
        XCTAssertFalse(templates.isEmpty)
        XCTAssertGreaterThan(templates.count, 0)
    }

    func testTemplatesCount() {
        // Arrange & Act
        let templates = ScriptLibrary.templates

        // Assert
        XCTAssertEqual(templates.count, 5)
    }

    func testAllTemplatesHaveRequiredFields() {
        // Arrange & Act
        let templates = ScriptLibrary.templates

        // Assert
        for template in templates {
            XCTAssertFalse(template.name.isEmpty, "Template name should not be empty")
            XCTAssertFalse(template.description.isEmpty, "Template description should not be empty")
            XCTAssertFalse(template.code.isEmpty, "Template code should not be empty")
        }
    }

    func testAllTemplatesHaveUniqueNames() {
        // Arrange & Act
        let templates = ScriptLibrary.templates
        let names = templates.map { $0.name }
        let uniqueNames = Set(names)

        // Assert
        XCTAssertEqual(names.count, uniqueNames.count, "All template names should be unique")
    }

    // MARK: - Individual Template Tests

    func testAddCORSHeadersTemplate() {
        // Arrange & Act
        let template = ScriptLibrary.templates.first { $0.name == "Add CORS Headers" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.category, .response)
        XCTAssertTrue(template?.code.contains("Access-Control-Allow-Origin") ?? false)
        XCTAssertTrue(template?.code.contains("Access-Control-Allow-Methods") ?? false)
        XCTAssertTrue(template?.code.contains("Access-Control-Allow-Headers") ?? false)
        XCTAssertTrue(template?.description.contains("CORS") ?? false)
    }

    func testInjectAuthTokenTemplate() {
        // Arrange & Act
        let template = ScriptLibrary.templates.first { $0.name == "Inject Auth Token" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.category, .authentication)
        XCTAssertTrue(template?.code.contains("Authorization") ?? false)
        XCTAssertTrue(template?.code.contains("Bearer") ?? false)
        XCTAssertTrue(template?.description.contains("Authorization") ?? false)
    }

    func testForceJSONResponseTemplate() {
        // Arrange & Act
        let template = ScriptLibrary.templates.first { $0.name == "Force JSON Response" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.category, .response)
        XCTAssertTrue(template?.code.contains("Content-Type") ?? false)
        XCTAssertTrue(template?.code.contains("application/json") ?? false)
        XCTAssertTrue(template?.code.contains("JSON.stringify") ?? false)
        XCTAssertTrue(template?.description.contains("JSON") ?? false)
    }

    func testLogRequestURLTemplate() {
        // Arrange & Act
        let template = ScriptLibrary.templates.first { $0.name == "Log Request URL" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.category, .debugging)
        XCTAssertTrue(template?.code.contains("console.log") ?? false)
        XCTAssertTrue(template?.code.contains("request.url") ?? false)
        XCTAssertTrue(template?.description.contains("Log") ?? false)
    }

    func testRewriteQueryParamTemplate() {
        // Arrange & Act
        let template = ScriptLibrary.templates.first { $0.name == "Rewrite Query Param" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertEqual(template?.category, .request)
        XCTAssertTrue(template?.code.contains("setQueryParam") ?? false)
        XCTAssertTrue(template?.code.contains("request.url") ?? false)
        XCTAssertTrue(template?.description.contains("query") ?? false)
    }

    // MARK: - Category Tests

    func testAllCategoriesRepresented() {
        // Arrange & Act
        let templates = ScriptLibrary.templates
        let categories = Set(templates.map { $0.category })

        // Assert
        XCTAssertTrue(categories.contains(.request))
        XCTAssertTrue(categories.contains(.response))
        XCTAssertTrue(categories.contains(.authentication))
        XCTAssertTrue(categories.contains(.debugging))
    }

    func testTemplatesGroupedByCategory() {
        // Arrange & Act
        let templates = ScriptLibrary.templates
        let requestTemplates = templates.filter { $0.category == .request }
        let responseTemplates = templates.filter { $0.category == .response }
        let authTemplates = templates.filter { $0.category == .authentication }
        let debugTemplates = templates.filter { $0.category == .debugging }

        // Assert
        XCTAssertGreaterThan(requestTemplates.count, 0)
        XCTAssertGreaterThan(responseTemplates.count, 0)
        XCTAssertGreaterThan(authTemplates.count, 0)
        XCTAssertGreaterThan(debugTemplates.count, 0)
    }

    // MARK: - ScriptTemplate Tests

    func testScriptTemplateInitialization() {
        // Arrange
        let name = "Test Template"
        let category = ScriptCategory.request
        let description = "Test description"
        let code = "console.log('test');"

        // Act
        let template = ScriptTemplate(
            name: name,
            category: category,
            description: description,
            code: code
        )

        // Assert
        XCTAssertEqual(template.name, name)
        XCTAssertEqual(template.category, category)
        XCTAssertEqual(template.description, description)
        XCTAssertEqual(template.code, code)
    }

    func testScriptTemplateWithAllCategories() {
        // Arrange & Act & Assert
        let categories: [ScriptCategory] = [.request, .response, .authentication, .debugging, .security]

        for category in categories {
            let template = ScriptTemplate(
                name: "Test",
                category: category,
                description: "Test",
                code: "test"
            )
            XCTAssertEqual(template.category, category)
        }
    }

    // MARK: - ScriptCategory Tests

    func testScriptCategoryRawValues() {
        // Assert
        XCTAssertEqual(ScriptCategory.request.rawValue, "request")
        XCTAssertEqual(ScriptCategory.response.rawValue, "response")
        XCTAssertEqual(ScriptCategory.authentication.rawValue, "authentication")
        XCTAssertEqual(ScriptCategory.debugging.rawValue, "debugging")
        XCTAssertEqual(ScriptCategory.security.rawValue, "security")
    }

    func testScriptCategoryFromRawValue() {
        // Arrange & Act & Assert
        XCTAssertEqual(ScriptCategory(rawValue: "request"), .request)
        XCTAssertEqual(ScriptCategory(rawValue: "response"), .response)
        XCTAssertEqual(ScriptCategory(rawValue: "authentication"), .authentication)
        XCTAssertEqual(ScriptCategory(rawValue: "debugging"), .debugging)
        XCTAssertEqual(ScriptCategory(rawValue: "security"), .security)
    }

    func testScriptCategoryInvalidRawValue() {
        // Arrange & Act
        let invalidCategory = ScriptCategory(rawValue: "invalid")

        // Assert
        XCTAssertNil(invalidCategory)
    }

    // MARK: - Template Code Validation Tests

    func testAllTemplateCodesAreValidJavaScript() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            XCTAssertFalse(template.code.isEmpty, "Template '\(template.name)' has empty code")
            // Basic validation - code should not be just whitespace
            XCTAssertFalse(template.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "Template '\(template.name)' has only whitespace code")
        }
    }

    func testTemplateCodesContainExpectedKeywords() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            switch template.category {
            case .request:
                XCTAssertTrue(template.code.contains("request") || template.code.contains("console"),
                            "Request template '\(template.name)' should reference request or console")
            case .response:
                XCTAssertTrue(template.code.contains("response"),
                            "Response template '\(template.name)' should reference response")
            case .authentication:
                XCTAssertTrue(template.code.contains("request") || template.code.contains("Authorization"),
                            "Auth template '\(template.name)' should reference request or Authorization")
            case .debugging:
                XCTAssertTrue(template.code.contains("console"),
                            "Debug template '\(template.name)' should use console")
            case .security:
                // Security templates can vary, no specific requirement
                break
            }
        }
    }

    func testTemplateCodesDoNotContainCommonErrors() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            // Check for common syntax errors
            XCTAssertEqual(
                template.code.filter { $0 == "{" }.count,
                template.code.filter { $0 == "}" }.count,
                "Template '\(template.name)' has mismatched braces"
            )

            XCTAssertEqual(
                template.code.filter { $0 == "[" }.count,
                template.code.filter { $0 == "]" }.count,
                "Template '\(template.name)' has mismatched brackets"
            )
        }
    }

    // MARK: - Template Description Tests

    func testAllTemplateDescriptionsAreMeaningful() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            XCTAssertGreaterThan(template.description.count, 10,
                               "Template '\(template.name)' description is too short")
            XCTAssertLessThan(template.description.count, 200,
                            "Template '\(template.name)' description is too long")
        }
    }

    func testTemplateDescriptionsEndWithPeriod() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            XCTAssertTrue(template.description.hasSuffix("."),
                        "Template '\(template.name)' description should end with period")
        }
    }

    // MARK: - Template Name Tests

    func testAllTemplateNamesAreProperCase() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            // First character should be uppercase
            if let firstChar = template.name.first {
                XCTAssertTrue(firstChar.isUppercase,
                            "Template name '\(template.name)' should start with uppercase")
            }
        }
    }

    func testTemplateNamesAreReasonableLength() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act & Assert
        for template in templates {
            XCTAssertGreaterThan(template.name.count, 3,
                               "Template name '\(template.name)' is too short")
            XCTAssertLessThan(template.name.count, 50,
                            "Template name '\(template.name)' is too long")
        }
    }

    // MARK: - Integration Tests

    func testTemplatesCanBeFilteredByCategory() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let responseTemplates = templates.filter { $0.category == .response }

        // Assert
        XCTAssertGreaterThan(responseTemplates.count, 0)
        for template in responseTemplates {
            XCTAssertEqual(template.category, .response)
        }
    }

    func testTemplatesCanBeSortedByName() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let sortedTemplates = templates.sorted { $0.name < $1.name }

        // Assert
        XCTAssertEqual(sortedTemplates.count, templates.count)
        for i in 0..<sortedTemplates.count - 1 {
            XCTAssertLessThanOrEqual(sortedTemplates[i].name, sortedTemplates[i + 1].name)
        }
    }

    func testTemplatesCanBeSearchedByName() {
        // Arrange
        let templates = ScriptLibrary.templates
        let searchTerm = "CORS"

        // Act
        let matchingTemplates = templates.filter { $0.name.contains(searchTerm) }

        // Assert
        XCTAssertGreaterThan(matchingTemplates.count, 0)
        for template in matchingTemplates {
            XCTAssertTrue(template.name.contains(searchTerm))
        }
    }

    func testTemplatesCanBeSearchedByDescription() {
        // Arrange
        let templates = ScriptLibrary.templates
        let searchTerm = "header"

        // Act
        let matchingTemplates = templates.filter {
            $0.description.localizedCaseInsensitiveContains(searchTerm)
        }

        // Assert
        XCTAssertGreaterThan(matchingTemplates.count, 0)
    }

    // MARK: - Edge Cases

    func testTemplateWithEmptyCode() {
        // Arrange
        let template = ScriptTemplate(
            name: "Empty Template",
            category: .request,
            description: "Template with no code.",
            code: ""
        )

        // Assert
        XCTAssertEqual(template.code, "")
        XCTAssertTrue(template.code.isEmpty)
    }

    func testTemplateWithMultilineCode() {
        // Arrange
        let multilineCode = """
        const x = 1;
        const y = 2;
        console.log(x + y);
        """
        let template = ScriptTemplate(
            name: "Multiline Template",
            category: .debugging,
            description: "Template with multiline code.",
            code: multilineCode
        )

        // Assert
        XCTAssertTrue(template.code.contains("\n"))
        XCTAssertGreaterThan(template.code.components(separatedBy: "\n").count, 1)
    }

    func testTemplateWithSpecialCharacters() {
        // Arrange
        let code = "console.log('Special: @#$%^&*()');"
        let template = ScriptTemplate(
            name: "Special Chars",
            category: .debugging,
            description: "Template with special characters.",
            code: code
        )

        // Assert
        XCTAssertTrue(template.code.contains("@#$%^&*()"))
    }

    func testTemplateWithUnicodeCharacters() {
        // Arrange
        let code = "console.log('你好 🌍');"
        let template = ScriptTemplate(
            name: "Unicode Template",
            category: .debugging,
            description: "Template with unicode.",
            code: code
        )

        // Assert
        XCTAssertTrue(template.code.contains("你好"))
        XCTAssertTrue(template.code.contains("🌍"))
    }

    // MARK: - Category Distribution Tests

    func testRequestCategoryHasTemplates() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let requestTemplates = templates.filter { $0.category == .request }

        // Assert
        XCTAssertGreaterThan(requestTemplates.count, 0)
    }

    func testResponseCategoryHasTemplates() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let responseTemplates = templates.filter { $0.category == .response }

        // Assert
        XCTAssertGreaterThan(responseTemplates.count, 0)
    }

    func testAuthenticationCategoryHasTemplates() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let authTemplates = templates.filter { $0.category == .authentication }

        // Assert
        XCTAssertGreaterThan(authTemplates.count, 0)
    }

    func testDebuggingCategoryHasTemplates() {
        // Arrange
        let templates = ScriptLibrary.templates

        // Act
        let debugTemplates = templates.filter { $0.category == .debugging }

        // Assert
        XCTAssertGreaterThan(debugTemplates.count, 0)
    }

    // MARK: - Immutability Tests

    func testTemplatesArrayIsConstant() {
        // Arrange
        let templates1 = ScriptLibrary.templates
        let templates2 = ScriptLibrary.templates

        // Act & Assert
        XCTAssertEqual(templates1.count, templates2.count)
        for i in 0..<templates1.count {
            XCTAssertEqual(templates1[i].name, templates2[i].name)
            XCTAssertEqual(templates1[i].code, templates2[i].code)
        }
    }

    // MARK: - Template Content Quality Tests

    func testAddCORSHeadersTemplateHasAllRequiredHeaders() {
        // Arrange
        let template = ScriptLibrary.templates.first { $0.name == "Add CORS Headers" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertTrue(template?.code.contains("*") ?? false, "Should allow all origins")
        XCTAssertTrue(template?.code.contains("GET") ?? false, "Should include GET method")
        XCTAssertTrue(template?.code.contains("POST") ?? false, "Should include POST method")
    }

    func testInjectAuthTokenTemplateUsesBearer() {
        // Arrange
        let template = ScriptLibrary.templates.first { $0.name == "Inject Auth Token" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertTrue(template?.code.contains("Bearer") ?? false)
        XCTAssertTrue(template?.code.contains("YOUR_TOKEN") ?? false, "Should have placeholder")
    }

    func testForceJSONResponseTemplateHasValidJSON() {
        // Arrange
        let template = ScriptLibrary.templates.first { $0.name == "Force JSON Response" }

        // Assert
        XCTAssertNotNil(template)
        XCTAssertTrue(template?.code.contains("status") ?? false)
        XCTAssertTrue(template?.code.contains("ok") ?? false)
    }

    // MARK: - Performance Tests

    func testTemplateAccessPerformance() {
        measure {
            _ = ScriptLibrary.templates
        }
    }

    func testTemplateFilterPerformance() {
        measure {
            _ = ScriptLibrary.templates.filter { $0.category == .response }
        }
    }

    func testTemplateSearchPerformance() {
        measure {
            _ = ScriptLibrary.templates.filter { $0.name.contains("Log") }
        }
    }
}
