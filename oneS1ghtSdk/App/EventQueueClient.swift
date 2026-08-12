//
//  EventQueueClient.swift
//  oneS1ghtSdk
//
//  console 존 이벤트 조회 — GET .../zone/{zone_id}/event?session_id={sid}
//  존 진입 판정 시 **1회** 호출한다. 서버가 "이 세션이 아직 못 본 활성 시책"을 돌려주므로
//  폴링이 필요 없다 (예전엔 큐에서 1건씩 꺼내 삭제하는 방식이라 1초 폴링 + 선착순 1대였다).
//  · session_id 를 빠뜨리면 서버가 구(舊) 큐 동작으로 폴백 → 다중 수신이 안 된다.
//  · 중복 방지는 서버 몫 — 앱에 "이미 받음" 플래그를 두지 않는다.
//  Base URL 은 SDK 의 ApiClient.defaultBaseURL 재사용(중복 선언 안 함).
//

import Foundation
import OneS1ghtSDK

enum EventQueueClient {

    /// 이 세션이 아직 못 받은 이벤트 payload 목록 (없으면 빈 배열).
    /// 네트워크·5xx 실패면 짧게 1회 재시도한다.
    static func fetch(buildingId: String, floorId: String,
                      zoneId: String, sessionId: String) async -> [[String: Any]] {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            switch await once(buildingId: buildingId, floorId: floorId,
                              zoneId: zoneId, sessionId: sessionId) {
            case .success(let events): return events
            case .failure:             continue          // 실패 → 재시도
            }
        }
        return []
    }

    private enum Outcome { case success([[String: Any]]), failure }

    private static func once(buildingId: String, floorId: String,
                             zoneId: String, sessionId: String) async -> Outcome {
        let base = ApiClient.defaultBaseURL.absoluteString
        var comps = URLComponents(string:
            "\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/zone/\(zoneId)/event")
        comps?.queryItems = [URLQueryItem(name: "session_id", value: sessionId)]
        guard let url = comps?.url else { return .failure }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ConfigDB.sdkKey, forHTTPHeaderField: "X-SDK-Key")
        req.setValue("close", forHTTPHeaderField: "Connection")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failure }
        guard (200..<300).contains(http.statusCode) else {
            // 4xx 는 재시도해도 같은 답 (401 키 · 403 스코프 · 404 존 없음) → 실패로 확정하지 않는다
            return http.statusCode >= 500 ? .failure : .success([])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure
        }

        // events(신규, 0..n건) 우선. 구서버 폴백 대비로 event(단건)도 받는다.
        if let list = obj["events"] as? [[String: Any]], !list.isEmpty {
            return .success(list.compactMap { $0["payload"] as? [String: Any] })
        }
        if let one = obj["event"] as? [String: Any] {
            return .success([one["payload"] as? [String: Any] ?? [:]])
        }
        return .success([])                                  // event:null → 받을 것 없음
    }
}
