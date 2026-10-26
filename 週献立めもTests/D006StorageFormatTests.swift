//
//  D006StorageFormatTests.swift
//  週献立めも
//
//  D-006：数値数量の保存形式の検証（Decimal型属性／文字列）
//  technical-design 4.1・4.4、data-design 3.1「保存形式（暫定）」
//

import XCTest
import SwiftData
import SQLite3

// 検証専用のモデル。アプリ本体のモデルではない。
@Model
final class D006DecimalRecord {
    var label: String
    var amount: Decimal

    init(label: String, amount: Decimal) {
        self.label = label
        self.amount = amount
    }
}

@Model
final class D006StringRecord {
    var label: String
    var amount: String

    init(label: String, amount: String) {
        self.label = label
        self.amount = amount
    }
}

final class D006StorageFormatTests: XCTestCase {

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func decimal(_ string: String) -> Decimal {
        Decimal(string: string, locale: posix)!
    }

    // test-design D-006 の値に、入力上限20文字の値などを加えたもの
    private static var samples: [(label: String, value: Decimal)] {
        [
            ("0.1", decimal("0.1")),
            ("0.123456789", decimal("0.123456789")),
            ("99999", decimal("99999")),
            ("1/3 (38桁)", decimal("1") / decimal("3")),
            ("0.1+0.2", decimal("0.1") + decimal("0.2")),
            ("20文字 1.000000000000000001", decimal("1.000000000000000001")),
            ("12345.6789012345", decimal("12345.6789012345")),
            ("0.0015", decimal("0.0015")),
        ]
    }

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("D006-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }

    private func makeContainer(for type: any PersistentModel.Type, url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: type, configurations: configuration)
    }

    func testDecimalAttributeRoundTrip() throws {
        let url = storeDirectory.appendingPathComponent("decimal.store")

        // 保存（このコンテナはブロックを抜けると破棄される）
        do {
            let container = try makeContainer(for: D006DecimalRecord.self, url: url)
            let context = ModelContext(container)
            for sample in Self.samples {
                context.insert(D006DecimalRecord(label: sample.label, amount: sample.value))
            }
            try context.save()
        }

        // 新しいコンテナで同じストアを開いて再読み込み
        let container = try makeContainer(for: D006DecimalRecord.self, url: url)
        let records = try ModelContext(container).fetch(FetchDescriptor<D006DecimalRecord>())
        XCTAssertEqual(records.count, Self.samples.count)

        var lines = ["[D-006] Decimal型属性"]
        var mismatchCount = 0
        for sample in Self.samples {
            guard let record = records.first(where: { $0.label == sample.label }) else {
                XCTFail("再読み込みで見つからない: \(sample.label)")
                continue
            }
            let matched = record.amount == sample.value
            if !matched { mismatchCount += 1 }
            lines.append("\(matched ? "一致" : "不一致") \(sample.label): 保存前=\(sample.value) 再読み込み後=\(record.amount)")
        }
        lines.append("不一致 \(mismatchCount)/\(Self.samples.count) 件")
        lines.append(contentsOf: sqliteStorageTypes(storeURL: url))
        record(lines)
        // D-006 は結果を記録するテストのため、Decimal型属性の不一致はテスト失敗にしない
    }

    func testStringRoundTrip() throws {
        let url = storeDirectory.appendingPathComponent("string.store")

        do {
            let container = try makeContainer(for: D006StringRecord.self, url: url)
            let context = ModelContext(container)
            for sample in Self.samples {
                context.insert(D006StringRecord(label: sample.label, amount: sample.value.description))
            }
            try context.save()
        }

        let container = try makeContainer(for: D006StringRecord.self, url: url)
        let records = try ModelContext(container).fetch(FetchDescriptor<D006StringRecord>())
        XCTAssertEqual(records.count, Self.samples.count)

        var lines = ["[D-006] 文字列"]
        var mismatchCount = 0
        for sample in Self.samples {
            guard let record = records.first(where: { $0.label == sample.label }) else {
                XCTFail("再読み込みで見つからない: \(sample.label)")
                continue
            }
            let restored = Decimal(string: record.amount, locale: Self.posix)
            let matched = record.amount == sample.value.description && restored == sample.value
            if !matched { mismatchCount += 1 }
            XCTAssertTrue(matched, "文字列保存で不一致: \(sample.label)")
            lines.append("\(matched ? "一致" : "不一致") \(sample.label): 保存前=\(sample.value) 再読み込み後=\(record.amount)")
        }
        lines.append("不一致 \(mismatchCount)/\(Self.samples.count) 件")
        lines.append(contentsOf: sqliteStorageTypes(storeURL: url))
        record(lines)
    }

    // SQLiteに実際に保存された列の型を調べる（ZAMOUNT列）
    private func sqliteStorageTypes(storeURL: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return ["SQLite: 開けませんでした"]
        }
        defer { sqlite3_close(db) }

        var lines: [String] = []
        let tableSQL = "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'ZD006%'"
        for table in query(db, tableSQL).map({ $0[0] }) {
            for column in query(db, "PRAGMA table_info(\(table))") where column[1] == "ZAMOUNT" {
                lines.append("SQLite: \(table).ZAMOUNT 宣言型=\(column[2])")
            }
            for row in query(db, "SELECT ZLABEL, typeof(ZAMOUNT), quote(ZAMOUNT) FROM \(table)") {
                lines.append("SQLite: \(row[0]) 格納型=\(row[1]) 格納値=\(row[2])")
            }
        }
        return lines.isEmpty ? ["SQLite: ZAMOUNT列が見つかりませんでした"] : lines
    }

    private func query(_ db: OpaquePointer?, _ sql: String) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            rows.append((0..<columnCount).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "NULL"
            })
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
