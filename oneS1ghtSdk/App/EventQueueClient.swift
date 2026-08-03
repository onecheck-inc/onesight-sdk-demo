//
//  EventQueueClient.swift
//  oneS1ghtSdk
//
//  console 다운링크 이벤트 큐 소비 — GET .../zone/{zone_id}/event (pop, 1건 꺼내 삭제).
//  존 진입 중 1초 폴링으로 서버가 밀어넣은 이벤트를 받아 인앱 메시지로 표시한다.
//  큐 비면 event:null → nil 반환. (적재는 외부에서 POST 로, 키 없이 가능)
//  Base URL 은 SDK 의 ApiClient.defaultBaseURL 재사용(중복 선언 안 함).
//

import Foundation
import OneS1ghtSDK

enum EventQueueClient {

    /// 존 큐에서 이벤트 1건 pop. 있으면 payload(원본 — title/content가 언어 object일 수 있음), 없으면 nil.
    static func pop(buildingId: String, floorId: String, zoneId: String) async -> [String: Any]? {
        let base = ApiClient.defaultBaseURL.absoluteString
        let path = "\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/zone/\(zoneId)/event"
        guard let url = URL(string: path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ConfigDB.sdkKey, forHTTPHeaderField: "X-SDK-Key")   // pop 은 키 필요
        req.setValue("close", forHTTPHeaderField: "Connection")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? [String: Any] else { return nil }   // event:null → 큐 빔

        return event["payload"] as? [String: Any] ?? [:]
    }
}
