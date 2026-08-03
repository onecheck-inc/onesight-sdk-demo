//
//  FloorMapView.swift
//  oneS1ghtSdk
//
//  GeoSpace 도면 이미지 위에 "내 위치"(빨간 점) + GeoSpace custom_area(지정 영역)를 그리는 지도.
//  · 좌표계 = GeoSpace 미터 (경계 minX..maxX / minY..maxY, Y-up).
//  · custom_area = infra.customAreas (workspaces 폴리곤, 미터 좌표 → 도면과 정합).
//  · 내 위치가 영역 안에 들어가면 하이라이트 + onAreaEnter 발화.
//

import SwiftUI
import OneS1ghtSDK

@available(iOS 27.0, *)
struct FloorMapView: View {
    @ObservedObject var provider: UwbPositioningProvider
    var infra: Geospace3Client.FloorInfra?
    var showAreas: Bool = true                                        // 영역 표시 게이트
    var onAreaChange: ((Geospace3Client.CustomArea?) -> Void)? = nil  // 진입(area)·이탈(nil)
    var mapRotation: Double = 270                                     // 도면 회전(도). 90/270이면 세로 화면을 꽉 채움

    // 줌/팬 상태 (핀치 확대 + 드래그 이동, 더블탭 리셋)
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private var rotated90: Bool { mapRotation == 90 || mapRotation == 270 }

    /// 현재 내 위치가 들어가 있는 custom area (없으면 nil)
    private var currentArea: Geospace3Client.CustomArea? {
        guard let p = provider.latestPosition, let areas = infra?.customAreas else { return nil }
        return areas.first { Self.pointInPolygon(x: p.x, y: p.y, polygon: $0.points) }
    }

    var body: some View {
        GeometryReader { geo in
            // 90/270°이면 회전 후 세로가 도록 캔버스 치수를 스왑해 fit → 세로 꽉 참
            let canvas = rotated90 ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
            ZStack {
                if let infra {
                    let t = Transform(infra: infra, canvas: canvas)
                    let r = t.imageRect(infra)

                    ZStack {
                        // 배경 도면 이미지
                        Image(uiImage: infra.image)
                            .resizable()
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)

                        // GeoSpace custom_area (지정 영역) — 데모: showAreas일 때 페이드인
                        if showAreas {
                            ForEach(Array(infra.customAreas.enumerated()), id: \.offset) { _, area in
                                ZonePolygon(
                                    points: area.points.map { t.point(x: Double($0.x), y: Double($0.y)) },
                                    name: area.name,
                                    color: area.id == currentArea?.id ? .red : .blue,   // 기본 파랑 · 진입 시 빨강
                                    active: area.id == currentArea?.id,
                                    labelRotation: -mapRotation   // 지도 회전 상쇄 → 글자 정방향
                                )
                                .animation(.easeInOut(duration: 0.35), value: currentArea?.id)  // 색 전환 부드럽게
                            }
                            .transition(.opacity)
                        }

                        // 내 위치 (빨간 펄스 점)
                        if let p = provider.latestPosition {
                            PositionDot()
                                .position(t.point(x: p.x, y: p.y))
                                .animation(.easeInOut(duration: 0.5), value: p.x)
                                .animation(.easeInOut(duration: 0.5), value: p.y)
                        }
                    }
                    // ★ 회전·스케일·제스처는 "도면 콘텐츠에만" 적용 (로딩엔 영향 없게)
                    .frame(width: canvas.width, height: canvas.height)
                    .rotationEffect(.degrees(mapRotation))
                    .frame(width: geo.size.width, height: geo.size.height)   // 회전 후 컨테이너 크기로 재정렬(중앙)
                    .scaleEffect(zoom * pinch)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { v, s, _ in s = v.magnification }
                            .onEnded { v in zoom = min(max(zoom * v.magnification, 1), 6) }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .updating($drag) { v, s, _ in s = v.translation }
                            .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height }
                    )
                    .onTapGesture(count: 2) { withAnimation { zoom = 1; pan = .zero } }
                } else {
                    // 로딩 — 회전/스케일 영향 없이 항상 0도, 컨테이너 수직·수평 중앙
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(Localized.text("map.loading"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 슬롯을 꽉 채움 — 위아래 UI와 좌우 라인 정렬
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))       // 넘친 도면은 여기서 클립
        .onChange(of: currentArea?.id) { _, _ in
            onAreaChange?(currentArea)   // 진입 시 area, 이탈 시 nil
        }
    }

    /// ray casting — 점이 폴리곤 내부인가 (미터 좌표)
    private static func pointInPolygon(x: Double, y: Double, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (Double(a.y) > y) != (Double(b.y) > y) {
                let xCross = Double(a.x) + (y - Double(a.y)) / (Double(b.y) - Double(a.y)) * (Double(b.x) - Double(a.x))
                if x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - GeoSpace 미터 → 화면 픽셀 (경계 기준 fit + Y 뒤집기)

    private struct Transform {
        let minX, minY, maxY: Double
        let scale: CGFloat
        let origin: CGPoint

        /// contain: 도면 전체가 다 보이게 fit(안 잘림). 여백은 바깥 padding으로 조금 준다.
        init(infra: Geospace3Client.FloorInfra, canvas: CGSize) {
            minX = infra.minX; minY = infra.minY; maxY = infra.maxY
            let w = infra.maxX - infra.minX
            let h = infra.maxY - infra.minY
            let s = min(canvas.width / w, canvas.height / h)
            scale = s
            origin = CGPoint(x: (canvas.width - w * s) / 2,
                             y: (canvas.height - h * s) / 2)
        }

        func point(x: Double, y: Double) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(x - minX) * scale,
                    y: origin.y + CGFloat(maxY - y) * scale)
        }

        func imageRect(_ infra: Geospace3Client.FloorInfra) -> CGRect {
            let bl = point(x: Double(infra.originMeters.x), y: Double(infra.originMeters.y))
            let wpx = CGFloat(infra.sizeMeters.width) * scale
            let hpx = CGFloat(infra.sizeMeters.height) * scale
            return CGRect(x: bl.x, y: bl.y - hpx, width: wpx, height: hpx)
        }
    }
}

// MARK: - 영역 폴리곤

@available(iOS 27.0, *)
private struct ZonePolygon: View {
    let points: [CGPoint]   // 화면 픽셀
    let name: String
    let color: Color
    let active: Bool
    var labelRotation: Double = 0   // 지도 회전 상쇄용 (라벨 글자 정방향)

    private var path: Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            points.dropFirst().forEach { p.addLine(to: $0) }
            p.closeSubpath()
        }
    }
    private var centroid: CGPoint {
        guard !points.isEmpty else { return .zero }
        let sx = points.map(\.x).reduce(0, +), sy = points.map(\.y).reduce(0, +)
        return CGPoint(x: sx / CGFloat(points.count), y: sy / CGFloat(points.count))
    }

    var body: some View {
        ZStack {
            path.fill(color.opacity(active ? 0.45 : 0.22))
            path.stroke(color, style: StrokeStyle(lineWidth: active ? 3 : 2))
            Text(name)
                .font(.caption2).bold()
                .foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.ultraThinMaterial, in: Capsule())
                .rotationEffect(.degrees(labelRotation))   // 지도 회전 상쇄 → 글자 정방향
                .position(centroid)
        }
    }
}

// MARK: - 내 위치 도트 (빨간 펄스)

@available(iOS 27.0, *)
private struct PositionDot: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.25))
                .frame(width: pulse ? 46 : 22, height: pulse ? 46 : 22)
            Circle()
                .fill(Color.red)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
