//
//  LocationTransformer.swift
//  oneS1ghtSdk
//
//  도면 로컬 미터 좌표 ↔ 실세계 위경도 변환 (구글맵 표시용).
//  · 측위·존 판정은 전부 로컬 미터로 하고, 이 변환은 "지도에 그릴 때만" 쓴다.
//  · 로컬 (0,0)이 지구상 어디인지(origin)를 넣어야 동작한다 — 층마다 다르다.
//  · +x = 동쪽, +y = 북쪽으로 두고 도면을 정북 정렬로 얹는다.
//    도면이 실제로 돌아가 있는 건 지도 카메라를 돌려서 맞춘다(표시용, 좌표와 무관).
//

import Foundation
import CoreLocation

struct LocalPoint: Equatable {
    var x: Double
    var y: Double
}

enum LocationTransformer {

    /// 지구 반지름 (미터) — 구글 SphericalUtil 기본값과 동일하게 맞춤
    private static let earthRadius = 6_371_009.0

    /// 도면 원점(로컬 0,0)의 실세계 좌표. 지도를 그리기 전에 층에 맞는 값을 주입한다.
    /// 미주입이면 변환 함수가 nil을 돌려준다 (엉뚱한 위치에 그리는 것보다 안 그리는 게 낫다).
    static var origin: CLLocationCoordinate2D?

    /// 기본 원점 — 도면 정렬(GeoSpace plan.gps)이 되기 전까지 모든 층이 이걸 쓴다.
    ///
    /// 실제 위치와 달라도 되는 이유: 지도 타일이 꺼져 있어(mapType .none · 흰 배경)
    /// 도면이 지구상 어디에 얹히든 화면이 같다. 구글맵은 좌표가 "있기만" 하면 그린다.
    /// 적도를 쓰는 이유: cos(lat)=1 이라 경도 왜곡이 0 → 로컬 미터가 그대로 얹힌다.
    ///
    /// 서버가 plan.gps 를 주기 시작하면 층마다 그 값을 origin 에 넣으면 된다 (여긴 그대로 기본값).
    static let defaultOrigin = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    /// 로컬 미터 → 위경도. 원점에서 동쪽으로 x, 북쪽으로 y 이동한 지점.
    static func toWorld(x: Double, y: Double) -> CLLocationCoordinate2D? {
        guard let origin else { return nil }
        let movedEast = offset(from: origin, distance: x, heading: 90)
        return offset(from: movedEast, distance: y, heading: 0)
    }

    /// 위경도 → 로컬 미터. 지도 탭 좌표를 도면 좌표로 되돌릴 때 쓴다.
    static func toLocal(_ coordinate: CLLocationCoordinate2D) -> LocalPoint? {
        guard let origin else { return nil }
        let originLoc = CLLocation(latitude: origin.latitude, longitude: origin.longitude)

        // 위도는 원점 것으로 고정하고 경도만 바꿔 재면 순수 동서 거리 = x
        var x = originLoc.distance(from: CLLocation(latitude: origin.latitude,
                                                    longitude: coordinate.longitude))
        if coordinate.longitude < origin.longitude { x = -x }

        // 경도는 원점 것으로 고정하고 위도만 바꿔 재면 순수 남북 거리 = y
        var y = originLoc.distance(from: CLLocation(latitude: coordinate.latitude,
                                                    longitude: origin.longitude))
        if coordinate.latitude < origin.latitude { y = -y }

        return LocalPoint(x: x, y: y)
    }

    /// 한 점에서 방위(0=북, 90=동)로 distance 미터 이동한 좌표.
    private static func offset(from coordinate: CLLocationCoordinate2D,
                               distance: Double,
                               heading: Double) -> CLLocationCoordinate2D {
        let lat1 = coordinate.latitude * .pi / 180
        let lon1 = coordinate.longitude * .pi / 180
        let bearing = heading * .pi / 180
        let angular = distance / earthRadius

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi,
                                      longitude: lon2 * 180 / .pi)
    }
}
