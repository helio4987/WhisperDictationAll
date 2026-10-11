import XCTest
@testable import WhisperDictation

// MARK: - OperationTemplate.makeOperation (pure, no network)

final class OperationTemplateTests: XCTestCase {
    func testMakeOperationCopiesPromptFramingAndLeavesHotkeyAndModelUnassigned() {
        let template = OperationTemplate(
            id: "fix-grammar",
            name: "Fix Grammar",
            description: "Corrects grammar and spelling.",
            prependEnabled: true,
            prependText: "Fix the grammar in the following text:",
            appendEnabled: true,
            appendText: "Respond with only the corrected text.",
            recommendedModelHint: "Works well with any Q4_K_M instruct model."
        )

        let operation = template.makeOperation()

        XCTAssertEqual(operation.name, "Fix Grammar")
        XCTAssertTrue(operation.prependEnabled)
        XCTAssertEqual(operation.prependText, "Fix the grammar in the following text:")
        XCTAssertTrue(operation.appendEnabled)
        XCTAssertEqual(operation.appendText, "Respond with only the corrected text.")
        XCTAssertEqual(operation.hotkeyKeyCode, 0)
        XCTAssertFalse(operation.hasHotkey)
        XCTAssertNil(operation.modelVariantId)
    }

    func testMakeOperationWithNoHintStillWorks() {
        let template = OperationTemplate(
            id: "summarize",
            name: "Summarize",
            description: "Shortens the selection.",
            prependEnabled: true,
            prependText: "Summarize this:",
            appendEnabled: false,
            appendText: "",
            recommendedModelHint: nil
        )

        let operation = template.makeOperation()

        XCTAssertEqual(operation.name, "Summarize")
        XCTAssertFalse(operation.appendEnabled)
    }
}

// MARK: - TemplatesFile decoding (pure, no network)

final class TemplatesFileDecodingTests: XCTestCase {
    func testDecodesWellFormedFile() throws {
        let json = """
        {
            "schemaVersion": 1,
            "templates": [
                {
                    "id": "fix-grammar",
                    "name": "Fix Grammar",
                    "description": "Corrects grammar and spelling.",
                    "prependEnabled": true,
                    "prependText": "Fix the grammar in the following text:",
                    "appendEnabled": false,
                    "appendText": "",
                    "recommendedModelHint": "Works well with any Q4_K_M instruct model."
                }
            ]
        }
        """
        let file = try JSONDecoder().decode(TemplatesFile.self, from: Data(json.utf8))

        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.templates.count, 1)
        XCTAssertEqual(file.templates.first?.id, "fix-grammar")
    }

    func testDecodesEmptyTemplatesArray() throws {
        let json = """
        { "schemaVersion": 1, "templates": [] }
        """
        let file = try JSONDecoder().decode(TemplatesFile.self, from: Data(json.utf8))
        XCTAssertTrue(file.templates.isEmpty)
    }

    func testDecodesTemplateWithoutRecommendedModelHint() throws {
        let json = """
        {
            "schemaVersion": 1,
            "templates": [
                {
                    "id": "fix-grammar",
                    "name": "Fix Grammar",
                    "description": "Corrects grammar and spelling.",
                    "prependEnabled": true,
                    "prependText": "Fix the grammar in the following text:",
                    "appendEnabled": false,
                    "appendText": ""
                }
            ]
        }
        """
        let file = try JSONDecoder().decode(TemplatesFile.self, from: Data(json.utf8))
        XCTAssertNil(file.templates.first?.recommendedModelHint)
    }
}

// MARK: - OperationTemplateCatalog (schema version gate + fetch/cache, mocked network)

/// Minimal URLProtocol-based stub so `OperationTemplateCatalog.refresh()` can
/// be exercised against controlled responses without a real network call.
private final class StubURLProtocol: URLProtocol {
    static var responseData: Data?
    static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class OperationTemplateCatalogTests: XCTestCase {
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testRefreshPopulatesTemplatesFromWellFormedResponse() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data("""
        {
            "schemaVersion": 1,
            "templates": [
                {
                    "id": "fix-grammar",
                    "name": "Fix Grammar",
                    "description": "Corrects grammar and spelling.",
                    "prependEnabled": true,
                    "prependText": "Fix the grammar in the following text:",
                    "appendEnabled": false,
                    "appendText": ""
                }
            ]
        }
        """.utf8)

        let catalog = OperationTemplateCatalog(session: stubbedSession())
        await catalog.refresh()

        XCTAssertEqual(catalog.templates.map(\.id), ["fix-grammar"])
        XCTAssertNil(catalog.fetchError)
        XCTAssertNotNil(catalog.lastFetched)
    }

    func testRefreshRejectsUnsupportedSchemaVersionWithoutClearingPreviousList() async {
        // First, a successful fetch to populate a baseline list.
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data("""
        { "schemaVersion": 1, "templates": [
            { "id": "a", "name": "A", "description": "d", "prependEnabled": false, "prependText": "", "appendEnabled": false, "appendText": "" }
        ] }
        """.utf8)
        let catalog = OperationTemplateCatalog(session: stubbedSession())
        await catalog.refresh()
        XCTAssertEqual(catalog.templates.count, 1)

        // Then a refresh that reports a newer schema version than this build
        // understands — must surface an error and leave the previous list
        // in place, same "don't blank out a working list on a bad refresh"
        // policy as TextModelCatalog.refresh().
        StubURLProtocol.responseData = Data("""
        { "schemaVersion": 999, "templates": [] }
        """.utf8)
        await catalog.refresh()

        XCTAssertNotNil(catalog.fetchError)
        XCTAssertEqual(catalog.templates.count, 1, "previous list must survive a rejected refresh")
    }

    func testRefreshSurfacesErrorOnBadHTTPStatusWithoutClearingPreviousList() async {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseData = Data("""
        { "schemaVersion": 1, "templates": [
            { "id": "a", "name": "A", "description": "d", "prependEnabled": false, "prependText": "", "appendEnabled": false, "appendText": "" }
        ] }
        """.utf8)
        let catalog = OperationTemplateCatalog(session: stubbedSession())
        await catalog.refresh()
        XCTAssertEqual(catalog.templates.count, 1)

        StubURLProtocol.statusCode = 404
        StubURLProtocol.responseData = Data()
        await catalog.refresh()

        XCTAssertNotNil(catalog.fetchError)
        XCTAssertEqual(catalog.templates.count, 1)
    }
}
