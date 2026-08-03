//
//  oneS1ghtSdkApp.swift
//  oneS1ghtSdk
//
//  Created by onecheck-jordon on 7/10/26.
//

import SwiftUI
import GoogleMaps

@main
struct oneS1ghtSdkApp: App {

    init() {
        // 지도 SDK는 화면을 만들기 전에 키를 받아야 한다 (없으면 지도가 회색으로만 뜸)
        let key = ConfigDB.googleMapKey
        if key.isEmpty {
            print("⚠️ google_map_key 없음 — secrets.sqlite 재생성 필요 (tools/make_secrets_db.py)")
        } else {
            GMSServices.provideAPIKey(key)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
