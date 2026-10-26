//
//  D007AutosaveTests.swift
//  週献立めも
//
//  D-007：autosaveEnabled = false の動作の検証
//  technical-design 4.1・4.4
//

import XCTest
import SwiftData
import SQLite3
import UIKit

// 検証専用のモデル。アプリ本体のモデルではない。
@Model
final class D007Record {
    var label: String
    var value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// ModelContext.didSave 通知の受信回数を数える（記録用）
private final class SaveNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@MainActor
final class D007AutosaveTests: XCTestCase {

    private static let label = "D007"
    private static let initialValue = "initial"
    private static let changedValue = "changed"
    // 自動保存が起きる機会を与えるため、メインのRunLoopを回す時間（秒）
    private static let waitSeconds: TimeInterval = 3

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("D007-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    // 保存先はテスト終了後も削除しない。テスト中に作ったコンテナが破棄される前にファイルを削除すると、
    // SQLiteが使用中のファイルを削除したことになるため（保存先はシミュレーター内のアプリの一時ディレクトリ）。

    private func makeContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: D007Record.self, configurations: configuration)
    }

    // 初期値を保存する（このコンテナはブロックを抜けると破棄される）
    private func seed(url: URL) throws {
        let container = try makeContainer(url: url)
        let context = ModelContext(container)
        context.insert(D007Record(label: Self.label, value: Self.initialValue))
        try context.save()
    }

    // 別のModelContainer（別の永続ストア接続）で開いて読み直す
    private func valueFromNewContainer(url: URL) throws -> String? {
        let container = try makeContainer(url: url)
        return try ModelContext(container).fetch(FetchDescriptor<D007Record>()).first?.value
    }

    private func waitOnMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(Self.waitSeconds))
    }

    // アプリのバックグラウンド移行を模した通知（実際の移行ではない）
    private func postBackgroundNotifications() {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        waitOnMainRunLoop()
    }

    func testChangesAreNotSavedUntilExplicitSaveWhenAutosaveDisabled() throws {
        let url = storeDirectory.appendingPathComponent("autosave-off.store")
        try seed(url: url)

        let container = try makeContainer(url: url)
        let context = container.mainContext
        var lines = [
            "[D-007] autosaveEnabled = false",
            "保存先: \(url.path)",
            "コンテキスト: container.mainContext（既定のautosaveEnabled=\(context.autosaveEnabled)）",
        ]
        context.autosaveEnabled = false

        // didSave 通知は記録のみ。今回の検証構成では受信を確認できず、原因は特定できていないため、合否には使わない
        let saveNotifications = SaveNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { _ in saveNotifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D007Record>()).first)
        XCTAssertEqual(item.value, Self.initialValue)
        item.value = Self.changedValue
        XCTAssertTrue(context.hasChanges)

        // save()前：RunLoopを回したあと
        waitOnMainRunLoop()
        let afterWait = try valueFromNewContainer(url: url)
        let afterWaitSQLite = sqliteValue(storeURL: url)
        lines.append("save()前・\(Int(Self.waitSeconds))秒待機後: 新コンテナ=\(afterWait ?? "nil") SQLite=\(afterWaitSQLite ?? "nil") didSave通知=\(saveNotifications.count)回 hasChanges=\(context.hasChanges)")
        XCTAssertEqual(afterWait, Self.initialValue)
        XCTAssertEqual(afterWaitSQLite, Self.initialValue)

        // save()前：バックグラウンド移行の通知を送ったあと
        postBackgroundNotifications()
        let afterBackground = try valueFromNewContainer(url: url)
        let afterBackgroundSQLite = sqliteValue(storeURL: url)
        lines.append("save()前・バックグラウンド通知後: 新コンテナ=\(afterBackground ?? "nil") SQLite=\(afterBackgroundSQLite ?? "nil") didSave通知=\(saveNotifications.count)回 hasChanges=\(context.hasChanges)")
        XCTAssertEqual(afterBackground, Self.initialValue)
        XCTAssertEqual(afterBackgroundSQLite, Self.initialValue)
        XCTAssertTrue(context.hasChanges)

        // 明示的なsave()
        try context.save()
        let afterSave = try valueFromNewContainer(url: url)
        let afterSaveSQLite = sqliteValue(storeURL: url)
        lines.append("save()後: 新コンテナ=\(afterSave ?? "nil") SQLite=\(afterSaveSQLite ?? "nil") didSave通知=\(saveNotifications.count)回 hasChanges=\(context.hasChanges)")
        XCTAssertEqual(afterSave, Self.changedValue)
        XCTAssertEqual(afterSaveSQLite, Self.changedValue)
        XCTAssertFalse(context.hasChanges)

        record(lines)
    }

    // 対照：autosaveEnabled = true のまま save() を呼ばない場合を記録する。
    // 自動保存の時機はSwiftDataの内部動作のため、結果は記録のみで合否に使わない。
    func testAutosaveEnabledControl() throws {
        let url = storeDirectory.appendingPathComponent("autosave-on.store")
        try seed(url: url)

        let container = try makeContainer(url: url)
        let context = container.mainContext
        context.autosaveEnabled = true

        // didSave 通知は記録のみ。今回の検証構成では受信を確認できず、原因は特定できていないため、合否には使わない
        let saveNotifications = SaveNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { _ in saveNotifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D007Record>()).first)
        item.value = Self.changedValue

        waitOnMainRunLoop()
        let afterWait = try valueFromNewContainer(url: url)
        let afterWaitSQLite = sqliteValue(storeURL: url)

        record([
            "[D-007 対照] autosaveEnabled = true、save()を呼ばない",
            "保存先: \(url.path)",
            "\(Int(Self.waitSeconds))秒待機後: 新コンテナ=\(afterWait ?? "nil") SQLite=\(afterWaitSQLite ?? "nil") didSave通知=\(saveNotifications.count)回 hasChanges=\(context.hasChanges)",
        ])
    }

    // SQLiteファイルを直接読み、保存されている値を確認する
    private func sqliteValue(storeURL: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZVALUE FROM ZD007RECORD WHERE ZLABEL = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, Self.label, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func record(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
