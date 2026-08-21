//
//  ContentView.swift
//  oneS1ghtSdk
//
//  검증 앱 = "고객사 앱 시늉". OneS1ght 패키지를 SPM 으로 소비한다(upToNextMajor 0.1.0 → 현재 0.1.3):
//    · 측위 엔진(UwbPositioningProvider·패키지 내장)을 provider로 주입해 start
//    · zone 판정(PRM) → onZoneEvent 판정 배너 (로컬 훅)
//    · PRM IN → 서버 /events/zone → onTriggers — 존에 연결된 시책이 쿠폰이면 팝업
//

import SwiftUI
import UIKit
import OneS1ght

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
    @State private var buildings: [Building] = []
    @State private var selectedBuilding: Building?
    /// v0.1.0 부터 Building 이 층을 품지 않는다(floorCount 만) — 층은 따로 받아 여기 둔다.
    @State private var floors: [Floor] = []
    @State private var selectedFloor: Floor?
    // 마지막 선택 복원은 두지 않는다. 편의로 넣었다가, 앱을 켜자마자 아무것도 고르지 않았는데
    // 층 목록·도면 요청이 나가고 실패 로그만 쌓이는 상태가 됐다 — 화면과 로그가 어긋난다.
    // 검증 앱에서는 "무엇을 눌렀을 때 무엇이 일어나는가" 가 눈에 보이는 편이 낫다.
    /// 서버가 발급한 프로필 ID — 앱이 보관해 재사용한다(기기마다 하나).
    /// 매번 새로 만들면 같은 기기의 방문이 사람 수만큼 갈라져 리포트가 어긋난다.
    @AppStorage("profileId") private var storedProfileId = ""

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
    @State private var pollTask: Task<Void, Never>?  // 진행 중인 존 이벤트 조회 (재진입 시 교체)
    @State private var zoneWatchTask: Task<Void, Never>?  // 존 0개일 때 1초 존 등록 감시
    @State private var zonesRefreshing = false            // 존 새로고침 중 (버튼 스피너)
    /// 측위 세션 ID — 시작할 때 발급, 종료하면 소멸. 존 이벤트 조회에 실어 보낸다.
    /// 서버가 이 값으로 "이 세션에 이미 보냈나"를 판정하므로, 앱 로컬 1회 플래그는 두지 않는다
    /// (로컬로 막으면 콘솔 [테스트]로 수신기록을 초기화해도 앱이 스스로 막아버린다).
    @State private var eventSessionId: String?

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
                        ForEach(floors) { f in Button(floorDisplayName(f)) { selectFloor(f) } }
                    } label: { pickerField("🗺", selectedFloor.map(floorDisplayName) ?? Localized.text("picker.floor")) }
                        .disabled(selectedBuilding == nil)
                }
            }

            // ── 지도 (도면 + 내 위치 빨간 점 + custom_area) — 화면 대부분 차지 ──
            // 존은 있으면 항상 표시 (on/off 토글 없음)
            // 원점 위경도가 있으면 구글맵 위에 도면을 얹고, 없으면 기존 캔버스로 그린다.
            Group {
                if let infra {
                    GoogleFloorMapView(provider: provider, infra: infra,
                                       origin: LocationTransformer.defaultOrigin,
                                       mapRotation: mapRotation(for: infra),
                                       showAreas: true,
                                       onAreaChange: { area in handleAreaChange(area) })
                } else {
                    // 도면 로딩 전 — 캔버스 뷰가 빈 상태를 그린다
                    FloorMapView(provider: provider, infra: nil,
                                 showAreas: true,
                                 onAreaChange: { area in handleAreaChange(area) },
                                 mapRotation: mapRotation(for: nil))
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
            // SDK 내부 활동(verify·flush·zone 전송 결과)을 같은 로그창에 합류.
            // ⚠️ initialize 보다 먼저 걸어야 초기화 단계 로그를 놓치지 않는다.
            OneS1ght.onDebugLog = { line in
                provider.note("🌐 \(line)")
            }
            // 판정 증적 — 화면 로그는 200줄 링버퍼 휘발이라, 전 라인을 파일에 영속
            provider.onLog = { line in JudgmentLog.append(line) }
            // 판정 팝업 — 엔진 이벤트를 시각과 함께 화면에 (걷기 검증용)
            // ★ 쿠폰은 PRM 판정 기준: IN 에서 이벤트 1회 조회 · OUT 이면 진행 중인 조회 취소
            provider.onZoneEvent = { ev in
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "HH:mm:ss"
                showJudgeBanner("\(ev.label) · \(df.string(from: Date()))")
                switch ev {
                case .enter(let zone, _): fetchZoneEvent(zoneId: zone.id)
                case .exit:               pollTask?.cancel(); pollTask = nil
                default:                  break
                }
            }
            // ① 앱 시작 시 초기화 — 키 검증 + 설정 프리페치 ("세션 가능?" 미리 판정)
            //    ② 세션 콜백 등록과 ③ 빌딩 목록 로드는 초기화가 끝난 뒤에 이어진다.
            //    ⚠️ v0.1.0 부터 초기화 전 호출은 notInitialized(E1001) 로 실패한다 —
            //       옛 API 처럼 나란히 부르면 목록이 비어 보인다.
            initializeSDK()
        }
    }

    /// 층 표시 이름 — 서버에 잘못 등록된 이름을 화면에서만 교체한다.
    /// GeoSpace 에 층 이름 수정 API/UI 가 없어(07-27 확인) 앱이 떠안고 있다. 서버에서 고치면 제거.
    private func floorDisplayName(_ f: Floor) -> String {
        f.name == "304로" ? Localized.text("floor.meetingRoom") : f.name
    }

    /// 도면 회전각 — 지금은 회전 없음(위쪽 = 도면 원본 위쪽).
    /// 가로 도면을 270°로 돌리면 세로 화면을 꽉 채우지만 방향 감각이 바뀌어, 확인 전까지 보류한다.
    /// 지도는 회전 제스처가 살아 있어 손으로 돌릴 수 있다.
    /// (서버 plan.rotationDeg 는 층 정렬 전이라 전부 0 — 채워지면 그 값을 쓴다)
    private func mapRotation(for infra: FloorInfra?) -> Double { 0 }

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
            pollTask?.cancel(); pollTask = nil   // 진행 중인 이벤트 조회 중단
            eventSessionId = nil                 // 측위 종료 = 세션 소멸 (다시 시작하면 새 ID)
            enteredArea = nil
            provider.stop()                       // 즉시 isRunning=false → 상태 바로 전환
            endSession()                          // 코어 flush·타이머 정리
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

    /// 측위 세션 종료 — 잔여 좌표 flush + 타이머 정리.
    /// floorSession() 은 초기화 전이면 throw 하므로 조용히 넘어간다(끌 세션이 애초에 없다).
    private func endSession() {
        Task { @MainActor in
            if let session = try? OneS1ght.floorSession() { await session.end() }
        }
    }

    /// SDK 초기화 (앱 시작 시 1회) — 키 검증 + 설정 프리페치. 여기서 "세션 가능"이 판정됨.
    private func initializeSDK() {
        connState = .connecting
        Task {
            do {
                try await OneS1ght.initialize(
                    sdkKey: ConfigDB.sdkKey,
                    geoSdkKey: ConfigDB.geospaceKey.isEmpty ? nil : ConfigDB.geospaceKey)

                // 프로필 연결 — 없으면 좌표·존 이벤트가 어디에도 귀속되지 않는다(E1004).
                // 검증 앱이라 기기에 하나 만들어 두고 계속 재사용한다.
                if storedProfileId.isEmpty {
                    storedProfileId = try await OneS1ght.createProfile([:])
                    provider.note("🆕 프로필 발급 \(storedProfileId)")
                }
                OneS1ght.identify(profileId: storedProfileId)

                bindSessionCallbacks()
                connState = .ready
                loadBuildingList()          // 초기화가 끝나야 조회가 통한다
            } catch {
                connState = .failed
                provider.note("⚠️ 초기화 실패: \(error)")   // 실 연결 오류만 여기로
            }
        }
    }

    /// 세션 콜백 — 서버 triggers(개인화 액션)는 PRM IN 전송 → /events/zone 응답으로 도착.
    /// 존에 연결된 시책이 쿠폰이면 팝업, 그 외(사이니지 등)는 toast.
    /// ⚠️ floorSession() 은 초기화 후에만 얻을 수 있다.
    @MainActor
    private func bindSessionCallbacks() {
        guard let session = try? OneS1ght.floorSession() else { return }
        session.onTriggers = { _, triggers in
            for t in triggers {
                if t.type == "coupon" {
                    couponTitle = t.payload?["title"] ?? "쿠폰"
                    couponContent = t.payload?["rule"] ?? ""
                    showToast("🎁 \(couponTitle)")
                    withAnimation { showCoupon = true }
                } else {
                    showToast(Localized.format("log.serverAction", t.type))
                }
            }
        }
    }

    /// 빌딩 목록만 채운다. **여기서 층도 도면도 부르지 않는다.**
    ///
    /// 예전에는 목록을 받자마자 첫 건물·첫 층을 스스로 골라 도면 요청까지 냈다. 화면에는
    /// '빌딩 선택'·'층 선택' 이 그대로 떠 있는데 뒤에서는 요청이 나가고 실패 로그만 쌓였다.
    /// 이제는 사용자가 건물을 고를 때까지 아무 요청도 나가지 않는다.
    private func loadBuildingList() {
        Task {
            do {
                let list = try await OneS1ght.buildings()
                buildings = list
                provider.note(Localized.format("log.buildingsLoaded", list.count))
            } catch {
                provider.note(Localized.text("log.buildingsFail"))
            }
        }
    }

    /// 빌딩 선택 → 그 건물의 층 목록만 조회한다. 도면은 층을 고른 뒤에 부른다.
    /// v0.1.0 부터 Building 이 층을 품지 않아 층 조회가 한 번 더 필요하다.
    private func selectBuilding(_ b: Building) {
        selectedBuilding = b
        selectedFloor = nil
        floors = []
        infra = nil
        Task {
            do {
                let list = try await OneS1ght.floors(b.id)
                floors = list
                provider.note(Localized.format("log.floorsLoaded", list.count))
                // 층은 사용자가 고른다 — 첫 층을 임의로 골라 도면을 부르지 않는다.
            } catch {
                // ⚠️ 여기서 실패한 것은 **층 목록**이다. 예전에는 도면 실패와 같은 문구가 떠서
                //    화면만 보고는 어디가 막혔는지 알 수 없었다.
                provider.note(Localized.format("log.floorListFail", "\(error)"))
            }
        }
    }

    /// 층 선택 → 그 building/floor 의 도면·앵커·존 로딩.
    private func selectFloor(_ f: Floor) {
        selectedFloor = f
        guard let b = selectedBuilding else { return }
        // 층 변경 → 측위 즉시 중단. provider.stop()을 동기로 먼저 호출해 isRunning을 바로 꺼서
        // 상태가 "측위 중"에 안 걸리게 하고, 코어 정리·flush는 async로 뒤따른다.
        if provider.isRunning {
            provider.stop()                             // 즉시 isRunning=false + 빨간점 제거
            endSession()                                // 코어 flush·타이머 정리
        }
        infra = nil                              // 로딩 표시(도면 로딩 중…)
        floorLoading = true                      // 상태바 "도면 불러오는 중"
        enteredArea = nil
        pollTask?.cancel(); pollTask = nil
        zoneWatchTask?.cancel(); zoneWatchTask = nil
        Task {
            defer { floorLoading = false }
            do {
                // 도면·로케이터·존을 한 번에 받고 엔진 주입(setFloorMap)까지 끝낸다(SdkCompat).
                // 데모 provider 는 UI 관찰용으로 직접 보유 중이라 config 만 수동 반영.
                let loaded = try await FloorInfra.load(buildingId: b.id, floorId: f.id)
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
            let zones = await OneS1ght.refreshZones()
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
                let zones = await OneS1ght.refreshZones()
                if !zones.isEmpty {
                    withAnimation { infra?.zones = zones }    // 생기면 그냥 바로 보여줌
                    zoneWatchTask = nil
                    return                                          // 하나라도 있으면 종료
                }
            }
        }
    }

    /// 영역 진입/이탈 표시 — 지도 로컬 감지는 화면 toast까지만.
    /// 쿠폰 조회는 PRM IN 판정(onZoneEvent .enter → fetchZoneEvent)이 트리거한다.
    private func handleAreaChange(_ area: Zone?) {
        guard let area else {                                  // 이탈
            if enteredArea != nil { showToast(Localized.text("log.areaExit")) }
            enteredArea = nil
            return
        }
        enteredArea = area.name                                // 진입 = Enter
        showToast(Localized.format("log.areaEnter", area.name))
    }

    /// PRM IN 판정 → 존 이벤트 1회 조회 (쿠폰 등 인앱 이벤트).
    /// 서버가 호출 시점에 결정적인 답을 주므로 폴링하지 않는다. 이탈 후 재진입 시 다시 불러도
    /// 같은 session_id 면 서버가 빈 배열로 답한다.
    private func fetchZoneEvent(zoneId: String) {
        pollTask?.cancel()
        guard let infra, let sid = eventSessionId else { return }
        pollTask = Task { @MainActor in
            let events = await EventQueueClient.fetch(buildingId: infra.buildingId,
                                                      floorId: infra.floorId,
                                                      zoneId: zoneId, sessionId: sid)
            guard !Task.isCancelled else { return }
            for payload in events { presentServerEvent(payload) }
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
            showToast("🎁 \(title)")
            withAnimation { showCoupon = true }
        default:
            showToast("📩 \(title)")
        }
    }

    /// SDK 시작 (매장 진입) — initialize가 미리 끝나 있어 즉시 가동
    private func startSDK() {
        let sid = Self.makeSessionId()
        eventSessionId = sid                     // 이번 측위 동안 유지 — 종료 시 소멸
        provider.note("🆔 측위 세션 \(sid)")
        Task {
            do {
                // 검증 앱은 UI 관찰을 위해 provider 를 직접 들고 있으므로 주입 오버로드를 쓴다.
                // (일반 연동은 인자 없는 begin() — SDK 가 내부에서 만든다)
                try await OneS1ght.floorSession().begin(provider: provider)
                startReceptionWatchdog()   // 앵커 수신 감시 → 안 잡히면 자동 종료
            } catch {
                // 시작 실패는 연결(초기화) 오류와 별개 → 로그로만 (상태는 연결됨 유지)
                provider.note("⚠️ 측위 시작 실패: \(error)")
            }
        }
    }

    /// 측위 세션 ID — 영숫자 10자리. 62^10 ≈ 8×10^17 이라 충돌은 사실상 없다.
    private static func makeSessionId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
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
