//
//  Localized.swift  (앱 UI/로그 다국어)
//  oneS1ghtSdk
//
//  OS 언어가 일본어면 "ja", 영어면 "en", 그 외엔 "ko".
//  문구는 Resources/i18n/Localization.json 에 { "키": { "ko":…, "ja":…, "en":… } } 로 관리.
//
//  사용:
//    Localized.text("btn.start")                 // 단순 문구
//    Localized.format("log.buildingsLoaded", 3)  // %d/%@/%.2f 인자 채우기
//    Localized.pick(payload, "title")            // 서버 payload 의 title_ja/title_en 우선
//

import Foundation

enum Localized {

    /// 현재 언어 코드 — "ja" · "en" · "ko"(기본)
    static let language: String = {
        let code = (Locale.preferredLanguages.first ?? "ko").prefix(2).lowercased()
        switch code {
        case "ja": return "ja"
        case "en": return "en"
        default:   return "ko"
        }
    }()

    /// 로드된 문구 테이블: [키: [언어: 문구]]
    private static let table: [String: [String: String]] = {
        let url = Bundle.main.url(forResource: "Localization", withExtension: "json")
               ?? Bundle.main.url(forResource: "Localization", withExtension: "json", subdirectory: "i18n")
        guard let url,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }()

    /// 키 → 현재 언어 문구 (없으면 한국어 기본, 그것도 없으면 키)
    static func text(_ key: String) -> String {
        table[key]?[language] ?? table[key]?["ko"] ?? key
    }

    /// 포맷 문구(%d/%@/%.2f …)에 인자를 채워 반환
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), arguments: args)
    }

    /// 서버 payload 의 언어별 필드에서 현재 언어 문구를 뽑는다.
    ///   형태 ① 언어 object: { "ko":…, "ja":…, "en":… }  ← 서버가 이렇게 보냄
    ///   형태 ② 평문 문자열                                ← 하위호환
    /// 현재 언어가 없으면 ko → 아무 값 순으로 폴백.
    static func value(from any: Any?) -> String {
        if let byLang = any as? [String: Any] {
            let picked = byLang[language] ?? byLang["ko"] ?? byLang.values.first
            return (picked as? String) ?? ""
        }
        return (any as? String) ?? ""
    }
}
