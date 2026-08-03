//
//  Geospace3Client.swift
//  oneS1ghtSdk
//
//  GeoSpace(geoplan.io) 연동 — 한 호스트, 두 키.
//  · /api/m/floors/{id}/plan       (gsk_, X-SDK-Key)    → 도면 이미지(base64) + widthM + origin
//  · /api/m/floors/{id}/anchors    (gsk_, X-SDK-Key)    → 앵커(도면 로컬 미터 0~13)
//  · /api/partner/floors/{id}/zones (gpk_, X-Partner-Key) → zone 폴리곤(미터 0~13) + 판정 파라미터
//  모든 좌표가 0~13 프레임(origin 0,0)이라 변환(÷57.7·Y플립) 불필요.
//  (console /positioning/floors 는 HTML 회귀로 사용 불가 → 파트너 zones 로 대체.)
//

import Foundation
import Combine
import UIKit
import simd
import OneS1ghtSDK   // ApiClient.defaultBaseURL (console 도면 프록시용)

@MainActor
final class Geospace3Client: NSObject, ObservableObject {

    private let host = "geospace.geoplan.io"
    private var key: String { ConfigDB.geospaceKey }        // gsk_ (도면·앵커, X-SDK-Key)
    private var partnerKey: String { ConfigDB.partnerKey }  // gpk_ (빌딩·존, X-Partner-Key)

    // 빌딩/층 선택 트리 (partner /buildings)
    struct Floor: Identifiable { let id: String; let name: String; let hasPlan: Bool }   // id = floorId
    struct Building: Identifiable { let id: String; let name: String; let floors: [Floor] }  // id = buildingId

    struct Anchor { let address: Int; let x, y, z: Double }
    struct CustomArea { let id: String; let name: String; let points: [CGPoint] }   // zone_id + 폴리곤(미터)

    /// 지도 렌더에 필요한 한 층 인프라 묶음
    struct FloorInfra {
        let buildingId: String          // 다운링크 큐 경로용
        let floorId: String
        let sessionId: Int?             // = networkIdentifier (층별 UWB 세션, 앵커 응답에서)
        let positioningReady: Bool      // 앵커 clusterStatus 모두 auto_done → 측위 가능
        let image: UIImage
        let originMeters: CGPoint
        let sizeMeters: CGSize
        let minX, minY, maxX, maxY: Double
        let anchors: [Anchor]
        var customAreas: [CustomArea]   // 존 폴링으로 늦게 채워질 수 있어 var
    }

    @Published private(set) var status: String = "대기"

    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    enum GsError: Error { case badResponse(Int), noImage, decode }

    // MARK: - 공개 진입점

    /// 빌딩/층 트리 로드 (선택 UI용) — console §6.2/§6.3 우선, 실패 시 GeoSpace 파트너 폴백.
    /// 층 이름은 §6.3 이 UUID 만 주므로 §6.4b plan 의 floor_name("607호")으로 채운다.
    /// (부수효과: 이때 받은 plan 이 캐시돼 층 선택 시 도면 재요청이 없다.)
    func loadBuildings() async throws -> [Building] {
        // TODO(server): console /positioning/buildings/{id}/floors 가 빌딩과 무관하게
        // 같은 층을 반환하는 이슈(07-27 확인)로 파트너 API 우선. 서버 수정되면 순서 원복.
        do { return try await partnerBuildings() }
        catch { return try await consoleBuildings() }
    }

    private func consoleBuildings() async throws -> [Building] {
        let base = ApiClient.defaultBaseURL.absoluteString
        let list: ConsoleBuildingsResponse = try await consoleGet("\(base)/positioning/buildings")
        var out: [Building] = []
        for b in list.buildings where !b.buildingId.hasPrefix("sim-") {   // GeoSpace 미연동 sim 매장 제외
            let fl: ConsoleFloorsResponse = try await consoleGet("\(base)/positioning/buildings/\(b.buildingId)/floors")
            var floors: [Floor] = []
            for f in fl.floors {
                let plan = try? await consolePlan(b.buildingId, f.floorId)   // 이름 획득 + 도면 선로딩 캐시
                floors.append(Floor(id: f.floorId,
                                    name: plan?.floorName ?? String(f.floorId.prefix(8)),
                                    hasPlan: plan?.hasPlan ?? false))
            }
            out.append(Building(id: b.buildingId, name: b.name, floors: floors))
        }
        guard !out.isEmpty else { throw GsError.decode }
        return out
    }

    private func partnerBuildings() async throws -> [Building] {
        let res: BuildingsResponse = try await getPartner("api/partner/buildings")
        return res.buildings.map { b in
            Building(id: b.buildingId, name: b.buildingName,
                     floors: b.floors.map { Floor(id: $0.floorId, name: $0.floorName, hasPlan: $0.hasPlan) })
        }
    }

    /// 선택한 building/floor의 도면·앵커·존 로드
    func loadInfra(buildingId: String, floorId: String) async throws -> FloorInfra {
        status = "도면 로딩 중…"
        async let planTask = getPlan(buildingId: buildingId, floorId)
        async let anchorTask = getAnchors(floorId)
        async let zoneTask = getZones(buildingId: buildingId, floorId)
        let (plan, anchorRes) = try await (planTask, anchorTask)
        let zonesRaw = await zoneTask

        guard let image = plan.image.uiImage() else { throw GsError.noImage }
        let widthM = plan.image.widthM
        let heightM = widthM * Double(plan.image.imgH) / Double(plan.image.imgW)
        let ox = plan.image.originX, oy = plan.image.originY

        let zones = normalizeZones(zonesRaw, image: plan.image)

        // 측위 가능 판정 = 앵커 + 세션ID 존재. clusterStatus 는 안 따진다 —
        // (등록 절차 상태일 뿐, 실제 통신 여부는 시작 후 수신 watchdog 이 판정)
        let ready = !anchorRes.anchors.isEmpty
            && anchorRes.anchors.first?.sessionId != nil
        let infra = FloorInfra(
            buildingId: buildingId,
            floorId: floorId,
            sessionId: anchorRes.anchors.first?.sessionId,
            positioningReady: ready,
            image: image,
            originMeters: CGPoint(x: ox, y: oy),
            sizeMeters: CGSize(width: widthM, height: heightM),
            minX: ox, minY: oy, maxX: ox + widthM, maxY: oy + heightM,
            anchors: anchorRes.anchors.compactMap { $0.toAnchor() },
            customAreas: zones
        )
        status = "완료 (앵커 \(infra.anchors.count) · zone \(zones.count))"
        return infra
    }

    // MARK: - 엔드포인트

    // 세션 캐시 — plan 은 정적(층이름 겸 선로딩), 앵커는 전원상태(clusterStatus)가 변할 수 있어 TTL
    private var planCache: [String: ConsolePlanResponse] = [:]                 // floorId → plan
    private var anchorCache: [String: (at: Date, res: AnchorResponse)] = [:]   // floorId → 앵커 (TTL 3분)

    /// 도면 — console 프록시(§6.4b) 우선(+세션 캐시), 실패 시 GeoSpace 직행 폴백.
    private func getPlan(buildingId: String, _ floorId: String) async throws -> PlanResponse {
        if let res = try? await consolePlan(buildingId, floorId),
           res.hasPlan, let body = res.plan {
            return PlanResponse(plan: .init(image: body.image))
        }
        return try await get("api/m/floors/\(floorId)/plan")
    }

    /// console 도면 프록시 (snake_case → convertFromSnakeCase 로 PlanImage 재사용). 층별 캐시.
    private func consolePlan(_ buildingId: String, _ floorId: String) async throws -> ConsolePlanResponse {
        if let cached = planCache[floorId] { return cached }
        let base = ApiClient.defaultBaseURL.absoluteString
        let res: ConsolePlanResponse =
            try await consoleGet("\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/plan")
        planCache[floorId] = res
        return res
    }

    /// console 공통 GET (X-SDK-Key + snake_case 디코딩)
    private func consoleGet<R: Decodable>(_ urlString: String) async throws -> R {
        guard let url = URL(string: urlString) else { throw GsError.decode }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ConfigDB.sdkKey, forHTTPHeaderField: "X-SDK-Key")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw GsError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1) }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(R.self, from: data)
    }
    /// 앵커 — GeoSpace 유일 잔존 (console 미제공, §10). TTL 3분 캐시로 층 재방문 시 즉시.
    private func getAnchors(_ floorId: String) async throws -> AnchorResponse {
        if let c = anchorCache[floorId], Date().timeIntervalSince(c.at) < 180 { return c.res }
        let res: AnchorResponse = try await get("api/m/floors/\(floorId)/anchors")
        anchorCache[floorId] = (Date(), res)
        return res
    }

    /// 존만 재조회 (존 등록 대기 폴링용) — plan 캐시 기준 미터 정규화까지 마쳐 반환.
    /// 층 로드 시 존이 0개였을 때, console 에서 영역이 생성되면 지도에 반영하기 위해 쓴다.
    func loadZones(buildingId: String, floorId: String) async -> [CustomArea] {
        let raw = await getZones(buildingId: buildingId, floorId)
        guard let image = planCache[floorId]?.plan?.image else {
            return raw.map { CustomArea(id: $0.id, name: $0.name,
                                        points: $0.polygon.map { CGPoint(x: $0[0], y: $0[1]) }) }
        }
        return normalizeZones(raw, image: image)
    }

    /// 존 폴리곤 미터 정규화 — console 이 아직 픽셀로 내려줌 (사양서 §6.4 는 미터).
    /// plan 의 scale(imgW/widthM)·imgH 로 변환하되, 값이 이미 미터 범위면 그대로 통과
    /// (서버가 미터화해도 코드 수정 없이 동작).
    private func normalizeZones(_ raw: [RawZone], image: PlanImage) -> [CustomArea] {
        let widthM = image.widthM
        let heightM = widthM * Double(image.imgH) / Double(image.imgW)
        let scale = Double(image.imgW) / widthM
        let imgH = Double(image.imgH)
        let ox = image.originX, oy = image.originY
        return raw.map { z in
            let isPixel = z.polygon.contains { $0[0] > widthM * 1.5 || $0[1] > heightM * 1.5 }
            let pts = z.polygon.map { p -> CGPoint in
                isPixel ? CGPoint(x: p[0] / scale + ox, y: (imgH - p[1]) / scale + oy)
                        : CGPoint(x: p[0], y: p[1])
            }
            return CustomArea(id: z.id, name: z.name, points: pts)
        }
    }

    /// 존 원시 데이터 (폴리곤 단위 미정 — normalizeZones 로 미터 정규화)
    struct RawZone { let id: String; let name: String; let polygon: [[Double]] }

    /// zone — console(§6.4) + GeoSpace 파트너 를 **합집합**으로.
    /// 두 소스의 동기화가 어긋나는 사례가 양방향으로 관측됨:
    ///   07-24: 콘솔 저작 존이 console 에만 존재 (파트너 0개)
    ///   07-27: 새로 만든 존이 파트너에만 존재 (console 미반영)
    /// → 어느 쪽이든 놓치지 않게 zone_id 기준 union. (id 중복 시 console 우선)
    private func getZones(buildingId: String, _ floorId: String) async -> [RawZone] {
        async let consoleTask = try? consoleZones(buildingId, floorId)
        async let partnerTask = partnerZones(floorId)
        let (c, p) = await (consoleTask ?? [], partnerTask)
        var seen = Set(c.map(\.id))
        return c + p.filter { seen.insert($0.id).inserted }
    }

    private func consoleZones(_ buildingId: String, _ floorId: String) async throws -> [RawZone] {
        let base = ApiClient.defaultBaseURL.absoluteString
        let res: ConsoleZonesResponse =
            try await consoleGet("\(base)/positioning/buildings/\(buildingId)/floor/\(floorId)/zones")
        var seen = Set<String>()
        return res.zones.compactMap { z in
            guard z.isActive, let poly = z.polygon, poly.count >= 3,
                  seen.insert(z.name).inserted else { return nil }
            return RawZone(id: z.zoneId, name: z.name, polygon: poly)
        }
    }

    private func partnerZones(_ floorId: String) async -> [RawZone] {
        var req = URLRequest(url: URL(string: "https://\(host)/api/partner/floors/\(floorId)/zones")!,
                             timeoutInterval: 20)
        req.setValue(partnerKey, forHTTPHeaderField: "X-Partner-Key")
        req.setValue("close", forHTTPHeaderField: "Connection")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let zones = try? JSONDecoder().decode([ZoneDTO].self, from: data) else { return [] }
        var seen = Set<String>()
        return zones.compactMap { z in
            guard z.isActive, let poly = z.polygon, poly.count >= 3,
                  seen.insert(z.name).inserted else { return nil }
            return RawZone(id: z.id, name: z.name, polygon: poly)
        }
    }

    // MARK: - HTTP

    private func get<R: Decodable>(_ path: String) async throws -> R {
        try await request(path, header: "X-SDK-Key", value: key)
    }
    private func getPartner<R: Decodable>(_ path: String) async throws -> R {
        try await request(path, header: "X-Partner-Key", value: partnerKey)
    }
    private func request<R: Decodable>(_ path: String, header: String, value: String) async throws -> R {
        var req = URLRequest(url: URL(string: "https://\(host)/\(path)")!, timeoutInterval: 20)
        req.setValue(value, forHTTPHeaderField: header)
        req.setValue("close", forHTTPHeaderField: "Connection")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GsError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw GsError.badResponse(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(R.self, from: data) else { throw GsError.decode }
        return decoded
    }

    // MARK: - DTO

    private struct BuildingsResponse: Decodable {
        let buildings: [BuildingDTO]
        struct BuildingDTO: Decodable {
            let buildingId: String
            let buildingName: String
            let floors: [FloorDTO]
        }
        struct FloorDTO: Decodable {
            let floorId: String
            let floorName: String
            let hasPlan: Bool
        }
    }

    private struct PlanResponse: Decodable {
        let plan: PlanBody
        var image: PlanImage { plan.image }
        struct PlanBody: Decodable { let image: PlanImage }
    }

    /// console §6.4b 응답 (snake_case → convertFromSnakeCase 디코딩이라 PlanImage 그대로 맞음)
    private struct ConsolePlanResponse: Decodable {
        let hasPlan: Bool
        let floorName: String?
        let plan: Body?
        struct Body: Decodable { let image: PlanImage }
    }

    /// console §6.4 zones 응답 (snake_case)
    private struct ConsoleZonesResponse: Decodable {
        let zones: [Zone]
        struct Zone: Decodable {
            let zoneId: String
            let name: String
            let polygon: [[Double]]?
            let isActive: Bool
        }
    }

    /// console §6.2 buildings / §6.3 floors 응답 (snake_case)
    private struct ConsoleBuildingsResponse: Decodable {
        let buildings: [B]
        struct B: Decodable { let buildingId: String; let name: String }
    }
    private struct ConsoleFloorsResponse: Decodable {
        let floors: [F]
        struct F: Decodable { let floorId: String }
    }
    private struct PlanImage: Decodable {
        let dataUrl: String
        let widthM: Double
        let imgW: Int
        let imgH: Int
        let originX: Double
        let originY: Double
        func uiImage() -> UIImage? {
            let b64 = dataUrl.contains(",") ? String(dataUrl.split(separator: ",", maxSplits: 1)[1]) : dataUrl
            guard let data = Data(base64Encoded: b64) else { return nil }
            return UIImage(data: data)
        }
    }

    private struct AnchorResponse: Decodable { let anchors: [AnchorDTO] }
    private struct AnchorDTO: Decodable {
        let uwbMac: String?
        let x: Double?
        let y: Double?
        let sessionId: Int?          // = networkIdentifier (층별 UWB 세션)
        let clusterStatus: String?   // "auto_done"=배치완료 / "apply_failed" 등=미배치
        /// 주소 = UWB MAC 뒤 2바이트 (마지막 4 hex)
        func toAnchor() -> Anchor? {
            guard let mac = uwbMac, let x, let y,
                  let addr = Int(String(mac.suffix(4)), radix: 16) else { return nil }
            return Anchor(address: addr & 0xFFFF, x: x, y: y, z: 0)
        }
    }

    /// 파트너 zones 응답 = 최상위 배열. 폴리곤은 미터(0~13). (판정 파라미터 다수 있으나 지도엔 name/폴리곤만)
    private struct ZoneDTO: Decodable {
        let id: String          // zone_id (console 다운링크 큐와 동일 UUID)
        let name: String
        let isActive: Bool
        let polygon: [[Double]]?
    }
}

// MARK: - self-signed 인증서 우회 (필요 시)

extension Geospace3Client: URLSessionDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
