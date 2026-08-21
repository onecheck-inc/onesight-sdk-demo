//
//  SdkCompat.swift
//  옛 SDK 의 FloorInfra 자리를 메우는 앱 로컬 타입.
//
//  v0.1.0 에서 공개 API 가 재설계되며 loadFloor(buildingId:floorId:) -> FloorInfra 가 사라지고,
//  같은 정보가 세 갈래로 나뉘었다.
//
//      OneS1ght.floor(_:_:)      도면 이미지 + 배치 범위
//      OneS1ght.locators(_:_:)   로케이터 배치 + UWB 세션 ID
//      OneS1ght.zones(_:_:)      구역
//
//  지도 뷰 두 곳(FloorMapView · GoogleFloorMapView)이 FloorInfra 를 깊이 쓰고 있어,
//  그 모양을 앱 쪽에 그대로 두고 새 API 로 채우는 편이 변경 범위가 훨씬 작다.
//  덕분에 지도 뷰는 한 줄도 고치지 않았다.
//
//  ⚠️ 이건 과도기 어댑터다. 언젠가 지도 뷰를 Floor/FloorLocators 로 직접 옮기면 통째로 지운다.
//

import Foundation
import OneS1ght

/// 로케이터. 옛 이름을 유지한다 — 필드(address·x·y·z)가 v0.1.0 의 Locator 와 같다.
typealias AnchorPoint = Locator

/// 도면 이미지와 그것이 덮는 실좌표 범위.
struct FloorPlanImage: Equatable {
    let pngData: Data
    let originX, originY: Double     // 도면 원점 오프셋 (미터)
    let widthM, heightM: Double      // 도면 실제 크기 (미터)

    var minX: Double { originX }
    var minY: Double { originY }
    var maxX: Double { originX + widthM }
    var maxY: Double { originY + heightM }
}

/// 한 층을 그리고 측위하는 데 필요한 것 전부.
struct FloorInfra {
    let buildingId: String
    let floorId: String
    /// UWB 세션 — 층마다 다르다. nil 이면 측위를 시작할 수 없다.
    let sessionId: Int?
    /// 로케이터가 있고 세션도 있는가.
    let positioningReady: Bool
    let plan: FloorPlanImage
    let anchors: [AnchorPoint]
    /// 콘솔에서 존을 고치면 갱신되므로 var.
    var zones: [Zone]
}

extension FloorInfra {

    /// 층 하나를 통째로 읽어 온다. 옛 `OneS1ghtSDK.loadFloor` 자리.
    ///
    /// ⚠️ `setFloorMap` 을 여기서 함께 부른다 — 이걸 빠뜨리면 측위 파이프라인은 돌지만
    /// 좌표가 하나도 나오지 않는다(E3001). 옛 `loadFloor` 가 엔진 주입까지 겸했으므로
    /// 호출부의 기대를 그대로 유지한다.
    @MainActor
    static func load(buildingId: String, floorId: String) async throws -> FloorInfra {
        // 도면은 단건 조회로 받는다 — floors(_:) 목록은 가볍게 유지하려고 image 가 비어 있다.
        let floor = try await OneS1ght.floor(buildingId, floorId)

        // 엔진 주입 (로케이터·세션·존을 SDK 내부로). 가동 중이면 즉시 층 전환.
        try await OneS1ght.setFloorMap(floor, buildingID: buildingId)

        // 화면·provider 가 직접 들고 있어야 하는 것들은 따로 받아 온다.
        let locators = try await OneS1ght.locators(buildingId, floorId)
        let zones = try await OneS1ght.zones(buildingId, floorId)

        return FloorInfra(
            buildingId: buildingId,
            floorId: floorId,
            sessionId: locators.sessionId,
            positioningReady: locators.positioningReady,
            // 도면이 없는 층(hasPlan == false)이면 빈 Data — UIImage(data:) 가 nil 이 되어
            // 지도 뷰가 배경 없이 그린다(기존 동작과 같다).
            plan: FloorPlanImage(pngData: floor.image ?? Data(),
                                 originX: floor.originX, originY: floor.originY,
                                 widthM: floor.widthM, heightM: floor.heightM),
            anchors: locators.locators,
            zones: zones)
    }
}
