import XCTest
@testable import LocalFlowCore

final class EnvLoaderTests: XCTestCase {
    func testParseEnvFile() {
        let env = EnvLoader.parse(
            """
            # ignored
            OPENAI_API_KEY=sk-test
            TRANSCRIPTION_LANGUAGE="fr"
            ENABLE_POLISH=true
            export POLISH_MODEL='gpt-4o-mini'
            EMPTY=
            """
        )

        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-test")
        XCTAssertEqual(env["TRANSCRIPTION_LANGUAGE"], "fr")
        XCTAssertEqual(env["ENABLE_POLISH"], "true")
        XCTAssertEqual(env["POLISH_MODEL"], "gpt-4o-mini")
        XCTAssertEqual(env["EMPTY"], "")
    }

    func testConfigurationDefaultsAndOverrides() {
        let configuration = AppConfiguration(env: [
            "OPENAI_API_KEY": "sk-test",
            "ENABLE_POLISH": "yes",
            "HISTORY_RETENTION_DAYS": "14",
            "PASTE_RESTORE_DELAY_MS": "1200"
        ])

        XCTAssertTrue(configuration.isOpenAIConfigured)
        XCTAssertEqual(configuration.transcriptionModel, "gpt-4o-transcribe")
        XCTAssertEqual(configuration.transcriptionLanguage, "fr")
        XCTAssertTrue(configuration.enablePolish)
        XCTAssertEqual(configuration.historyRetentionDays, 14)
        XCTAssertEqual(configuration.pasteRestoreDelayMilliseconds, 1200)
    }
}
