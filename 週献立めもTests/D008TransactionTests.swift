//
//  D008TransactionTests.swift
//  週献立めも
//
//  D-008：transaction(block:) の動作の検証
//  technical-design 4.1・4.4
//
//  動作を記録するテスト。transaction(block:) の動作（保存されるか、取り消されるか）は
//  合否に使わず、テスト結果の添付に記録する。合否に使うのは、検証の前提（初期データの保存）だけ。
//

import XCTest
import SwiftData
import SQLite3

// 検証専用のモデル。アプリ本体のモデルではない。
@Model
final class D008Record {
    var label: String
    var value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// transaction(block:) のブロック内で意図的に投げる、検証用のエラー
private enum D008IntentionalError: Error {
    case thrownInsideTransactionBlock
}

@MainActor
final class D008TransactionTests: XCTestCase {

    private static let label = "D008"
    private static let insertedLabel = "D008-inserted"
    private static let initialValue = "initial"
    private static let beforeTransactionValue = "beforeTransaction"
    private static let insideTransactionValue = "insideTransaction"

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("D008-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    // 保存先はテスト終了後も削除しない（D-007と同じ理由。使用中のSQLiteファイルを削除しないため）。

    private func makeContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: D008Record.self, configurations: configuration)
    }

    // 初期値を保存し、ディスク上にあることを確認する（検証の前提）
    private func seed(url: URL) throws {
        do {
            let container = try makeContainer(url: url)
            let context = ModelContext(container)
            context.insert(D008Record(label: Self.label, value: Self.initialValue))
            try context.save()
        }
        XCTAssertEqual(try diskRecords(url: url), ["\(Self.label)=\(Self.initialValue)"])
        XCTAssertEqual(sqliteRecords(storeURL: url), ["\(Self.label)=\(Self.initialValue)"])
    }

    // 検証対象の mainContext を用意する（autosaveEnabled = false）
    private func makeMainContext(url: URL) throws -> (ModelContainer, ModelContext, [String]) {
        let container = try makeContainer(url: url)
        let context = container.mainContext
        let lines = [
            "保存先: \(url.path)",
            "コンテキスト: container.mainContext（既定のautosaveEnabled=\(context.autosaveEnabled)）→ falseに設定",
        ]
        context.autosaveEnabled = false
        return (container, context, lines)
    }

    // 別のModelContainer（別の永続ストア接続）で開いて読み直す
    private func diskRecords(url: URL) throws -> [String] {
        let container = try makeContainer(url: url)
        return try ModelContext(container).fetch(FetchDescriptor<D008Record>())
            .map { "\($0.label)=\($0.value)" }
            .sorted()
    }

    // 検証対象のコンテキストから取得した内容（未保存の変更を含む）
    private func memoryRecords(_ context: ModelContext) -> String {
        do {
            let records = try context.fetch(FetchDescriptor<D008Record>())
            return records.map { "\($0.label)=\($0.value)" }.sorted().description
        } catch {
            return "fetchエラー: \(error)"
        }
    }

    private func describe(_ error: Error?) -> String {
        guard let error else { return "なし" }
        if let intentional = error as? D008IntentionalError {
            return "検証用エラー D008IntentionalError.\(intentional)"
        }
        return "その他のエラー \(type(of: error)): \(error)"
    }

    private func state(_ title: String, context: ModelContext, url: URL) -> String {
        let disk = (try? diskRecords(url: url).description) ?? "読み直しエラー"
        return "\(title): メモリ=\(memoryRecords(context)) hasChanges=\(context.hasChanges)"
            + " inserted=\(context.insertedModelsArray.count) changed=\(context.changedModelsArray.count) deleted=\(context.deletedModelsArray.count)"
            + " 新コンテナ=\(disk) SQLite=\(sqliteRecords(storeURL: url))"
    }

    // A：ブロック内で変更し、正常に終える（save()は呼ばない）
    func testA_CompletesNormallyWithoutSave() throws {
        let url = storeDirectory.appendingPathComponent("a.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 A] ブロック内で更新し、正常終了。save()は呼ばない"] + setup
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D008Record>()).first)

        var thrown: Error?
        do {
            try context.transaction {
                item.value = Self.insideTransactionValue
            }
        } catch {
            thrown = error
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))
        lines.append("item.value=\(item.value)")
        record(lines)
        withExtendedLifetime(container) {}
    }

    // B：ブロック内で変更してから検証用エラーを投げる
    func testB_ThrowsInsideBlock() throws {
        let url = storeDirectory.appendingPathComponent("b.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 B] ブロック内で更新してから検証用エラーを投げる"] + setup
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D008Record>()).first)

        let thrown = runThrowingTransaction(context) {
            item.value = Self.insideTransactionValue
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))
        lines.append("item.value=\(item.value)")
        record(lines)
        withExtendedLifetime(container) {}
    }

    // C：ブロックの前に未保存の変更をしておき、ブロック内で検証用エラーを投げる
    func testC_PendingChangeBeforeBlockThenThrow() throws {
        let url = storeDirectory.appendingPathComponent("c.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 C] ブロック前に更新（未保存）、ブロック内でさらに更新してから検証用エラーを投げる"] + setup
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D008Record>()).first)

        item.value = Self.beforeTransactionValue
        lines.append(state("ブロック前の変更後", context: context, url: url))

        let thrown = runThrowingTransaction(context) {
            item.value = Self.insideTransactionValue
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))
        lines.append("item.value=\(item.value)")
        record(lines)
        withExtendedLifetime(container) {}
    }

    // D：Bのあとで save() を呼ぶ
    func testD_SaveAfterThrow() throws {
        let url = storeDirectory.appendingPathComponent("d.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 D] Bと同じ操作のあと、save()を呼ぶ"] + setup
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D008Record>()).first)

        let thrown = runThrowingTransaction(context) {
            item.value = Self.insideTransactionValue
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))

        lines.append("save()のエラー: \(describe(saveCatchingError(context)))")
        lines.append(state("save()後", context: context, url: url))
        lines.append("item.value=\(item.value)")
        record(lines)
        withExtendedLifetime(container) {}
    }

    // E（挿入）：ブロック内で挿入してから検証用エラーを投げ、そのあと save() を呼ぶ
    func testE_InsertInsideBlockThenThrow() throws {
        let url = storeDirectory.appendingPathComponent("e-insert.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 E 挿入] ブロック内で挿入してから検証用エラーを投げ、そのあとsave()"] + setup

        let thrown = runThrowingTransaction(context) {
            context.insert(D008Record(label: Self.insertedLabel, value: Self.insideTransactionValue))
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))

        lines.append("save()のエラー: \(describe(saveCatchingError(context)))")
        lines.append(state("save()後", context: context, url: url))
        record(lines)
        withExtendedLifetime(container) {}
    }

    // E（削除）：ブロック内で削除してから検証用エラーを投げ、そのあと save() を呼ぶ
    func testE_DeleteInsideBlockThenThrow() throws {
        let url = storeDirectory.appendingPathComponent("e-delete.store")
        try seed(url: url)
        let (container, context, setup) = try makeMainContext(url: url)
        var lines = ["[D-008 E 削除] ブロック内で削除してから検証用エラーを投げ、そのあとsave()"] + setup
        let item = try XCTUnwrap(context.fetch(FetchDescriptor<D008Record>()).first)

        let thrown = runThrowingTransaction(context) {
            context.delete(item)
        }
        lines.append("呼び出し元に伝わったエラー: \(describe(thrown))")
        lines.append(state("transaction後", context: context, url: url))
        lines.append("item.isDeleted=\(item.isDeleted)")

        lines.append("save()のエラー: \(describe(saveCatchingError(context)))")
        lines.append(state("save()後", context: context, url: url))
        record(lines)
        withExtendedLifetime(container) {}
    }

    // ブロック内の操作のあとに検証用エラーを投げ、呼び出し元に伝わったエラーを返す
    private func runThrowingTransaction(_ context: ModelContext, _ change: () -> Void) -> Error? {
        do {
            try context.transaction {
                change()
                throw D008IntentionalError.thrownInsideTransactionBlock
            }
            return nil
        } catch {
            return error
        }
    }

    private func saveCatchingError(_ context: ModelContext) -> Error? {
        do {
            try context.save()
            return nil
        } catch {
            return error
        }
    }

    // SQLiteファイルを直接読み、保存されている行を確認する
    private func sqliteRecords(storeURL: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return ["SQLite: 開けませんでした"] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZLABEL, ZVALUE FROM ZD008RECORD ORDER BY ZLABEL", -1, &statement, nil) == SQLITE_OK else { return ["SQLite: 読み取れませんでした"] }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let label = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL"
            let value = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "NULL"
            rows.append("\(label)=\(value)")
        }
        return rows
    }

    private func record(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
