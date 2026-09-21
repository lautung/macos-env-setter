import Testing
import Foundation
@testable import EnvSetterCore

private extension Array where Element == ManagedEntry {
    func record(named key: String) -> VariableRecord? {
        compactMap { entry -> VariableRecord? in
            if case .record(let record) = entry { return record }
            return nil
        }.first { $0.key == key }
    }
}

/// 「秘密值」标记：只影响界面打码，属于本地状态——不进标记块、不参与漂移，且改一次存一次。
struct SecretFlagTests {
    @Test func missingFieldDecodesAsNotSecret() throws {
        // 早期 store.json 没有 secret 字段：把编码结果里的该字段摘掉，模拟旧文件。
        let data = try JSONEncoder().encode(VariableRecord(key: "A", rawValue: "1"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "secret")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(VariableRecord.self, from: stripped)
        #expect(decoded.key == "A")
        #expect(decoded.secret == false)
    }

    @Test func secretSurvivesStoreRoundTrip() throws {
        let (home, _) = try TestSupport.makeSandbox()
        let store = EnvStore(entries: [.record(VariableRecord(key: "TOKEN", rawValue: "x", secret: true))])
        let url = home.appending(path: "store.json")
        try StorePersistence.save(store, to: url)
        #expect(try StorePersistence.load(from: url) == store)
        #expect(try StorePersistence.load(from: url).entries.record(named: "TOKEN")?.secret == true)
    }

    /// 漂移重载以文件为准改值，但打码标记是本地状态，必须留住——否则手工改一次块内内容就把打码丢了。
    @Test func driftReloadKeepsSecretFlag() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        try engine.apply(entries: [
            .record(VariableRecord(key: "TOKEN", rawValue: "1", secret: true)),
            .record(VariableRecord(key: "PLAIN", rawValue: "2")),
        ])

        let content = try TestSupport.read(paths.zprofileURL)
        try TestSupport.write(
            content.replacingOccurrences(of: #"export TOKEN="1""#, with: #"export TOKEN="9""#),
            to: paths.zprofileURL
        )

        let result = try engine.load()
        #expect(result.driftDetected)
        #expect(result.entries.record(named: "TOKEN")?.rawValue == "9")
        #expect(result.entries.record(named: "TOKEN")?.secret == true)
        #expect(result.entries.record(named: "PLAIN")?.secret == false)
    }

    /// 用户手工往块里加的一行凭据，重载时按导入处理并默认打码。
    @Test func handAddedCredentialLinesAreMarkedSecret() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        try engine.apply(entries: [.record(VariableRecord(key: "A", rawValue: "1"))])

        let content = try TestSupport.read(paths.zprofileURL)
        try TestSupport.write(
            content.replacingOccurrences(
                of: MarkerBlock.endMarker,
                with: #"export STRIPE_SECRET_KEY="sk_live_x""# + "\n" + MarkerBlock.endMarker
            ),
            to: paths.zprofileURL
        )

        let result = try engine.load()
        #expect(result.entries.record(named: "STRIPE_SECRET_KEY")?.secret == true)
        #expect(result.entries.record(named: "STRIPE_SECRET_KEY")?.source == .adopted)
    }

    @Test func adoptionMarksCredentialLookingKeys() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        try TestSupport.write(
            """
            export TOOLS="/opt/tools"
            export GITHUB_TOKEN="ghp_x"
            export DB_PASSWORD="hunter2"
            export EDITOR="nvim"
            """,
            to: paths.zprofileURL
        )
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        let plan = try engine.planAdoption()

        #expect(plan.entries.record(named: "GITHUB_TOKEN")?.secret == true)
        #expect(plan.entries.record(named: "DB_PASSWORD")?.secret == true)
        #expect(plan.entries.record(named: "TOOLS")?.secret == false)
        #expect(plan.entries.record(named: "EDITOR")?.secret == false)
    }

    @Test func secretFlagIsNotWrittenIntoTheBlock() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        try engine.apply(entries: [.record(VariableRecord(key: "TOKEN", rawValue: "1", secret: true))])

        let content = try TestSupport.read(paths.zprofileURL)
        #expect(content.contains(#"export TOKEN="1""#))
        #expect(!content.lowercased().contains("secret"))
    }

    @Test func setSecretFlagsOnlyTouchesLocalState() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        _ = try engine.load()
        try engine.apply(entries: [.record(VariableRecord(key: "TOKEN", rawValue: "1"))])
        let before = try TestSupport.read(paths.zprofileURL)
        let snapshotBefore = try StorePersistence.load(from: paths.storeURL).blockSnapshot

        try engine.setSecretFlags(["TOKEN": true, "NOT_THERE": true])

        // 标记块与漂移基准都没动：打码不是两层的内容
        #expect(try TestSupport.read(paths.zprofileURL) == before)
        let store = try StorePersistence.load(from: paths.storeURL)
        #expect(store.blockSnapshot == snapshotBefore)
        #expect(store.entries.record(named: "TOKEN")?.secret == true)
        #expect(try engine.checkDrift() == false)
    }

    /// 本地状态还不存在时（尚未应用过任何东西）静默跳过：标记会随下一次应用落盘。
    @Test func setSecretFlagsOnMissingStoreIsANoOp() throws {
        let (_, paths) = try TestSupport.makeSandbox()
        let engine = EnvSetterEngine(paths: paths)
        try engine.setSecretFlags(["A": true])
        #expect(!FileManager.default.fileExists(atPath: paths.storeURL.path))
    }
}
