//
//  PermissionHelper.swift
//  App — 권한 요청은 앱(고객사 앱) 책임 (SDK는 supportStatus로 상태만 알려줌)
//
//  · 위치: 직접 요청 가능 (DL-TDoA 전제조건 — 없으면 세션 INVALID_CONFIGURATION)
//  · Nearby Interaction / Bluetooth: 직접 요청 API 없음 — 첫 세션 시작 때 iOS가 자동 팝업
//

import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class PermissionHelper: NSObject, ObservableObject {

    @Published var locationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        locationStatus = manager.authorizationStatus
    }

    /// 위치 권한 시스템 팝업 요청 (미결정일 때만 팝업 뜸)
    func requestLocation() {
        manager.requestWhenInUseAuthorization()
    }

    /// 거부 상태일 때 — 앱 설정 화면으로 이동 (거기서만 다시 켤 수 있음)
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 화면 표시용 텍스트
    var locationText: String {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return "✅ 위치 허용됨"
        case .notDetermined:                          return "⚪️ 위치 미결정 — 요청 필요"
        case .denied:                                 return "❌ 위치 거부됨 — 설정에서 허용"
        case .restricted:                             return "❌ 위치 제한됨"
        @unknown default:                             return "❓ 알 수 없음"
        }
    }

    var isLocationGranted: Bool {
        locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
    }
}

// MARK: - CLLocationManagerDelegate (권한 변경 실시간 반영)

extension PermissionHelper: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
        }
    }
}
