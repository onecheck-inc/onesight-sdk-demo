//
//  JudgmentLog.swift
//  oneS1ghtSdk
//
//  판정 증적 파일 로거 — "알고리즘이 진짜 탔는가"를 걷기 검증 뒤 파일로 확인하기 위한 것.
//  화면 로그(provider.log)는 200줄 링버퍼 + 앱 재시작 휘발이라 증적이 못 된다.
//  앱 실행마다 Documents/ 에 새 파일을 만들고, 모든 로그 라인을 밀리초 타임스탬프로 전량 기록.
//  내보내기는 로그 시트의 공유 버튼(ShareLink → AirDrop·메신저).
//
//  앱에 한 벌(파일 1·직렬 큐 1)이라 진입점은 static — SDK 와 같은 규칙("문은 static").
//

import Foundation

final class JudgmentLog {

    private init() {}   // 인스턴스 생성 차단 — 전부 static

    /// 이번 실행의 증적 파일 (첫 접근 시 생성)
    static let fileURL: URL = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("judgment-\(df.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()

    private static let queue = DispatchQueue(label: "co.onecheck.judgment-log")   // 순서 보장 직렬 큐
    private static let handle: FileHandle? = try? FileHandle(forWritingTo: fileURL)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func append(_ line: String) {
        queue.async {
            handle?.write(Data("[\(stamp.string(from: Date()))] \(line)\n".utf8))
        }
    }
}
