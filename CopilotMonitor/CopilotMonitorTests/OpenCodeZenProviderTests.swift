import XCTest
@testable import OpenCode_Bar

final class OpenCodeZenProviderTests: XCTestCase {

    func testParseAlibabaTokenPlanActivityMetricsAndProviderPrefix() {
        let fixture = #"""
        │ MODEL USAGE │
        │ alibaba-token-plan/qwen3.8-max │
        │ Messages 12 │
        │ Input Tokens 12.5K │
        │ Output Tokens 1.2K │
        │ Cache Read 3M │
        │ Cache Write 45 │
        │ qwen/qwen3.8-max │
        │ Messages 99 │
        │ alibaba-token-plan/qwen3.8-flash │
        │ Messages 4 │
        │ Input Tokens 2K │
        │ Output Tokens 500 │
        │ Cache Read 0 │
        │ Cache Write 1K │
        """#
        let parsed = OpenCodeZenProvider.parseAlibabaActivity(from: fixture)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed["alibaba-token-plan/qwen3.8-max"], .init(messages: 12, inputTokens: 12_500, outputTokens: 1_200, cacheReadTokens: 3_000_000, cacheWriteTokens: 45))
        XCTAssertEqual(parsed["alibaba-token-plan/qwen3.8-flash"], .init(messages: 4, inputTokens: 2_000, outputTokens: 500, cacheReadTokens: 0, cacheWriteTokens: 1_000))
        XCTAssertTrue(OpenCodeZenProvider.parseAlibabaActivity(from: "").isEmpty)
        XCTAssertTrue(OpenCodeZenProvider.hasModelUsageSection(in: fixture))
    }

    func testModelUsageSectionDetectionRejectsUnrecognizedStatsOutput() {
        XCTAssertTrue(OpenCodeZenProvider.hasModelUsageSection(in: "│ MODEL USAGE │"))
        XCTAssertFalse(OpenCodeZenProvider.hasModelUsageSection(in: "│ TOTAL COST │"))
    }

    func testParseModelCostsReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Input Tokens                                    12.5M │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ opencode-go/kimi-k2.6                                  │
        │  Messages                                           18 │
        │  Input Tokens                                   410.6K │
        │  Cost                                          $0.2251 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertEqual(modelCosts["opencode-go/kimi-k2.6"], 0.2251)
        XCTAssertEqual(modelCosts.count, 2)
    }

    func testParseModelMessagesReadsCurrentMultilineStatsFormat() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │ openrouter/google/gemini-3-flash-preview               │
        │  Messages                                           26 │
        │  Cost                                          $0.5563 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelMessages = OpenCodeZenProvider.parseModelMessages(from: output)

        XCTAssertEqual(modelMessages["opencode/gpt-5.5"], 2_871)
        XCTAssertEqual(modelMessages["openrouter/google/gemini-3-flash-preview"], 26)
        XCTAssertEqual(modelMessages.count, 2)
    }

    func testParseModelCostsIgnoresCostRowsOutsideModelUsageSection() {
        let output = #"""
        ┌────────────────────────────────────────────────────────┐
        │                      MODEL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ opencode/gpt-5.5                                       │
        │  Messages                                        2,871 │
        │  Cost                                        $215.2045 │
        ├────────────────────────────────────────────────────────┤
        │                       TOOL USAGE                       │
        ├────────────────────────────────────────────────────────┤
        │ mcp-server                                             │
        │  Calls                                                4 │
        │  Cost                                          $1.2300 │
        └────────────────────────────────────────────────────────┘
        """#

        let modelCosts = OpenCodeZenProvider.parseModelCosts(from: output)

        XCTAssertEqual(modelCosts["opencode/gpt-5.5"], 215.2045)
        XCTAssertNil(modelCosts["mcp-server"])
        XCTAssertEqual(modelCosts.count, 1)
    }

    func testAdjustStatsForDisplayKeepsOnlyOpenCodeZenProviderPrefixes() {
        let modelCosts = [
            "opencode/gpt-5.5": 2.0,
            "opencode-go/minimax-m2.7": 4.0,
            "anthropic/claude-opus-4-7": 15.0,
            "openrouter/google/gemini-3-flash-preview": 9.0,
            "openai/gpt-5.5-fast": 0.0
        ]
        let modelMessages = [
            "opencode/gpt-5.5": 1,
            "opencode-go/minimax-m2.7": 159,
            "anthropic/claude-opus-4-7": 2_848,
            "openrouter/google/gemini-3-flash-preview": 26
        ]

        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 30.0,
            avgCostPerDay: 10.0,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )

        XCTAssertEqual(adjusted.excludedCost, 24.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 6.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 2.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 160)
        XCTAssertEqual(adjusted.modelCosts.keys.sorted(), [
            "opencode-go/minimax-m2.7",
            "opencode/gpt-5.5"
        ])
    }

    func testAdjustStatsForDisplayReturnsZeroWhenStatsHaveNoZenModels() {
        let adjusted = OpenCodeZenProvider.adjustStatsForDisplay(
            totalCost: 22.0,
            avgCostPerDay: 3.142857,
            modelCosts: [
                "openai/gpt-5.4": 11.2679,
                "openai/gpt-5.4-mini": 3.7001,
                "nano-gpt/minimax/minimax-m2.5": 4.2045,
                "nano-gpt/zai-org/glm-5:thinking": 1.6042
            ]
        )

        XCTAssertEqual(adjusted.excludedCost, 22.0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.totalCost, 0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.avgCostPerDay, 0, accuracy: 0.0001)
        XCTAssertEqual(adjusted.messages, 0)
        XCTAssertTrue(adjusted.modelCosts.isEmpty)
    }

    func testIsOpenCodeZenModelMatchesOnlyZenProviderPrefixes() {
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel("opencode/gpt-5.5"))
        XCTAssertTrue(OpenCodeZenProvider.isOpenCodeZenModel(" opencode-go/minimax-m2.7 "))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openai/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("openrouter/opencode/gpt-5.5"))
        XCTAssertFalse(OpenCodeZenProvider.isOpenCodeZenModel("nano-gpt/minimax/minimax-m2.5"))
    }

    func testParseETimeSecondsParsesMinutesHoursAndDaysFormats() {
        let cases: [(String, Int?)] = [
            ("03:14", 194),
            ("01:02:03", 3_723),
            ("2-01:05:30", 176_730)
        ]

        for (value, expected) in cases {
            XCTAssertEqual(OpenCodeZenProvider.parseETimeSeconds(value), expected, "value: \(value)")
        }
    }

    func testParseETimeSecondsReturnsNilForMalformedInput() {
        for value in ["03", "garbage", ""] {
            XCTAssertNil(OpenCodeZenProvider.parseETimeSeconds(value), "value: \(value)")
        }
    }

    func testStaleOpenCodeStatsPIDsIncludesOnlyStaleOpenCodeStatsLines() {
        // Mirrors real `ps -axo pid=,etime=,command=` output: a stale hung stats run
        // (123), a fresh healthy one (124), a stale one that is our own pid (125, must
        // be excluded so we never kill ourselves), an unrelated process with a huge argv
        // (126), `ps` itself (127), an unrelated "opencode" subcommand that isn't
        // "stats" (128), and malformed/empty lines that must be skipped, not crash.
        let output = #"""
        123 01:00:01 /opt/homebrew/bin/opencode stats --days 7 --models
        124 00:05 /opt/homebrew/bin/opencode stats --days 7
        125 02:00:00 /opt/homebrew/bin/opencode stats --days 7 --models
        126 02:00:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer --field-trial-handle=1,i,9999999999999999999,1234567890123456,262144
        127 00:00 /bin/ps -axo pid=,etime=,command=
        128 02:00:00 /opt/homebrew/bin/opencode run something

        129 abc /opt/homebrew/bin/opencode stats --days 7
        weird
        """#

        let staleProcesses = OpenCodeZenProvider.staleOpenCodeStatsPIDs(
            fromPSOutput: output,
            staleThresholdSeconds: 3_600,
            selfPid: 125
        )

        // Tuple arrays aren't Equatable, so compare pids and elapsed seconds separately.
        XCTAssertEqual(staleProcesses.map(\.pid), [123])
        XCTAssertEqual(staleProcesses.map(\.etimeSeconds), [3_601])
    }

    // MARK: - Alibaba quota calibration projection

    /// Real console pair: 0.94% then 2.1% about one hour apart on a Standard
    /// (45,000 Credit) plan. Locks the derived pace, exhaust window and rate.
    @MainActor
    func testAlibabaQuotaProjectionFromConsoleSnapshotPair() {
        let start = Date(timeIntervalSince1970: 0)
        let samples = [
            AlibabaQuotaSample(date: start, percentUsed: 0.94, totalTokens: 16_757_800, nonCacheTokens: 1_357_800, messages: 192),
            AlibabaQuotaSample(date: start.addingTimeInterval(3600), percentUsed: 2.1, totalTokens: 41_266_600, nonCacheTokens: 2_266_600, messages: 261)
        ]

        let projection = AlibabaQuotaCalibration.projection(samples: samples, monthlyQuota: 45_000)
        let result = try? XCTUnwrap(projection)
        XCTAssertNotNil(result)
        guard let result else { return }

        XCTAssertEqual(result.usedCredits, 945.0, accuracy: 0.5)
        XCTAssertEqual(result.remainingCredits, 44_055.0, accuracy: 0.5)
        XCTAssertEqual(result.creditsPerHour ?? 0, 522.0, accuracy: 2.0)
        XCTAssertEqual(result.creditsPerDay ?? 0, 12_528.0, accuracy: 50.0)
        XCTAssertEqual(result.daysToExhaust ?? 0, 3.52, accuracy: 0.05)
        XCTAssertEqual(result.creditsPerMessage ?? 0, 7.57, accuracy: 0.1)
        XCTAssertEqual(result.rateWindowHours ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(result.sampleCount, 2)
    }

    @MainActor
    func testAlibabaQuotaProjectionSingleSampleHasNoPace() {
        let samples = [
            AlibabaQuotaSample(date: Date(timeIntervalSince1970: 0), percentUsed: 0.94, totalTokens: 1_000_000, nonCacheTokens: 500_000, messages: 10)
        ]
        let result = AlibabaQuotaCalibration.projection(samples: samples, monthlyQuota: 45_000)
        XCTAssertNotNil(result?.usedCredits)
        XCTAssertNil(result?.creditsPerDay)
        XCTAssertNil(result?.daysToExhaust)
    }

    @MainActor
    func testAlibabaQuotaCreditsFormattingGroups() {
        XCTAssertEqual(StatusBarController.alibabaQuotaCredits(44055.4), "44,055")
    }
}
