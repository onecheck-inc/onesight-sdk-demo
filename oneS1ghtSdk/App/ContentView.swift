//
//  ContentView.swift
//  oneS1ghtSdk
//
//  검증 앱 = "고객사 앱 시늉". OneS1ghtSDK 패키지를 소비한다:
//    · 측위 엔진(UwbPositioningProvider·패키지 내장)을 provider로 주입해 start
//    · zone 판정(PRM) → onZoneEvent 판정 배너 (로컬 훅)
//    · PRM IN → 서버 /events/zone → onTriggers — 존에 연결된 시책이 쿠폰이면 팝업
//

import SwiftUI
import UIKit
import OneS1ghtSDK

struct ContentView: View {
    var body: some View {
        if #available(iOS 27.0, *) {
            VerifyView()
        } else {
            ContentUnavailableView(
                "iOS 27+ 필요",
                systemImage: "exclamationmark.triangle",
                description: Text("DL-TDoA 측위는 iOS 27 이상에서만 동작합니다.")
            )
        }
    }
}

@available(iOS 27.0, *)
struct VerifyView: View {
    @StateObject private var provider = UwbPositioningProvider()   // 패키지 내장 UWB 어댑터
    @StateObject private var permission = PermissionHelper()
    @State private var showLogSheet = false                        // 하단 상태바 탭 → 전체 로그
    @State private var infra: FloorInfra?          // 받아온 도면 인프라
    /// 연결(초기화) 상태 — 문자열 파싱 대신 실제 상태로 판정
    private enum ConnState { case connecting, ready, failed }
    @State private var connState: ConnState = .connecting
    @State private var floorLoading = false   // 도면(GeoSpace) 로딩 중 — 층 전환 포함

    // 빌딩/층 선택
    @State private var buildings: [SpaceBuilding] = []
    @State private var selectedBuilding: SpaceBuilding?
    @State private var selectedFloor: SpaceFloor?

    /// 트래킹 시작 가능 여부 — 기기 지원 + 도면 로드됨 + 앵커 클러스터 배치완료(auto_done).
    /// (배치돼도 전원 이슈 등으로 신호가 없을 수 있어, 시작 후 watchdog가 최종 확인)
    private var canTrack: Bool {
        UwbPositioningProvider.isSupported && (infra?.positioningReady ?? false)
    }

    // Zone 이벤트 UI 상태
    @State private var showCoupon = false
    @State private var enteredArea: String?          // 현재 진입한 zone 이름 (지도가 알려줌)
    @State private var couponTitle = ""              // payload.title
    @State private var couponContent = ""            // payload.content
    @State private var pollTask: Task<Void, Never>?  // 존 진입 중 1초 큐 폴링
    @State private var zoneWatchTask: Task<Void, Never>?  // 존 0개일 때 1초 존 등록 감시
    @State private var zonesRefreshing = false            // 존 새로고침 중 (버튼 스피너)
    @State private var couponReceived = false        // 쿠폰 1회 수령 → 이번 세션 종료

    /// [데모] toast 배너 off — 메시지는 하단 상태바 로그로만 남긴다.
    private func showToast(_ text: String) {
        provider.note(text)
    }

    // 판정 팝업 — 엔진(PRM)이 IN/OUT/DWELL 을 발화하는 순간 화면 상단에 띄운다.
    // 걷기 검증 중 로그를 볼 수 없어 "지금 판정됐다"를 눈으로 확인하는 용도.
    @State private var judgeBanner: String?
    @State private var judgeBannerTask: Task<Void, Never>?
    private func showJudgeBanner(_ text: String) {
        judgeBanner = text
        judgeBannerTask?.cancel()
        judgeBannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { judgeBanner = nil }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // ── 빌딩·층 선택 ──
            HStack(alignment: .bottom, spacing: 12) {
                labeledPicker(Localized.text("label.building")) {
                    Menu {
                        ForEach(buildings) { b in Button(b.name) { selectBuilding(b) } }
                    } label: { pickerField("🏢", selectedBuilding?.name ?? Localized.text("picker.building")) }
                }
                labeledPicker(Localized.text("label.floor")) {
                    Menu {
                        ForEach(selectedBuilding?.floors ?? []) { f in Button(floorDisplayName(f)) { selectFloor(f) } }
                    } label: { pickerField("🗺", selectedFloor.map(floorDisplayName) ?? Localized.text("picker.floor")) }
                        .disabled(selectedBuilding == nil)
                }
            }

            // ── 지도 (도면 + 내 위치 빨간 점 + custom_area) — 화면 대부분 차지 ──
            // 존은 있으면 항상 표시 (on/off 토글 없음)
            // 원점 위경도가 있으면 구글맵 위에 도면을 얹고, 없으면 기존 캔버스로 그린다.
            Group {
                if let infra, let origin = ConfigDB.originFallback(floorId: infra.floorId) {
                    GoogleFloorMapView(provider: provider, infra: infra,
                                       origin: origin,
                                       mapRotation: mapRotation(for: selectedFloor?.id),
                                       showAreas: true,
                                       onAreaChange: { area in handleAreaChange(area) })
                } else {
                    FloorMapView(provider: provider, infra: infra,
                                 showAreas: true,
                                 onAreaChange: { area in handleAreaChange(area) },
                                 mapRotation: mapRotation(for: selectedFloor?.id))
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    // 존 새로고침 — 서버에서 존이 삭제/변경됐을 때 지도에 반영
                    // (0개가 되면 등록 감시 폴링도 다시 시작. 도는 동안 스피너 표시)
                    Button { refreshZones() } label: {
                        Group {
                            if zonesRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(radius: 2)
                    }
                    .padding(12)
                    .disabled(infra == nil || floorLoading || zonesRefreshing)
                }

            // 시작/종료 (풀폭)
            Button {
                handleTrackingButton()
            } label: {
                Text(trackingButtonText)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(provider.isRunning ? Color.orange : (canTrack ? Color.blue : Color.gray))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!provider.isRunning && !canTrack)   // 종료는 항상 가능, 시작은 canTrack일 때만

            // ── 연결 상태 (한 줄) — 탭하면 전체 로그 시트 ──
            HStack(spacing: 8) {
                Circle().fill(statusDot).frame(width: 9, height: 9)
                    .shadow(color: statusDot.opacity(0.6), radius: 3)
                Text(statusLine).font(.subheadline).fontWeight(.semibold)
                Spacer(minLength: 8)
                if let last = provider.log.last {
                    Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { showLogSheet = true }
        }
        .padding()
        .sheet(isPresented: $showLogSheet) {
            NavigationStack {
                List(Array(provider.log.enumerated()).reversed(), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
                .navigationTitle("로그 (\(provider.log.count))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: JudgmentLog.fileURL) {   // 판정 증적 파일 내보내기
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // 파트너 zone 진입 쿠폰 팝업
        .overlay {
            if showCoupon { couponPopup }
        }
        // 판정 팝업 배너 (상단)
        .overlay(alignment: .top) {
            if let judgeBanner {
                Text(judgeBanner)
                    .font(.callout.monospaced().bold())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: judgeBanner)
        .onAppear {
            // 서버 triggers(개인화 액션) — PRM IN 전송 → /events/zone 응답으로 도착.
            // 존에 연결된 시책이 쿠폰이면 팝업, 그 외(사이니지 등)는 toast.
            OneS1ghtSDK.onTriggers = { zoneId, triggers in
                for t in triggers {
                    if t.type == "coupon", !couponReceived {
                        couponTitle = t.payload?["title"] ?? "쿠폰"
                        couponContent = t.payload?["rule"] ?? ""
                        couponReceived = true                 // 세션당 1회
                        showToast("🎁 \(couponTitle)")
                        withAnimation { showCoupon = true }
                    } else {
                        showToast(Localized.format("log.serverAction", t.type))
                    }
                }
            }
            // SDK 내부 활동(verify·flush·zone 전송 결과)을 같은 로그창에 합류
            OneS1ghtSDK.onDebugLog = { line in
                provider.note("🌐 \(line)")
            }
            // 판정 증적 — 화면 로그는 200줄 링버퍼 휘발이라, 전 라인을 파일에 영속
            provider.onLog = { line in JudgmentLog.append(line) }
            // 판정 팝업 — 엔진 이벤트를 시각과 함께 화면에 (걷기 검증용)
            // ★ 쿠폰은 PRM 판정 기준: IN → 큐 폴링 시작 · OUT → 중지
            provider.onZoneEvent = { ev in
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "HH:mm:ss"
                showJudgeBanner("\(ev.label) · \(df.string(from: Date()))")
                switch ev {
                case .enter(let zone, _): startEventPolling(zoneId: zone.id)
                case .exit:               pollTask?.cancel(); pollTask = nil
                default:                  break
                }
            }
            // ① 앱 시작 시 초기화 — 키 검증 + 설정 프리페치 ("세션 가능?" 미리 판정)
            initializeSDK()
            // ② 빌딩/층 목록 로드 → 첫 빌딩·층 자동 선택 → 도면 로딩
            loadBuildingList()
        }
    }

    /// 층 표시 이름 치환 — GeoSpace에 층 이름 수정 API/UI가 없어(07-27 확인) 앱에서 표시만 교체.
    /// 서버 원본 이름("304로")은 그대로 두고 화면에만 적용. 서버에서 수정 가능해지면 제거.
    private func floorDisplayName(_ f: SpaceFloor) -> String {
        switch f.id {
        case "7aeb5ded-8dd2-4ed7-951f-4d18317910ce":
            return Localized.text("floor.jpMeetingRoom")   // 서버명: "304로"
        default:
            return f.name
        }
    }

    /// 층별 도면 회전각 (도면 원본 방향이 층마다 달라 지정).
    private func mapRotation(for floorId: String?) -> Double {
        switch floorId {
        case "7aeb5ded-8dd2-4ed7-951f-4d18317910ce": return 0     // 아카시아 304로
        case "15612d2d-c100-4ee3-80c7-fc813578bcb9": return 270   // 607호
        default:                                      return 270
        }
    }

    /// 캡션 라벨 + 픽커 필드 묶음
    private func labeledPicker<Content: View>(_ caption: String,
                                              @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content()
        }
    }

    /// 픽커 필드(알약형) — 아이콘 + 선택값 + 상하 셰브론
    private func pickerField(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(icon)
            Text(value).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    /// 이 층에서 측위(위치 확인) 가능한가 — 도면 로드됨 + 앵커 클러스터 배치완료
    private var floorPositionable: Bool { infra?.positioningReady ?? false }

    /// 연결 상태 점 색 (한 줄 상태바) — 실제 상태 기반
    private var statusDot: Color {
        if provider.isRunning { return .green }
        if floorLoading { return .orange }
        switch connState {
        case .connecting: return .orange
        case .failed:     return .red
        case .ready:      return floorPositionable ? .green : .gray   // 측위 불가 층 = 회색
        }
    }
    /// 연결 상태 한 줄 문구 — 측위중 > 도면로딩 > (준비완료 / 위치확인불가) / 연결중 / 오류
    private var statusLine: String {
        if provider.isRunning { return Localized.text("status.tracking") }
        if floorLoading { return Localized.text("status.loading") }
        switch connState {
        case .connecting: return Localized.text("status.connecting")
        case .failed:     return Localized.text("status.error")
        case .ready:
            // 도면은 떴지만 측위 안 되는 층이면 "위치 확인 불가"
            if infra != nil && !floorPositionable { return Localized.text("status.unavailable") }
            return Localized.text("status.connected")
        }
    }

    /// 버튼 라벨 — 권한·측위 상태 반영
    private var trackingButtonText: String {
        if provider.isRunning { return Localized.text("btn.stop") }
        if !UwbPositioningProvider.isSupported { return Localized.text("btn.unsupported") }
        if infra == nil { return Localized.text("btn.loading") }
        if !(infra?.positioningReady ?? false) { return Localized.text("btn.noPositioning") }
        if !permission.isLocationGranted { return Localized.text("btn.permission") }
        return Localized.text("btn.start")
    }

    /// 트래킹 버튼 — 권한 없으면 팝업, 있으면 SDK start/stop
    private func handleTrackingButton() {
        if provider.isRunning {
            pollTask?.cancel(); pollTask = nil   // 큐 폴링 중지
            enteredArea = nil
            provider.stop()                       // 즉시 isRunning=false → 상태 바로 전환
            Task { await OneS1ghtSDK.stop() }   // 코어 flush·타이머 정리
            return
        }
        switch permission.locationStatus {
        case .notDetermined:
            permission.requestLocation()
        case .authorizedWhenInUse, .authorizedAlways:
            startSDK()
        default:
            permission.openSettings()
        }
    }

    /// SDK 초기화 (앱 시작 시 1회) — 키 검증 + 설정 프리페치. 여기서 "세션 가능"이 판정됨.
    private func initializeSDK() {
        connState = .connecting
        Task {
            do {
                try await OneS1ghtSDK.initialize(
                    sdkKey: ConfigDB.sdkKey,
                    geospaceKey: ConfigDB.geospaceKey.isEmpty ? nil : ConfigDB.geospaceKey)
                connState = .ready
            } catch {
                connState = .failed
                provider.note("⚠️ 초기화 실패: \(error)")   // 실 연결 오류만 여기로
            }
        }
    }

    /// 빌딩/층 목록 로드 → 첫 빌딩·층 자동 선택.
    private func loadBuildingList() {
        Task {
            do {
                let list = try await OneS1ghtSDK.buildings()
                buildings = list
                provider.note(Localized.format("log.buildingsLoaded", list.count))
                // 기본 선택: 금정역 skv1 — 구글맵 원점 좌표가 있는 유일한 층이라 지도 검증이 여기서만 된다
                let defaultBuildingId = "0fe8f405-a710-44ee-96a2-f927c44b9cde"
                let defaultBuilding = list.first { $0.id == defaultBuildingId } ?? list.first
                if let defaultBuilding { selectBuilding(defaultBuilding) }
            } catch {
                provider.note(Localized.text("log.buildingsFail"))
            }
        }
    }

    /// 빌딩 선택 → 그 빌딩의 첫 층 자동 선택 후 로딩.
    private func selectBuilding(_ b: SpaceBuilding) {
        selectedBuilding = b
        if let f = b.floors.first { selectFloor(f) } else { selectedFloor = nil; infra = nil }
    }

    /// 층 선택 → 그 building/floor 의 도면·앵커·존 로딩.
    private func selectFloor(_ f: SpaceFloor) {
        selectedFloor = f
        guard let b = selectedBuilding else { return }
        // 층 변경 → 측위 즉시 중단. provider.stop()을 동기로 먼저 호출해 isRunning을 바로 꺼서
        // 상태가 "측위 중"에 안 걸리게 하고, 코어 정리·flush는 async로 뒤따른다.
        if provider.isRunning {
            provider.stop()                             // 즉시 isRunning=false + 빨간점 제거
            Task { await OneS1ghtSDK.stop() }     // 코어 flush·타이머 정리
        }
        infra = nil                              // 로딩 표시(도면 로딩 중…)
        floorLoading = true                      // 상태바 "도면 불러오는 중"
        enteredArea = nil; couponReceived = false
        pollTask?.cancel(); pollTask = nil
        zoneWatchTask?.cancel(); zoneWatchTask = nil
        Task {
            defer { floorLoading = false }
            do {
                // SDK 가 도면을 돌려주고 앵커·세션·존은 내부 엔진에 직접 주입한다.
                // 데모 provider 는 UI 관찰용으로 직접 보유 중이라 config 만 수동 반영.
                let loaded = try await OneS1ghtSDK.loadFloor(buildingId: b.id, floorId: f.id)
                infra = loaded
                let anchorDict = Dictionary(uniqueKeysWithValues:
                    loaded.anchors.map { ($0.address, SIMD3<Double>($0.x, $0.y, $0.z)) })
                provider.apply(config: PositioningConfig(anchors: anchorDict,
                                                         sessionId: loaded.sessionId,
                                                         zones: loaded.zones))
                provider.apply(buildingId: b.id, floorId: f.id)
                provider.note(Localized.format("log.floorLoaded", b.name, floorDisplayName(f),
                                     loaded.anchors.count, loaded.sessionId.map(String.init) ?? "-",
                                     loaded.zones.count))
                if loaded.zones.isEmpty { startZoneWatch(buildingId: b.id, floorId: f.id) }
            } catch {
                provider.note(Localized.format("log.floorFail", "\(error)"))
            }
        }
    }

    /// 존 새로고침 — 지금 존 목록을 다시 받아 지도에 반영 (삭제된 존 제거 포함).
    /// 결과가 0개면 등록 감시 폴링을 재시작한다.
    private func refreshZones() {
        guard let infra, !zonesRefreshing else { return }
        zoneWatchTask?.cancel(); zoneWatchTask = nil
        zonesRefreshing = true
        Task { @MainActor in
            let zones = await OneS1ghtSDK.refreshZones()
            try? await Task.sleep(nanoseconds: 700_000_000)   // 조회가 0.1초라 최소 스핀 시간 확보
            withAnimation { self.infra?.zones = zones }
            zonesRefreshing = false
            if zones.isEmpty {
                startZoneWatch(buildingId: infra.buildingId, floorId: infra.floorId)
            }
        }
    }

    /// 존 등록 감시 — 층에 존이 0개일 때 1초마다 재조회.
    /// console 에서 영역이 생성되면 지도에 바로 표시 + 폴링 종료(하나라도 오면 끝).
    private func startZoneWatch(buildingId: String, floorId: String) {
        zoneWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1초
                guard !Task.isCancelled, infra?.floorId == floorId else { return }
                let zones = await OneS1ghtSDK.refreshZones()
                if !zones.isEmpty {
                    withAnimation { infra?.zones = zones }    // 생기면 그냥 바로 보여줌
                    zoneWatchTask = nil
                    return                                          // 하나라도 있으면 종료
                }
            }
        }
    }

    /// 영역 진입/이탈 표시 — 지도 로컬 감지는 화면 toast까지만.
    /// 쿠폰 큐 폴링은 PRM IN 판정(onZoneEvent .enter → startEventPolling)이 트리거한다.
    private func handleAreaChange(_ area: Zone?) {
        guard let area else {                                  // 이탈
            if enteredArea != nil { showToast(Localized.text("log.areaExit")) }
            enteredArea = nil
            return
        }
        enteredArea = area.name                                // 진입 = Enter
        showToast(Localized.format("log.areaEnter", area.name))
    }

    /// PRM IN 판정 → 다운링크 큐 1초 폴링 시작 (쿠폰 등 인앱 이벤트). PRM OUT 이면 중지.
    private func startEventPolling(zoneId: String) {
        pollTask?.cancel(); pollTask = nil
        guard let infra, !couponReceived else { return }       // 이미 받았으면 세션 종료까지 안 띄움
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let payload = await EventQueueClient.pop(buildingId: infra.buildingId,
                                                            floorId: infra.floorId,
                                                            zoneId: zoneId) {
                    presentServerEvent(payload)                // 큐에 이벤트 있음 → 인앱 메시지
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1초
            }
        }
    }

    /// 서버가 내려준 이벤트 payload → 인앱 메시지 (kind에 맞춰 표시)
    /// title/content 는 언어 object: { "ko":…, "ja":…, "en":… } → Localized.value 가 OS 언어로 고름.
    private func presentServerEvent(_ payload: [String: Any]) {
        provider.note(Localized.text("log.eventReceived"))
        let kind = payload["kind"] as? String ?? "event"
        let title = Localized.value(from: payload["title"])
        let content = Localized.value(from: payload["content"])
        switch kind {
        case "coupon":
            couponTitle = title
            couponContent = content
            couponReceived = true                 // 쿠폰 1회 → 종료
            pollTask?.cancel(); pollTask = nil     // 더는 폴링 안 함
            showToast("🎁 \(title)")
            withAnimation { showCoupon = true }
        default:
            showToast("📩 \(title)")
        }
    }

    /// SDK 시작 (매장 진입) — initialize가 미리 끝나 있어 즉시 가동
    private func startSDK() {
        couponReceived = false   // 새 세션 → 쿠폰 다시 받을 수 있게
        Task {
            do {
                try await OneS1ghtSDK.start(consent: true,    // 검증 앱은 동의 전제
                                                   provider: provider)
                startReceptionWatchdog()   // 앵커 수신 감시 → 안 잡히면 자동 종료
            } catch {
                // start 실패는 연결(초기화) 오류와 별개 → 로그로만 (상태는 연결됨 유지)
                provider.note("⚠️ 측위 시작 실패: \(error)")
            }
        }
    }

    /// 시작 후 앵커 수신 감시 — 7초 내 유효앵커 부족(측위 불가)이면 경고 + 자동 종료.
    private func startReceptionWatchdog() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)   // 7초 (5초 자동진단 직후)
            guard provider.isRunning else { return }
            let d = provider.diagnostic
            guard !d.canPosition else { return }                // 앵커 잡힘 → 정상
            showToast(Localized.text("log.watchdogToast"))
            provider.note(Localized.format("log.watchdogNote", d.summary))
            handleTrackingButton()                              // isRunning → 종료 경로
        }
    }

    // ── 쿠폰 디자인 토큰 — AEON몰 방문객 쿠폰 스타일 (핑크 그라데이션) ──
    private var couponPinkBg: Color { Color(red: 0.984, green: 0.906, blue: 0.933) }     // #FBE7EE 연핑크 카드
    private var couponRose: Color { Color(red: 0.914, green: 0.361, blue: 0.529) }        // #E95C87 로즈
    private var couponMagenta: Color { Color(red: 0.729, green: 0.180, blue: 0.549) }     // #BA2E8C 마젠타
    private var couponInk: Color { Color(red: 0.11, green: 0.11, blue: 0.12) }
    private var couponGradient: LinearGradient {
        LinearGradient(colors: [couponRose, couponMagenta], startPoint: .leading, endPoint: .trailing)
    }

    /// 서버 다운링크 이벤트(coupon) 인앱 메시지 — AEON몰 방문객 쿠폰 레퍼런스 구도:
    /// 그라데이션 필 배너(제목) + 연핑크 카드·헤어라인 프레임 + DISCOUNT COUPON 뱃지 + 큰 혜택 텍스트(내용).
    private var couponPopup: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { withAnimation { showCoupon = false } }

            VStack(spacing: 16) {
                // ── 그라데이션 필 배너 (payload title) ──
                Text(couponTitle.isEmpty ? Localized.text("coupon.fallbackTitle") : couponTitle)
                    .font(.subheadline).fontWeight(.heavy)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Capsule().fill(couponGradient))
                    .shadow(color: couponMagenta.opacity(0.3), radius: 6, y: 3)

                Text(Localized.text("coupon.arrived"))
                    .font(.footnote).fontWeight(.bold)
                    .foregroundStyle(couponMagenta)

                // ── 혜택 행: DISCOUNT COUPON 뱃지 + 큰 혜택 텍스트 (payload content) ──
                HStack(spacing: 14) {
                    Text("DISCOUNT\nCOUPON")
                        .font(.caption).fontWeight(.heavy).tracking(1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(couponMagenta)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(couponMagenta, lineWidth: 1.6))

                    Text(couponContent.isEmpty
                         ? (couponTitle.isEmpty ? Localized.text("coupon.fallbackTitle") : couponTitle)
                         : couponContent)
                        .font(.system(size: 44, weight: .black))
                        .minimumScaleFactor(0.32).lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(couponGradient)
                }
                .padding(.vertical, 6)

                // ── CTA (그라데이션 알약) ──
                Button { withAnimation { showCoupon = false } } label: {
                    Text(Localized.text("coupon.receive"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(couponGradient))
                        .foregroundStyle(.white)
                }
                .padding(.top, 2)

                Text("\(Localized.text("coupon.limited"))・\(Localized.text("coupon.expiry"))")
                    .font(.caption2)
                    .foregroundStyle(couponMagenta.opacity(0.55))
            }
            .padding(24)
            .frame(maxWidth: 330)
            .background(couponPinkBg)
            .overlay {   // 헤어라인 프레임 (레퍼런스의 얇은 사각 테두리)
                RoundedRectangle(cornerRadius: 8)
                    .stroke(couponRose.opacity(0.55), lineWidth: 1)
                    .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(couponRose, lineWidth: 3))
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .padding(36)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

#Preview {
    ContentView()
}
