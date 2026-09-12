import Testing
import Foundation
@testable import EnvSetterCore

struct BackupManagerTests {
    private func makeManager() throws -> (BackupManager, URL, String) {
        let (home, paths) = try TestSupport.makeSandbox()
        let content = "export A=\"1\"\n"
        try TestSupport.write(content, to: paths.zprofileURL)
        let manager = BackupManager(backupsDirectory: paths.backupsDirectory)
        return (manager, home, content)
    }

    @Test func baselineCreatedOnceAndNeverPruned() throws {
        let (manager, _, content) = try makeManager()
        #expect(try manager.ensureBaseline(currentContent: content) == true)
        #expect(try manager.ensureBaseline(currentContent: "changed") == false)

        let baselineURL = manager.backupsDirectory.appending(path: BackupManager.baselineFileName)
        #expect(try TestSupport.read(baselineURL) == content)

        // 轮转 30 份，基线仍在
        for index in 0..<30 {
            _ = try manager.timestampedBackup(currentContent: "v\(index)")
        }
        let list = try manager.list()
        #expect(list.filter { !$0.isBaseline }.count == BackupManager.retentionCount)
        #expect(list.filter(\.isBaseline).count == 1)
        #expect(try TestSupport.read(baselineURL) == content)
    }

    @Test func noBaselineWhenFileMissing() throws {
        let (manager, _, _) = try makeManager()
        #expect(try manager.ensureBaseline(currentContent: nil) == false)
        #expect(try manager.timestampedBackup(currentContent: nil) == nil)
        #expect(try manager.list().isEmpty)
    }

    @Test func timestampedBackupStoresContentAndParsesDate() throws {
        let (manager, _, content) = try makeManager()
        let url = try manager.timestampedBackup(currentContent: content)!
        #expect(try TestSupport.read(url) == content)
        let list = try manager.list()
        #expect(list.count == 1)
        #expect(list.first?.date != nil)
        #expect(list.first?.isBaseline == false)
    }

    @Test func readRejectsPathsOutsideBackupsDirectory() throws {
        let (manager, home, content) = try makeManager()
        let sneaky = home.appending(path: "not-a-backup.zprofile")
        try TestSupport.write(content, to: sneaky)
        #expect(throws: EngineError.backupNotFound(sneaky.path)) {
            _ = try manager.read(url: sneaky)
        }
    }

    @Test func listIsEmptyWhenDirectoryMissing() throws {
        let (manager, _, _) = try makeManager()
        #expect(try manager.list().isEmpty)
    }
}
