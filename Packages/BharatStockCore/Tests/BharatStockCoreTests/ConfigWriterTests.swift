import Foundation
import Testing
@testable import BharatStockCore

@Suite("Config writing")
struct ConfigWriterTests {
    @Test("Bootstrap creates a 0600 config plus the example and README")
    func bootstrapCreatesFiles() throws {
        let root = TempRoot()
        let writer = ConfigWriter()

        let result = try writer.bootstrap(at: root.paths)
        #expect(result.createdConfig)
        #expect(FileStore().exists(root.paths.config))
        #expect(FileStore().exists(root.paths.configExample))
        #expect(FileStore().exists(root.paths.configReadme))
        #expect(try FileStore().permissions(of: root.paths.config) == FileStore.ownerOnly)

        // The generated file must be readable by our own parser — the obvious way for a
        // hand-rolled serialiser to go wrong.
        let loaded = try ConfigLoader().load(contentsOf: root.paths.config)
        #expect(loaded.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(loaded.configuration.instruments.count == 5)
        #expect(loaded.configuration.refresh.times.count == 2)
        // The default ships with no key: the spec's key is being rotated.
        #expect(loaded.configuration.apiKey.isEmpty)
    }

    @Test("The shipped example file parses cleanly too")
    func exampleParses() throws {
        let result = try ConfigLoader().parse(Data(ConfigWriter.exampleJSON.utf8))
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(result.configuration.instruments.count == 5)
        // The corrected scheme codes, not the spec's wrong ones.
        #expect(result.configuration.instruments.map(\.symbol).contains("122639"))
        #expect(result.configuration.instruments.map(\.symbol).contains("120828"))
        #expect(!result.configuration.instruments.map(\.symbol).contains("120503"))
    }

    @Test("Bootstrap never overwrites an existing config")
    func bootstrapPreservesExistingConfig() throws {
        let root = TempRoot()
        let mine = #"{ "apiKey": "bsk_live_mine", "instruments": [ { "type": "ST", "symbol": "WIPRO" } ] }"#
        try root.writeConfig(mine)

        let result = try ConfigWriter().bootstrap(at: root.paths)
        #expect(!result.createdConfig)
        #expect(try String(decoding: Data(contentsOf: root.paths.config), as: UTF8.self) == mine)
    }

    @Test("Bootstrap re-asserts 0600 on an existing config")
    func bootstrapFixesPermissions() throws {
        let root = TempRoot()
        try root.writeConfig(#"{ "instruments": [] }"#)
        try FileStore().setPermissions(0o644, on: root.paths.config)

        _ = try ConfigWriter().bootstrap(at: root.paths)
        #expect(try FileStore().permissions(of: root.paths.config) == FileStore.ownerOnly)
    }

    @Test("Updating the key leaves the rest of the file untouched")
    func updateAPIKeyIsSurgical() throws {
        let root = TempRoot()
        try root.writeConfig("""
        {
          "apiKey": "old_key",
          "myOwnNote": "please keep me",
          "instruments": [ { "type": "ST", "symbol": "WIPRO" } ]
        }
        """)

        try ConfigWriter().updateAPIKey("bsk_live_brand_new", in: root.paths.config)
        let text = try String(decoding: Data(contentsOf: root.paths.config), as: UTF8.self)

        #expect(text.contains(#""apiKey": "bsk_live_brand_new""#))
        #expect(text.contains("myOwnNote"), "a forward-compatible key the user added must survive")
        #expect(text.contains("WIPRO"))
        #expect(!text.contains("old_key"))
        #expect(try FileStore().permissions(of: root.paths.config) == FileStore.ownerOnly)

        let reloaded = try ConfigLoader().load(contentsOf: root.paths.config)
        #expect(reloaded.configuration.apiKey == "bsk_live_brand_new")
    }

    @Test("A key can be added to a file that has no apiKey field")
    func addsMissingKeyField() throws {
        let root = TempRoot()
        try root.writeConfig(#"{ "instruments": [ { "type": "ST", "symbol": "WIPRO" } ] }"#)

        try ConfigWriter().updateAPIKey("bsk_live_added", in: root.paths.config)
        let reloaded = try ConfigLoader().load(contentsOf: root.paths.config)
        #expect(reloaded.configuration.apiKey == "bsk_live_added")
        #expect(reloaded.configuration.instruments.count == 1)
    }

    @Test("A key containing quotes or backslashes is escaped, not corrupted")
    func escapesAwkwardKeys() throws {
        let root = TempRoot()
        try root.writeConfig(#"{ "apiKey": "", "instruments": [] }"#)

        try ConfigWriter().updateAPIKey(#"we"ird\key"#, in: root.paths.config)
        let reloaded = try ConfigLoader().load(contentsOf: root.paths.config)
        #expect(reloaded.configuration.apiKey == #"we"ird\key"#)
    }

    @Test("The generated README documents every field the loader reads")
    func readmeCoversEveryField() {
        let readme = ConfigWriter.readmeText
        for field in [
            "schemaVersion", "apiKey", "refresh.times", "refresh.timeZone",
            "refresh.maxRequestsPerDay", "display.currencySymbol", "display.maxNameLength",
            "display.showChangePercent", "display.decimalPlaces",
        ] {
            #expect(readme.contains(field), "README does not explain \(field)")
        }
        // §2 requires a plain sentence about the key living in this file.
        #expect(readme.contains("plain text"))
        #expect(readme.contains("0600"))
        // §4 requires two or three worked examples.
        #expect(readme.contains("THREE WORKED EXAMPLES"))
        // F8: the completed-session caveat must be stated where the user will see it.
        #expect(readme.contains("no intraday data"))
    }
}
