import XCTest
@testable import OpenCode_Bar

private final class AntigravityTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AntigravityProviderVarintTests: XCTestCase {
    private let provider = AntigravityProvider()

    override func tearDown() {
        AntigravityTestURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AntigravityTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testFetchAvailableModelsUsesAntigravityQuotaEndpointAndHeaders() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        AntigravityTestURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                AntigravityQuotaAPI.userAgent
            )
            XCTAssertTrue(AntigravityQuotaAPI.userAgent.contains("Antigravity/1.18.3"))

            let requestData = try XCTUnwrap(Self.requestBodyData(from: request))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestData) as? [String: String]
            )
            XCTAssertEqual(payload, ["project": "test-cloud-project"])

            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let data = Data(#"{"models":{"gemini-3-pro":{"quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-10-05T15:00:00Z"}}}}"#.utf8)
            return (response, data)
        }

        let result = try await AntigravityQuotaAPI.fetchAvailableModels(
            accessToken: "test-access-token",
            projectId: "test-cloud-project",
            session: session
        )

        XCTAssertEqual(result.models?.count, 1)
        XCTAssertEqual(result.models?["gemini-3-pro"]?.quotaInfo?.remainingFraction, 0.75)
    }

    func testFetchAvailableModelsPreservesForbiddenStatus() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        AntigravityTestURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)
            )
            return (response, Data())
        }

        do {
            _ = try await AntigravityQuotaAPI.fetchAvailableModels(
                accessToken: "test-access-token",
                projectId: "test-cloud-project",
                session: session
            )
            XCTFail("Expected an HTTP 403 error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("403"))
        }
    }

    func testParseAvailableModelsReadsRemainingFractionsAndResetTimes() throws {
        let response = try JSONDecoder().decode(
            AntigravityAvailableModelsResponse.self,
            from: Data(#"{"models":{"gemini-3-pro":{"quotaInfo":{"remainingFraction":0.75,"resetTime":"2026-10-05T15:00:00Z"},"displayName":"Gemini 3 Pro"},"claude-opus-4-6":{"quotaInfo":{"remainingFraction":1.2}},"unavailable-model":{"displayName":"No quota"}}}"#.utf8)
        )

        let parsed = AntigravityProvider.parseAvailableModels(response.models ?? [:])

        XCTAssertEqual(parsed.modelBreakdown["gemini-3-pro"], 75.0)
        XCTAssertEqual(parsed.modelBreakdown["claude-opus-4-6"], 100.0)
        XCTAssertNil(parsed.modelBreakdown["unavailable-model"])
        XCTAssertNotNil(parsed.modelResetTimes["gemini-3-pro"])
        XCTAssertNil(parsed.modelResetTimes["claude-opus-4-6"])
    }

    func testAntigravityProjectPolicyPrefersManagedProject() {
        XCTAssertEqual(
            AntigravityProjectPolicy.resolve(
                managedProjectId: "managed-project",
                projectId: "configured-project"
            ),
            "managed-project"
        )
    }

    func testAntigravityProjectPolicyFallsBackToConfiguredProject() {
        XCTAssertEqual(
            AntigravityProjectPolicy.resolve(managedProjectId: nil, projectId: "configured-project"),
            "configured-project"
        )
    }

    func testAntigravityProjectPolicyUsesPluginFallbackWhenProjectIdsAreMissing() {
        XCTAssertEqual(
            AntigravityProjectPolicy.resolve(managedProjectId: nil, projectId: nil),
            AntigravityProjectPolicy.fallbackProjectId
        )
    }

    func testReadVarintBoundaryValues() throws {
        try assertVarintRoundTrip(0)
        try assertVarintRoundTrip(1)
        try assertVarintRoundTrip(127)
        try assertVarintRoundTrip(128)
        try assertVarintRoundTrip(300)
    }

    func testReadVarintMaxUInt64() throws {
        let bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        var index = 0
        let decoded = try provider.readVarint(from: bytes, index: &index)
        XCTAssertEqual(decoded, UInt64.max)
        XCTAssertEqual(index, bytes.count)
    }

    func testReadVarintThrowsOnTruncatedInput() {
        let bytes: [UInt8] = [0x80]
        var index = 0
        XCTAssertThrowsError(try provider.readVarint(from: bytes, index: &index))
    }

    func testParseProtobufMessageParsesVarintAndLengthDelimited() throws {
        let payload = Data([0x08, 0x96, 0x01, 0x12, 0x03, 0x61, 0x62, 0x63])
        let message = try provider.parseProtobufMessage(payload)

        guard let field1 = message[1]?.first else {
            XCTFail("Missing field 1")
            return
        }

        guard let field2 = message[2]?.first else {
            XCTFail("Missing field 2")
            return
        }

        switch field1 {
        case .varint(let value):
            XCTAssertEqual(value, 150)
        default:
            XCTFail("Expected varint for field 1")
        }

        switch field2 {
        case .lengthDelimited(let data):
            XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
        default:
            XCTFail("Expected length-delimited for field 2")
        }
    }

    func testParseProtobufMessageThrowsOnUnsupportedWireType() {
        let payload = Data([0x0F])
        XCTAssertThrowsError(try provider.parseProtobufMessage(payload))
    }

    func testParseProtobufMessageThrowsOnMalformedLengthDelimitedField() {
        let payload = Data([0x12, 0x05, 0x61])
        XCTAssertThrowsError(try provider.parseProtobufMessage(payload))
    }

    func testFallbackAccountSelectionSkipsStalePreferredAccount() throws {
        let staleAccount = AntigravityAccounts.Account(
            email: "stale@example.com",
            refreshToken: " ",
            projectId: nil,
            managedProjectId: nil,
            enabled: true
        )
        let validAccount = AntigravityAccounts.Account(
            email: "valid@example.com",
            refreshToken: "valid-refresh-token",
            projectId: nil,
            managedProjectId: nil,
            enabled: true
        )
        let accounts = AntigravityAccounts(
            version: 4,
            accounts: [staleAccount, validAccount],
            activeIndex: 0,
            activeIndexByFamily: ["gemini": 0]
        )

        let selected = try XCTUnwrap(AntigravityProvider.selectFallbackAccount(from: accounts))
        XCTAssertEqual(selected.email, "valid@example.com")
        XCTAssertEqual(selected.refreshToken, "valid-refresh-token")
    }

    private func assertVarintRoundTrip(_ expected: UInt64) throws {
        let encoded = encodeVarint(expected)
        var index = 0
        let decoded = try provider.readVarint(from: encoded, index: &index)
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(index, encoded.count)
    }

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []

        repeat {
            var nextByte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                nextByte |= 0x80
            }
            bytes.append(nextByte)
        } while remaining != 0

        return bytes
    }
}
