//
//  GoogleFloorMapView.swift
//  oneS1ghtSdk
//
//  구글맵 위에 도면을 얹고(GroundOverlay) 내 위치·영역을 그리는 지도.
//  · 도면은 정북 정렬 사각형으로 얹고, 보기 방향은 카메라 bearing 으로 맞춘다.
//    (GroundOverlay 를 돌리지 않는 이유 = 바운즈가 항상 남북/동서 축이라 회전과 같이 못 씀)
//  · 좌표 변환은 LocationTransformer — 로컬 미터 → 위경도. origin 없으면 아무것도 못 그린다.
//  · 줌·팬·회전은 지도 SDK 가 해주므로 제스처 코드가 없다 (FloorMapView 와 가장 큰 차이).
//

import SwiftUI
import CoreLocation
import GoogleMaps
import OneS1ghtSDK

extension Zone {
    /// 이 영역 안에 로컬 좌표가 들어오는가 — SDK ray casting 재사용
    func contains(x: Double, y: Double) -> Bool { contains(Position(x: x, y: y)) }
}

@available(iOS 27.0, *)
struct GoogleFloorMapView: UIViewRepresentable {

    @ObservedObject var provider: UwbPositioningProvider
    var infra: FloorInfra
    /// 도면 원점의 실세계 좌표 (GeoSpace 정렬값 또는 폴백)
    var origin: CLLocationCoordinate2D
    /// 보기 방향(도) — 표시용 카메라 회전. 측위 좌표와 무관.
    var mapRotation: Double = 270
    var showAreas: Bool = true
    var onAreaChange: ((Zone?) -> Void)? = nil

    // MARK: - UIViewRepresentable

    /// 지도를 감싸는 컨테이너 — "프레임이 잡히는 순간"을 알기 위해 존재한다.
    /// updateUIView 는 상태가 바뀔 때만 오므로(측위가 꺼진 평소엔 거의 안 옴),
    /// fit 트리거를 상태가 아니라 레이아웃(layoutSubviews)에 건다.
    final class Container: UIView {
        let mapView: GMSMapView
        var onLayout: (() -> Void)?
        init(mapView: GMSMapView) {
            self.mapView = mapView
            super.init(frame: .zero)
            addSubview(mapView)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func layoutSubviews() {
            super.layoutSubviews()
            mapView.frame = bounds
            onLayout?()
        }
    }

    func makeUIView(context: Context) -> Container {
        LocationTransformer.origin = origin

        // 지도 타일을 아예 끈다(.none) — 구글맵은 카메라·오버레이·제스처 엔진으로만 쓴다.
        // 실내 13×8m 에서 위성/도로는 도면에 가려 보이지도 않는다. AIShopping 과 같은 선택.
        let options = GMSMapViewOptions()
        options.backgroundColor = .white      // .none 일 때는 옵션 레벨에서 줘야 흰색이 먹는다

        let mapView = GMSMapView(options: options)
        mapView.mapType = .none
        mapView.settings.rotateGestures = true
        mapView.settings.tiltGestures = false
        mapView.isBuildingsEnabled = false
        mapView.isIndoorEnabled = false

        context.coordinator.install(on: mapView, infra: infra, rotation: mapRotation)

        let container = Container(mapView: mapView)
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.layoutDidChange()
        }
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        LocationTransformer.origin = origin
        context.coordinator.showAreas = showAreas
        context.coordinator.onAreaChange = onAreaChange
        context.coordinator.sync(infra: infra, rotation: mapRotation)   // 층 전환·존 늦게 도착 반영
        context.coordinator.update(position: provider.latestPosition)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(infra: infra, showAreas: showAreas, onAreaChange: onAreaChange)
    }

    // MARK: - Coordinator (오버레이 수명 관리)

    final class Coordinator {
        private var infra: FloorInfra
        var showAreas: Bool
        var onAreaChange: ((Zone?) -> Void)?

        /// 로컬 미터를 이 배수로 뻥튀기해서 지도에 얹는다 (AIShopping 과 동일).
        /// 구글맵 줌 상한(21)으론 13m 방을 화면에 못 채우는데, 공간을 3배로 키우면
        /// 필요 줌이 상한 안으로 내려온다. 배경이 흰색(.none)이라 실세계 크기와 안 맞아도 무관.
        private let scale = 3.0

        /// 로컬 미터 → 지도 위경도 (scale 적용). 판정은 항상 원본 미터로 하고 표시만 이걸 쓴다.
        private func world(x: Double, y: Double) -> CLLocationCoordinate2D? {
            LocationTransformer.toWorld(x: x * scale, y: y * scale)
        }

        private weak var mapView: GMSMapView?
        private var planOverlay: GMSGroundOverlay?
        private var areaPolygons: [String: GMSPolygon] = [:]
        private var meMarker: GMSMarker?
        private var currentAreaId: String?

        // 화면 크기에 맞춘 줌은 뷰가 실제 크기를 가진 뒤에야 계산된다 → 레이아웃이 알려줄 때
        private var planBounds: GMSCoordinateBounds?
        private var rotation: Double = 0
        private var didFit = false
        private var lastLaidOutSize: CGSize = .zero

        /// 컨테이너 layoutSubviews 에서 호출 — 첫 배치·화면 크기 변경(회전 등) 때 다시 꽉 채운다.
        func layoutDidChange() {
            guard let mapView, mapView.frame.size != .zero else { return }
            if mapView.frame.size != lastLaidOutSize {
                lastLaidOutSize = mapView.frame.size
                didFit = false
            }
            // 레이아웃 사이클 "안"에서 카메라를 만지면 GMSMapView 자신의 레이아웃 처리가
            // 리사이즈 전 카메라로 되돌려버린다 (설정값은 읽히는데 렌더링은 옛 줌).
            // 그래서 지도 내부 레이아웃까지 끝난 다음 런루프에서 fit 한다.
            DispatchQueue.main.async { [weak self] in self?.fitIfNeeded() }
        }

        init(infra: FloorInfra,
             showAreas: Bool,
             onAreaChange: ((Zone?) -> Void)?) {
            self.infra = infra
            self.showAreas = showAreas
            self.onAreaChange = onAreaChange
        }

        /// 층 전환·존 갱신 반영 — 쇼핑앱의 clear() + 재로드에 해당.
        /// · 층이 바뀌면: 오버레이 전부 걷어내고 새 도면으로 다시 설치 (fit도 다시)
        /// · 같은 층에서 존만 바뀌면(폴링으로 늦게 도착·새로고침): 폴리곤만 다시 그림
        func sync(infra newInfra: FloorInfra, rotation: Double) {
            guard let mapView else { infra = newInfra; return }

            if newInfra.floorId != infra.floorId {
                planOverlay?.map = nil; planOverlay = nil
                areaPolygons.values.forEach { $0.map = nil }; areaPolygons.removeAll()
                meMarker?.map = nil; meMarker = nil
                currentAreaId = nil
                didFit = false
                infra = newInfra
                install(on: mapView, infra: newInfra, rotation: rotation)
                return
            }

            infra = newInfra   // 존 판정이 항상 최신 목록을 보게
            let newIds = Set(newInfra.zones.map(\.id))
            if newIds != Set(areaPolygons.keys) {
                areaPolygons.values.forEach { $0.map = nil }
                areaPolygons.removeAll()
                addAreas(newInfra.zones, to: mapView)
            }
        }

        /// 도면·영역·카메라 최초 배치 (한 번만)
        func install(on mapView: GMSMapView, infra: FloorInfra, rotation: Double) {
            self.mapView = mapView

            mapView.setMinZoom(15, maxZoom: 21)   // 흰 허공까지 멀리 나가지 않게 (AIShopping 과 동일 범위)

            guard let sw = world(x: infra.plan.minX, y: infra.plan.minY),
                  let ne = world(x: infra.plan.maxX, y: infra.plan.maxY) else { return }

            // 도면 — 남서/북동 두 점이 만드는 사각형에 이미지를 얹는다
            let bounds = GMSCoordinateBounds(coordinate: sw, coordinate: ne)
            let overlay = GMSGroundOverlay(bounds: bounds, icon: UIImage(data: infra.plan.pngData) ?? UIImage())
            overlay.bearing = 0            // 오버레이는 안 돌린다 — 회전은 카메라 몫
            overlay.zIndex = 1
            overlay.map = mapView
            planOverlay = overlay

            addAreas(infra.zones, to: mapView)

            planBounds = bounds
            self.rotation = rotation

            // 카메라 — 도면 중심에서 회전 상태로 시작. 정확한 줌은 fitIfNeeded 가 잡는다.
            let center = CLLocationCoordinate2D(latitude: (sw.latitude + ne.latitude) / 2,
                                                longitude: (sw.longitude + ne.longitude) / 2)
            mapView.camera = GMSCameraPosition(target: center,
                                               zoom: 19,
                                               bearing: rotation,
                                               viewingAngle: 0)
        }

        /// 도면이 화면에 꽉 차도록 줌을 맞춘다.
        /// camera(for:insets:) 는 항상 북쪽 기준으로 계산하고 bearing 을 0으로 되돌리므로,
        /// 거기서 zoom·target 만 가져오고 회전은 다시 얹는다.
        private func fitIfNeeded() {
            guard !didFit,
                  let mapView, let bounds = planBounds,
                  mapView.frame.width > 0, mapView.frame.height > 0 else { return }

            // fit 기준 = 앵커 경계 + 1m 마진 (쇼핑앱의 "스페이스 경계" 역할).
            // 단, 도면 경계 안으로 클램프 — 마진이 도면 밖으로 삐져나가면
            // 도면 옆에 흰 띠가 생긴다 (앵커가 벽에 붙은 층에서 실제 발생).
            // 앵커가 없으면 도면 경계로 폴백.
            let minX: Double, minY: Double, maxX: Double, maxY: Double
            if !infra.anchors.isEmpty {
                minX = Swift.max(infra.anchors.map(\.x).min()! - 1, infra.plan.minX)
                minY = Swift.max(infra.anchors.map(\.y).min()! - 1, infra.plan.minY)
                maxX = Swift.min(infra.anchors.map(\.x).max()! + 1, infra.plan.maxX)
                maxY = Swift.min(infra.anchors.map(\.y).max()! + 1, infra.plan.maxY)
            } else {
                minX = infra.plan.minX; minY = infra.plan.minY
                maxX = infra.plan.maxX; maxY = infra.plan.maxY
            }
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            let w = maxX - minX
            let h = maxY - minY

            // 회전한 도면이 화면 축에서 차지하는 크기 — 90/270°면 가로세로가 뒤바뀐다.
            let rad = rotation * .pi / 180
            let fitW = abs(w * cos(rad)) + abs(h * sin(rad))
            let fitH = abs(w * sin(rad)) + abs(h * cos(rad))

            guard let center = world(x: cx, y: cy) else { return }

            // 줌을 SDK(camera(for:))에 묻지 않고 메르카토르 공식으로 직접 계산한다.
            // camera(for:)는 지도 내부 레이아웃이 끝나기 전(우리처럼 layoutSubviews 직후)에
            // 부르면 nil/부정확한 값을 줘서 초기 줌에 머무는 문제가 있었다.
            // 세계 폭 = 256pt × 2^zoom → 1pt당 미터 = 156543.03392 × cos(위도) / 2^zoom
            let metersPerPointAtZoom0 = 156543.03392 * cos(center.latitude * .pi / 180)
            let zoomW = log2(metersPerPointAtZoom0 * Double(mapView.frame.width)  / (fitW * scale))
            let zoomH = log2(metersPerPointAtZoom0 * Double(mapView.frame.height) / (fitH * scale))

            // 꽉 채우기(fill=max)는 긴 축을 잘라낸다. 잘림을 최대 ~1.5%로 캡:
            // 비율이 화면과 비슷한 층(금정역)은 사실상 풀블리드에 잘림만 살짝 줄고,
            // 길쭉한 층(赤坂 6.9×13.3m)은 여백을 두고 전체가 보인다.
            let zoomFit = min(zoomW, zoomH), zoomFill = max(zoomW, zoomH)
            let zoom = min(zoomFill, zoomFit + log2(1.015))

            didFit = true
            mapView.camera = GMSCameraPosition(target: center,
                                               zoom: Float(zoom),
                                               bearing: rotation,
                                               viewingAngle: 0)
            mapView.cameraTargetBounds = bounds   // 도면 밖으로 팬해서 길 잃지 않게
        }

        private func addAreas(_ areas: [Zone], to mapView: GMSMapView) {
            for area in areas {
                let path = GMSMutablePath()
                var ok = true
                for p in area.polygon {
                    guard let c = world(x: p.x, y: p.y) else {
                        ok = false; break
                    }
                    path.add(c)
                }
                guard ok, path.count() >= 3 else { continue }

                let polygon = GMSPolygon(path: path)
                polygon.strokeWidth = 2
                polygon.zIndex = 2
                apply(style: polygon, entered: false)
                polygon.map = showAreas ? mapView : nil
                areaPolygons[area.id] = polygon
            }
        }

        /// 내 위치 아이콘 — 기본 핀 대신 빨간 점 (흰 테두리로 도면 선 위에서도 구분)
        private static let redDotIcon: UIImage = {
            let size = CGSize(width: 18, height: 18)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                c.setFillColor(UIColor.white.cgColor)
                c.fillEllipse(in: CGRect(origin: .zero, size: size))
                c.setFillColor(UIColor.systemRed.cgColor)
                c.fillEllipse(in: CGRect(x: 3, y: 3, width: 12, height: 12))
            }
        }()

        /// 진입 여부에 따른 색 — 기본 파랑, 진입 시 빨강 (FloorMapView 와 동일 규칙)
        private func apply(style polygon: GMSPolygon, entered: Bool) {
            polygon.strokeColor = entered ? .systemRed : .systemBlue
            polygon.fillColor = (entered ? UIColor.systemRed : UIColor.systemBlue).withAlphaComponent(0.22)
        }

        /// 좌표 갱신 — 마커 이동 + 영역 진입/이탈 판정
        func update(position: Coordinates?) {
            guard let mapView else { return }
            // 층 전환 직후의 재fit — updateUIView 도 레이아웃 사이클 중에 불릴 수 있어
            // layoutDidChange 와 같은 이유로 다음 런루프로 미룬다 (didFit 가드라 중복 호출 무해)
            DispatchQueue.main.async { [weak self] in self?.fitIfNeeded() }

            for (id, polygon) in areaPolygons {
                polygon.map = showAreas ? mapView : nil
                apply(style: polygon, entered: id == currentAreaId)
            }

            guard let p = position,
                  let coord = world(x: p.x, y: p.y) else { return }

            if let marker = meMarker {
                // 좌표가 튀는 걸 눈으로 흡수 — 캔버스 뷰(FloorMapView)와 같은 값으로 유지할 것
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.5)
                marker.position = coord
                CATransaction.commit()
            } else {
                let marker = GMSMarker(position: coord)
                marker.icon = Self.redDotIcon
                marker.groundAnchor = CGPoint(x: 0.5, y: 0.5)
                marker.zIndex = 3
                marker.isTappable = false
                marker.map = mapView
                meMarker = marker
            }

            let entered = infra.zones.first { $0.contains(x: p.x, y: p.y) }
            if entered?.id != currentAreaId {
                currentAreaId = entered?.id
                onAreaChange?(entered)
            }
        }
    }
}
