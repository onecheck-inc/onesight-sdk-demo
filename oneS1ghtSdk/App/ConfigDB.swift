//
//  ConfigDB.swift
//  oneS1ghtSdk
//
//  키를 SQLite(secrets.sqlite)에서 읽는다. 값은 빌드 전 `tools/make_secrets_db.py`로 주입.
//  · 소스코드(Swift)엔 키 없음 — DB는 앱 폴더(통째 gitignore)에만 존재.
//  · 키 바뀌면: Secrets.swift(로컬) 수정 → 스크립트 재실행 → 재빌드.
//

import Foundation
import SQLite3
import CoreLocation

enum ConfigDB {

    /// 로드된 config 테이블 [key: value]
    private static let table: [String: String] = {
        let url = Bundle.main.url(forResource: "secrets", withExtension: "sqlite")
               ?? Bundle.main.url(forResource: "secrets", withExtension: "sqlite", subdirectory: "Resources")
        guard let path = url?.path else {
            print("⚠️ ConfigDB: secrets.sqlite 없음 — tools/make_secrets_db.py 먼저 실행")
            return [:]
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM config", -1, &stmt, nil) == SQLITE_OK else { return [:] }

        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                result[String(cString: k)] = String(cString: v)
            }
        }
        return result
    }()

    static var sdkKey: String { table["sdk_key"] ?? "" }
    static var geospaceKey: String { table["geospace_key"] ?? "" }
    static var partnerKey: String { table["partner_key"] ?? "" }
    static var googleMapKey: String { table["google_map_key"] ?? "" }

    // 층별 원점(origin_*) 표는 2026-08-12 제거.
    // 값이 전부 근사치라 도면이 어차피 엉뚱한 데 얹혔고, 타일이 꺼져 있어 화면은 (0,0)과 동일했다.
    // 지금은 LocationTransformer.defaultOrigin 하나로 통일 — 서버가 plan.gps 를 주면 그걸 쓴다.
}
