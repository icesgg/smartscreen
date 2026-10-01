import Foundation
import CoreBluetooth
import SmartScreenCore

/// 진단용 명령줄 모드 (Windows 의 tools/ProbeScan.exe, AdvScan.exe, BtCheck.exe 자리).
///
///   SmartScreen --probe-scan [초=20] [identifier]   잠긴 아이폰에서 신원 토큰을 읽을 수 있는지
///   SmartScreen --adv-scan [초=30]                  다른 PC 의 SmartScreen 광고가 잡히는지
///   SmartScreen --bt-check                          이 Mac 의 블루투스 역할 지원
///
/// NSApplication 없이 돈다. CoreBluetooth 는 메인 큐(queue: nil)로 콜백을 주고, 여기서는
/// RunLoop.main 을 직접 돌리며 기다린다 - 그래서 코드를 위에서 아래로 차례대로 쓸 수 있다.
/// Windows 도구의 한국어 출력을 그대로 쓰되, Mac 에 없는 것(페어링 상태, GattSession,
/// "아무 키나 누르세요")은 뺐다. 터미널 창은 저절로 닫히지 않는다.
///
/// 터미널에서 실행하면 macOS 는 블루투스 권한을 SmartScreen 이 아니라 그 터미널 앱에 묻는다
/// (권한은 "책임 프로세스" 단위다). 그래서 이 도구들의 권한 문구만 터미널 앱 이름을 말한다.
enum BLEDiagnostics {

    // MARK: - --probe-scan

    /// 3단계의 마지막 단계 길이 (초). 앱처럼 두 스캔을 함께 돌려 보는 것이라 짧게 둔다.
    private static let bothPhaseSec = 10
    /// 토큰을 읽어 볼 후보의 상한. 한 대가 최악 50초 남짓이라 이보다 많으면 기다리다 지친다.
    private static let maxProbes = 6

    /// --probe-scan [sec] [identifier]
    /// 배경: 잠긴 아이폰의 광고에는 이름도 서비스 UUID 도 실리지 않고 바뀌는 주소만 남는다.
    /// PC 가 central 로 붙어 토큰 특성을 읽으면 IRK 없이 신원이 확정된다 - 그게 되는지를 본다.
    ///
    /// Mac 에서는 특히 "어느 길로 잠긴 폰을 찾는가" 를 한 번에 가른다 (맥북 시험 한 번이 비싸다):
    ///   1 필터 스캔      - macOS 의 서비스 필터가 overflow 영역의 UUID 를 맞춰 주는가
    ///   2 직접 읽기 스캔 - 거르지 않으면 제조사 데이터 `4C 00 01 + 16바이트` 가 오는가 (Windows 방식).
    ///                      Apple 광고에 실린 키 이름도 보인다 (macOS 가 overflow 를 다른 키로 바꿔
    ///                      주는지 - 공개되지 않은 키가 있으면 그 값의 예도)
    ///   3 둘 다 동시에   - 앱처럼 둘을 함께 돌리면 한쪽이 끊기는가
    /// 그다음 후보에 붙어 토큰을 읽고, 붙여 넣기 좋은 요약으로 끝낸다.
    static func probeScan(args: [String]) -> Int32 {
        let ops = operands(args, flag: "--probe-scan")
        var seconds = ops.count > 0 ? ConfigStore.wtoi(ops[0]) : 20
        if seconds < 5 { seconds = 5 }
        let only = ops.count > 1 ? ops[1].uppercased() : ""
        // 등록된 토큰이 있으면 읽은 토큰과 대조한다 (읽기만 한다)
        let registered = ConfigStore.load().phoneToken.uppercased()

        emit("아이폰 신원 토큰 읽기 확인")
        emit("=====================================")
        emit("찾는 서비스: {\(BLEIds.identService.uuidString)}")
        emit("읽을 특성  : {\(BLEIds.identToken.uuidString)}\n")
        emit("아이폰에서 SSBeacon 을 실행한 뒤 화면을 끄고 잠근 상태로 두세요.")
        emit("이 Mac 과 아이폰이 페어링되어 있지 않아야 실제 배포 상황과 같습니다.")
        emit("SmartScreen 이 켜져 있으면 오른쪽 위 상자의 [종료] 로 끈 뒤 실행하면 결과가 깨끗합니다.")
        emitTerminalPermissionHint()
        emit("")

        let dF = DiagCentral()
        if !waitPoweredOn(dF) {
            emitCentralFailure(dF)
            return 1
        }

        let book = ProbeBook(only: only)
        let s1 = PhaseStats(seconds: seconds)
        let s2 = PhaseStats(seconds: seconds)
        let s3 = PhaseStats(seconds: bothPhaseSec)
        // R 의 기기 객체는 R 의 관리자로만 붙을 수 있으므로 탐색이 끝날 때까지 살려 둔다
        var dR: DiagCentral?
        var scanned = true

        if !only.isEmpty {
            // 식별자(전체 UUID 또는 로그에 찍힌 앞 12자리)를 주면 그 기기만 찔러 본다.
            emit("주소 \(only) 만 확인합니다.")
            if let u = UUID(uuidString: only),
               let p = dF.manager.retrievePeripherals(withIdentifiers: [u]).first {
                var c = UnionCand()
                c.viaF = p
                c.retrieved = true
                book.cands[u] = c
                scanned = false
            }
        }

        if scanned {
            let r = DiagCentral()
            // 권한은 첫 관리자에서 이미 답했으므로 곧 켜진다
            let rawOk = waitPoweredOn(r)
            dR = r
            emit("세 단계로 찾습니다 (모두 \(seconds * 2 + bothPhaseSec)초쯤).")
            emit("  1 필터 스캔       \(seconds)초 - 신원 서비스 UUID 로 걸러 달라고 macOS 에 맡긴다")
            emit("  2 직접 읽기 스캔  \(seconds)초 - 거르지 않고 제조사 데이터(4C 00 01 + 16바이트)를 읽는다")
            emit("  3 둘 다 동시에    \(bothPhaseSec)초 - SmartScreen 이 실제로 도는 모양")

            emit("\n[1/3] 필터 스캔 \(seconds)초...")
            runPhase(s1, book, filter: dF, raw: nil)
            emitFilterPhase(s1)

            emit("\n[2/3] 직접 읽기 스캔 \(seconds)초...")
            if rawOk {
                runPhase(s2, book, filter: nil, raw: r)
                emitRawPhase(s2, book)
            } else {
                emit("  두 번째 스캔 관리자가 켜지지 않아 건너뜁니다 (\(BLEIds.stateName(r.manager.state)))")
            }

            emit("\n[3/3] 둘 다 동시에 \(bothPhaseSec)초...")
            runPhase(s3, book, filter: dF, raw: rawOk ? r : nil)
            emitBothPhase(s3)
        }

        // 신원 UUID 를 직접 본 것 먼저, 그다음 가까운 것부터 - 멀리 있는 남의 폰은 자리 판정에 쓸모가 없다
        let all = book.cands.values.sorted { a, b in
            if a.sure != b.sure { return a.sure }
            return a.rssi > b.rssi
        }
        let list = Array(all.prefix(maxProbes))
        emit("\n후보 \(all.count)대" + (all.count > maxProbes
            ? " - 앞의 \(maxProbes)대만 시도합니다 (신원 UUID 를 본 것 먼저, 그다음 신호 순)" : ""))

        var discovered = 0
        var hits: [TokenHit] = []
        for c in list {
            // F 의 객체가 있으면 F 의 관리자로 (앱과 같은 순서), 없으면 R 의 것으로 붙는다
            let d: DiagCentral
            let p: CBPeripheral
            if let fp = c.viaF {
                d = dF
                p = fp
            } else if let rp = c.viaR, let rd = dR {
                d = rd
                p = rp
            } else {
                continue
            }
            let r = probe(d, p, c)
            if r.code >= 1 { discovered += 1 }
            if r.code == 2 {
                hits.append(TokenHit(cand: c, id: p.identifier, token: r.token))
                if !registered.isEmpty {
                    emit(r.token == registered
                         ? "      (등록된 토큰과 같습니다)"
                         : "      (등록된 토큰과 다릅니다 - 다른 사람의 폰이거나, 앱을 다시 설치해 토큰이 바뀌었습니다)")
                }
            }
        }

        emit("\n=====================================")
        if list.isEmpty {
            emit("결과: 후보가 없습니다.")
            emit("      아이폰에서 SSBeacon 이 실제로 광고 중인지 확인하세요.")
            emit("      (앱을 켠 채 화면을 끄면 잠금 상태에서도 광고가 이어져야 합니다)")
        } else {
            emit("후보 \(list.count)대 중 서비스 탐색 성공 \(discovered)대, 토큰 읽기 성공 \(hits.count)대")
            if !hits.isEmpty {
                emit("\n결과: 잠긴 폰에서 신원 토큰을 읽었습니다.")
                emit("      IRK 도 Phone Link 도 없이 폰을 특정할 수 있습니다.")
            } else if discovered > 0 {
                emit("\n결과: 연결과 서비스 탐색은 되는데 신원 서비스가 안 보입니다.")
                emit("      아이폰 앱이 신원 서비스를 올리는 버전인지 확인하세요.")
                emit("      (앱을 지웠다 다시 설치한 뒤 한 번 실행해야 반영됩니다)")
            } else {
                emit("\n결과: 붙지 못했습니다.")
                emit("      AccessDenied 면 macOS 가 페어링을 요구하는 것입니다.")
                emit("      전부 Unreachable 이면 폰이 아니라 이 Mac 의 블루투스가")
                emit("      직전 연결을 아직 물고 있는 경우가 많습니다. 1~2분 두었다")
                emit("      다시 실행해 보세요.")
            }
        }

        emitSummary(scanned: scanned, s1: s1, s2: s2, s3: s3, book: book, tried: list.count,
                    discovered: discovered, hits: hits, registered: registered)
        return 0
    }

    /// 한 단계: 주어진 관리자들로 정해진 초만큼 훑는다. 콜백은 메인 큐에서 오고 spin 이 런루프를 돌린다.
    private static func runPhase(_ st: PhaseStats, _ book: ProbeBook, filter: DiagCentral?, raw: DiagCentral?) {
        // allowDuplicates 가 없으면 기기마다 한 번뿐이라 광고 수도 최고 신호도 셀 수 없다
        let dup: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        if let f = filter {
            st.ranFilter = true
            f.onDiscover = { p, adv, rssi in BLEDiagnostics.noteFilter(book, st, p, adv, rssi) }
            // 잠긴 폰의 UUID 는 이 UUID 를 명시해서 찾는 스캐너에게만 보인다 (iOS 의 규칙)
            f.manager.scanForPeripherals(withServices: [BLEIds.identService], options: dup)
        }
        if let r = raw {
            st.ranRaw = true
            r.onDiscover = { p, adv, rssi in BLEDiagnostics.noteRaw(book, st, p, adv, rssi) }
            r.manager.scanForPeripherals(withServices: nil, options: dup)
        }
        _ = spin(Double(st.seconds)) { false }
        if let f = filter {
            f.manager.stopScan()
            f.onDiscover = nil
        }
        if let r = raw {
            r.manager.stopScan()
            r.onDiscover = nil
        }
    }

    /// 필터 스캔이 준 광고. 필터가 맞춘 것이므로 UUID 목록이 비어 있어도 후보다 (앱도 그렇게 한다) -
    /// 목록이 비어 있는 채로 오는지가 그 자체로 알아야 할 것이라 따로 센다.
    private static func noteFilter(_ book: ProbeBook, _ st: PhaseStats, _ p: CBPeripheral,
                                   _ adv: [String: Any], _ rssi: Int) {
        st.filterAdverts += 1
        let id = p.identifier
        let plain = ((adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).contains(BLEIds.identService)
        let overflow = ((adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])
            .contains(BLEIds.identService)
        let r = BLEIds.validRssi(rssi) ? rssi : -127
        var s = st.filter[id] ?? FilterSeen()
        s.rssi = max(s.rssi, r)
        s.plain = s.plain || plain
        s.overflow = s.overflow || overflow
        st.filter[id] = s

        if !book.only.isEmpty && !matchesFilter(id, book.only) { return }
        var c = book.cands[id] ?? UnionCand()
        c.viaF = p
        c.plain = c.plain || plain
        c.overflowKey = c.overflowKey || overflow
        c.rssi = max(c.rssi, r)
        if c.name.isEmpty { c.name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? "" }
        book.cands[id] = c
    }

    /// 거르지 않은 스캔의 광고 하나. 전부 세고, Apple 광고는 키를 모으고, overflow 모양은 기기별로
    /// 비트를 적는다. 후보는 앱과 같다: 비트가 딱 하나이거나 UUID 목록에 신원 UUID 가 있는 것.
    private static func noteRaw(_ book: ProbeBook, _ st: PhaseStats, _ p: CBPeripheral,
                                _ adv: [String: Any], _ rssi: Int) {
        st.rawAdverts += 1
        let id = p.identifier
        let r = BLEIds.validRssi(rssi) ? rssi : -127
        var bits: [Int]?
        if let md = adv[CBAdvertisementDataManufacturerDataKey] as? Data {
            let b = [UInt8](md)
            if AppleOverflow.isApple(b) {
                st.appleAdverts += 1
                bits = AppleOverflow.bits(b)
                for (k, v) in adv where book.appleKeys.insert(k).inserted && !publicAdvKeys.contains(k) {
                    // 공개되지 않은 키: 값의 예를 하나 남긴다 (overflow 를 풀어 준 것일 수 있다)
                    book.privateSamples[k] = shortDescription(v)
                }
                if let bb = bits {
                    // overflow 모양 광고에 실린 키는 따로 - "그 광고를 macOS 가 어떻게 주는가" 의 답이다
                    for k in adv.keys { book.overflowKeys.insert(k) }
                    var o = st.overflow[id] ?? OverflowSeen()
                    o.rssi = max(o.rssi, r)
                    o.bits = bb
                    st.overflow[id] = o
                }
            }
        }
        let plain = ((adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).contains(BLEIds.identService)
        let overflow = ((adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])
            .contains(BLEIds.identService)
        let listed = plain || overflow
        if listed { st.rawListed.insert(id) }
        let single = (bits?.count == 1) ? bits![0] : -1
        if single < 0 && !listed { return }
        if !book.only.isEmpty && !matchesFilter(id, book.only) { return }
        var c = book.cands[id] ?? UnionCand()
        c.viaR = p
        if single >= 0 { c.bit = single }
        if listed { c.rawList = true }
        c.plain = c.plain || plain
        c.overflowKey = c.overflowKey || overflow
        c.rssi = max(c.rssi, r)
        if c.name.isEmpty { c.name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? "" }
        book.cands[id] = c
    }

    private static func emitFilterPhase(_ st: PhaseStats) {
        if st.filter.isEmpty {
            emit("  필터가 아무것도 주지 않았습니다 (광고 \(st.filterAdverts)건)")
            return
        }
        emit("  필터가 준 기기 \(st.filter.count)대 (광고 \(st.filterAdverts)건)")
        let rows = st.filter.sorted { $0.value.rssi > $1.value.rssi }
        for (id, s) in rows.prefix(10) {
            var flags: [String] = []
            if s.overflow { flags.append("overflow UUID") }
            if s.plain { flags.append("[광고에 서비스 UUID 노출]") }
            if !s.overflow && !s.plain { flags.append("UUID 목록 없음") }
            emit("    주소 \(BLEIds.shortId(id))  최고 \(s.rssi) dBm  " + flags.joined(separator: "  "))
        }
        if rows.count > 10 { emit("    (외 \(rows.count - 10)대)") }
    }

    private static func emitRawPhase(_ st: PhaseStats, _ book: ProbeBook) {
        emit("  광고 \(st.rawAdverts)건, 그중 Apple(4C 00) \(st.appleAdverts)건, "
             + "overflow 모양(4C 00 01 + 16바이트) \(st.overflow.count)대")
        let rows = st.overflow.sorted { $0.value.rssi > $1.value.rssi }
        for (id, o) in rows.prefix(15) {
            emit("    주소 \(BLEIds.shortId(id))  최고 \(o.rssi) dBm  " + bitsText(o.bits))
        }
        if rows.count > 15 { emit("    (외 \(rows.count - 15)대)") }
        if !st.rawListed.isEmpty {
            emit("  UUID 목록에 신원 서비스가 실린 기기 \(st.rawListed.count)대")
        }
        if book.appleKeys.isEmpty {
            emit("  Apple 광고가 하나도 없었습니다 - macOS 가 Apple 제조사 데이터를 앱에 주지 않는 것일 수 있습니다")
        } else {
            emit("  Apple 광고에서 본 키: " + book.appleKeys.sorted().joined(separator: ", "))
            if !book.overflowKeys.isEmpty {
                emit("  overflow 모양 광고의 키: " + book.overflowKeys.sorted().joined(separator: ", "))
            }
            if !book.privateSamples.isEmpty {
                emit("  공개되지 않은 키의 값 예:")
                for k in book.privateSamples.keys.sorted() {
                    emit("    \(k) = \(book.privateSamples[k] ?? "")")
                }
            }
        }
    }

    private static func emitBothPhase(_ st: PhaseStats) {
        var line = "  필터가 준 기기 \(st.filter.count)대"
        if st.ranRaw {
            line += ", overflow 모양 \(st.overflow.count)대 (비트 하나 \(singleBitCount(st))대)"
        } else {
            line += ", 직접 읽기는 못 했습니다"
        }
        emit(line)
    }

    /// 붙여 넣기용 요약. 줄마다 한 가지 - 다음 세션이 이것만 보고 어느 길을 살릴지 정한다.
    private static func emitSummary(scanned: Bool, s1: PhaseStats, s2: PhaseStats, s3: PhaseStats,
                                    book: ProbeBook, tried: Int, discovered: Int, hits: [TokenHit],
                                    registered: String) {
        emit("\n=============== 요약 ===============")
        emit("(이 블록을 그대로 복사해 붙여 넣어 주세요)")
        emit("SmartScreen \(BuildInfo.version) / macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if scanned {
            let f1 = s1.filter.values
            emit("1 필터 스캔 \(s1.seconds)초: 기기 \(s1.filter.count)대 (overflow UUID \(f1.filter { $0.overflow }.count), "
                 + "서비스 UUID 노출 \(f1.filter { $0.plain }.count), "
                 + "목록 없음 \(f1.filter { !$0.overflow && !$0.plain }.count)), 광고 \(s1.filterAdverts)건")
            if s2.ranRaw {
                let singles = Set(s2.overflow.values.compactMap { $0.bits.count == 1 ? $0.bits[0] : nil }).sorted()
                var bitList = ""
                if !singles.isEmpty {
                    bitList = ": 비트 " + singles.prefix(8).map { String($0) }.joined(separator: ", ")
                        + (singles.count > 8 ? " ..." : "")
                }
                emit("2 직접 읽기 \(s2.seconds)초: 광고 \(s2.rawAdverts)건, Apple \(s2.appleAdverts)건, "
                     + "overflow 모양 \(s2.overflow.count)대 (비트 하나 \(singleBitCount(s2))대\(bitList)), "
                     + "UUID 목록에 신원 서비스 \(s2.rawListed.count)대")
            } else {
                emit("2 직접 읽기: 못 함 (두 번째 스캔 관리자가 켜지지 않았다)")
            }
            var l3 = "3 둘 다 \(s3.seconds)초: 필터 기기 \(s3.filter.count)대"
            l3 += s3.ranRaw ? ", overflow 모양 \(s3.overflow.count)대 (비트 하나 \(singleBitCount(s3))대)"
                            : ", 직접 읽기 못 함"
            emit(l3)
            if book.appleKeys.isEmpty {
                emit("Apple 광고 키: 없음 (Apple 광고를 하나도 못 받았다)")
            } else {
                // kCBAdvData 는 떼고 적는다 (줄이 짧아야 붙여 넣는다). 다른 접두사의 키는 그대로.
                let names = book.appleKeys.sorted().map {
                    $0.hasPrefix("kCBAdvData") ? String($0.dropFirst("kCBAdvData".count)) : $0
                }
                emit("Apple 광고 키: " + names.joined(separator: ", "))
            }
        } else {
            emit("1~3 단계: 건너뜀 (식별자를 주어 바로 붙었다)")
        }

        // 결과는 토큰을 준 후보가 어느 길로 왔는지로 정한다. 등록된 토큰이 있으면 그것과 같은 것을 먼저 본다.
        let mine = registered.isEmpty ? hits : hits.filter { $0.token == registered }
        let basis = mine.isEmpty ? hits : mine
        if let h = basis.first {
            var reg = ""
            if registered.isEmpty {
                reg = ", 등록된 토큰 없음 (비교 못 함)"
            } else {
                reg = h.token == registered ? ", 등록된 토큰과 같음" : ", 등록된 토큰과 다름"
            }
            let more = hits.count > 1 ? " 외 \(hits.count - 1)대" : ""
            emit("토큰: 읽음 \(hits.count)대 / 시도 \(tried)대 - \(BLEIds.shortId(h.id)) \(pathText(h.cand))\(reg)\(more)")
        } else if tried > 0 {
            emit("토큰: 못 읽음 - 시도 \(tried)대, 서비스 탐색 성공 \(discovered)대")
        } else {
            emit("토큰: 시도할 후보가 없음")
        }

        let byFilter = basis.contains { $0.cand.viaF != nil && !$0.cand.retrieved }
        let byRaw = basis.contains { $0.cand.bit >= 0 || $0.cand.rawList }
        if !scanned {
            emit("결과: 식별자를 주어 스캔을 건너뛰었습니다 - 어느 길인지는 가리지 않습니다.")
        } else if byFilter && byRaw {
            emit("결과: 둘 다 - 필터 경로와 직접 읽기 경로가 모두 잠긴 폰을 찾았습니다.")
        } else if byFilter {
            emit("결과: 필터 경로 - macOS 의 서비스 필터가 잠긴 폰을 찾아 줍니다 (직접 읽기로는 못 찾았습니다).")
        } else if byRaw {
            emit("결과: 직접 읽기 경로 - 필터로는 못 찾고, 제조사 데이터의 overflow 비트로 찾았습니다.")
        } else {
            emit("결과: 둘 다 안 됨 - 광고로는 잠긴 폰을 찾지 못했습니다. 남은 길은 GATT 경로뿐입니다:")
            emit("      SmartScreen 을 켜고 보호를 켠 뒤, 고급 창 아래 GATT 줄(linked / waiting / off)을 보세요.")
        }

        // 결과를 그대로 믿으면 안 되는 경우
        if basis.contains(where: { $0.cand.plain }) {
            emit("주의: 토큰을 준 폰이 서비스 UUID 를 그대로 광고했습니다 (앱이 화면에 떠 있었음).")
            emit("      잠긴 상태의 결과가 아닐 수 있습니다 - 폰을 잠그고 다시 실행하세요.")
        }
        if !registered.isEmpty && !hits.isEmpty && mine.isEmpty {
            emit("주의: 읽은 토큰이 등록된 토큰과 다릅니다 - 옆 사람의 폰이거나, 앱을 다시 설치한 것입니다.")
        }
        if scanned && !s1.filter.isEmpty && s3.ranFilter && s3.filter.isEmpty {
            emit("주의: 둘을 함께 돌리면 필터가 아무것도 주지 않았습니다 (1단계 \(s1.filter.count)대) - "
                 + "앱에서는 필터 경로가 끊길 수 있습니다.")
        }
        if scanned && singleBitCount(s2) > 0 && s3.ranRaw && singleBitCount(s3) == 0 {
            emit("주의: 둘을 함께 돌리면 직접 읽기에서 비트 하나짜리가 0대였습니다 (2단계 \(singleBitCount(s2))대) - "
                 + "앱에서는 직접 읽기 경로가 끊길 수 있습니다.")
        }
        emit("====================================")
    }

    /// [시도] 줄과 요약의 경로 글자: 필터 / 직접 읽기(비트 N) / 직접 읽기(UUID 목록), 둘 다면 " + ".
    private static func pathText(_ c: UnionCand) -> String {
        if c.retrieved { return "식별자로 직접" }
        var parts: [String] = []
        if c.viaF != nil { parts.append("필터") }
        if c.bit >= 0 {
            parts.append("직접 읽기(비트 \(c.bit))")
        } else if c.rawList {
            parts.append("직접 읽기(UUID 목록)")
        }
        return parts.joined(separator: " + ")
    }

    private static func bitsText(_ bits: [Int]) -> String {
        if bits.isEmpty { return "비트 없음" }
        let shown = bits.prefix(12).map { String($0) }.joined(separator: ", ")
        return "비트 " + shown + (bits.count > 12 ? " ... (\(bits.count)개)" : "")
    }

    private static func singleBitCount(_ st: PhaseStats) -> Int {
        return st.overflow.values.filter { $0.bits.count == 1 }.count
    }

    /// CoreBluetooth 문서에 있는 광고 키. 이 밖의 것은 macOS 가 몰래 붙이는 것이다.
    private static let publicAdvKeys: Set<String> = [
        CBAdvertisementDataLocalNameKey, CBAdvertisementDataManufacturerDataKey,
        CBAdvertisementDataServiceDataKey, CBAdvertisementDataServiceUUIDsKey,
        CBAdvertisementDataOverflowServiceUUIDsKey, CBAdvertisementDataTxPowerLevelKey,
        CBAdvertisementDataIsConnectable, CBAdvertisementDataSolicitedServiceUUIDsKey,
    ]

    /// 값 하나를 한 줄 160자 안으로 (NSData 는 "{length = 19, bytes = 0x4c00...}" 로 나온다).
    private static func shortDescription(_ v: Any) -> String {
        var s = String(describing: v)
        s = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.count > 160 ? String(s.prefix(160)) + "..." : s
    }

    /// 한 후보에 실제로 붙어서 서비스 목록을 받고, 우리 서비스가 있으면 토큰까지 읽는다.
    /// code: 0 = 실패, 1 = 서비스 탐색 성공, 2 = 토큰 읽음 (token 에 대문자 hex).
    /// d 는 p 를 준 관리자여야 한다 (CBPeripheral 은 그것을 준 관리자로만 연결할 수 있다).
    private static func probe(_ d: DiagCentral, _ p: CBPeripheral, _ c: UnionCand) -> (code: Int, token: String) {
        emit("\n-------------------------------------")
        var line = "[시도] 주소 \(BLEIds.shortId(p.identifier))  신호 \(c.rssi) dBm  경로 \(pathText(c))"
        if c.overflowKey { line += "  overflow UUID" }
        if c.plain { line += "  [광고에 서비스 UUID 노출]" }
        if !c.name.isEmpty { line += "  이름 \"\(c.name)\"" }
        emit(line)
        emit("  기기 ID: \(p.identifier.uuidString)")

        guard d.manager.state == .poweredOn else {
            emit("  서비스 탐색: Unreachable (연결 실패)")
            return (0, "")
        }
        d.begin(p)
        // CoreBluetooth 의 connect 는 스스로 끝나지 않는다 - 시간을 재서 끊는다
        d.manager.connect(p, options: nil)
        let settled = spin(10) { d.connected || d.connectFailed }
        if !d.connected {
            if !settled { emit("  연결 상태: Disconnected (10초 대기 후)") }
            emit("  서비스 탐색: \(statusText(d.connectError))")
            release(d, p)
            return (0, "")
        }
        emit("  연결 상태: Connected")

        p.discoverServices(nil)   // 전체 탐색
        if !spin(20, until: { d.servicesDone || d.disconnected }) {
            emit("  결과: 서비스 탐색 20초 초과 - 연결되지 않았습니다")
            release(d, p)
            return (0, "")
        }
        if !d.servicesDone {
            emit("  서비스 탐색: Unreachable (연결 실패)")
            release(d, p)
            return (0, "")
        }
        if let e = d.servicesError {
            emit("  서비스 탐색: \(statusText(e))")
            release(d, p)
            return (0, "")
        }
        emit("  서비스 탐색: Success")
        var result = (code: 1, token: "")
        let svcs = p.services ?? []
        emit("  서비스 \(svcs.count)개:")
        for s in svcs {
            let mine = s.uuid == BLEIds.identService
            emit("    \(BLEIds.braced(s.uuid))" + (mine ? "   <<< SmartScreen 신원 서비스" : ""))
            if mine, let tok = readToken(d, p, s) { result = (2, tok) }
        }
        release(d, p)
        return result
    }

    /// 신원 서비스에서 토큰 특성을 찾아 읽는다. 성공하면 토큰(대문자 hex), 아니면 nil.
    private static func readToken(_ d: DiagCentral, _ p: CBPeripheral, _ s: CBService) -> String? {
        d.charsDone = false
        d.charsError = nil
        p.discoverCharacteristics(nil, for: s)
        if !spin(10, until: { d.charsDone || d.disconnected }) {
            emit("      특성 탐색 시간 초과")
            return nil
        }
        if !d.charsDone {
            emit("      특성 탐색: Unreachable (연결 실패)")
            return nil
        }
        if let e = d.charsError {
            emit("      특성 탐색: \(statusText(e))")
            return nil
        }
        emit("      특성 탐색: Success")
        for ch in s.characteristics ?? [] {
            if ch.uuid != BLEIds.identToken {
                emit("      특성 \(BLEIds.braced(ch.uuid))")
                continue
            }
            d.readDone = false
            d.readError = nil
            p.readValue(for: ch)
            if !spin(10, until: { d.readDone || d.disconnected }) {
                emit("      토큰 읽기 시간 초과")
                return nil
            }
            if !d.readDone {
                emit("      토큰 읽기: Unreachable (연결 실패)")
                return nil
            }
            if let e = d.readError {
                emit("      토큰 읽기: \(statusText(e))")
                return nil
            }
            let v = ch.value ?? Data()
            let hex = Hex.upper(v)
            emit("      >>> 토큰 \(hex) (\(v.count)바이트)")
            return hex
        }
        emit("      토큰 특성이 없습니다")
        return nil
    }

    /// 연결을 붙잡고 있으면 폰이 광고를 멈출 수 있으니 반드시 놓아준다.
    /// 해제가 끝나기 전에 다음 기기로 넘어가면 같은 증상(전부 Unreachable)이 난다 - 1.5초 쉰다.
    private static func release(_ d: DiagCentral, _ p: CBPeripheral) {
        if d.manager.state == .poweredOn {
            d.manager.cancelPeripheralConnection(p)
        }
        p.delegate = nil
        d.target = nil
        _ = spin(1.5) { false }
    }

    private static func matchesFilter(_ id: UUID, _ only: String) -> Bool {
        return id.uuidString == only || BLEIds.shortId(id) == only
    }

    // MARK: - --adv-scan

    /// --adv-scan [sec]
    /// 다른 PC 에서 실행해서, SmartScreen 이 돌고 있는 PC(또는 Mac)의 BLE 광고가 실제로 잡히는지 본다.
    /// "PC 는 광고 중이라는데 폰이 못 찾는다" 상황에서 PC 쪽 문제인지 폰 쪽 문제인지 가른다.
    static func advScan(args: [String]) -> Int32 {
        let ops = operands(args, flag: "--adv-scan")
        let seconds = max(ops.count > 0 ? ConfigStore.wtoi(ops[0]) : 30, 0)

        emit("SmartScreen 광고 수신 확인")
        emit("=====================================")
        emit("찾는 서비스: {\(BLEIds.pcService.uuidString)}")
        emitTerminalPermissionHint()
        emit("\(seconds)초 동안 주변 BLE 광고를 듣습니다...\n")
        emit("다른 PC에서 SmartScreen 을 실행하고 \"시작\" 을 누른 상태여야 합니다.\n")

        var total = 0
        var hits = 0
        var seen = Set<UUID>()
        var code: Int32 = 0
        let d = DiagCentral()
        if waitPoweredOn(d) {
            d.onDiscover = { p, adv, rssi in
                total += 1
                let uuids = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
                if !uuids.contains(BLEIds.pcService) { return }
                if !seen.insert(p.identifier).inserted { return }   // 기기별 1회만 출력
                hits += 1
                BLEDiagnostics.emit("[발견] \(LocalClock.hhmmss())  주소 \(BLEIds.shortId(p.identifier))  신호 \(rssi) dBm")
            }
            // 주변 광고 전체를 센다 (필터 없음) - "주변은 들리는데 SmartScreen 만 안 보인다" 를 가르려고
            d.manager.scanForPeripherals(withServices: nil,
                                         options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            _ = spin(Double(seconds)) { false }
            d.manager.stopScan()
            d.onDiscover = nil
        } else {
            emitCentralFailure(d)
            code = 1
        }

        emit("\n-------------------------------------")
        emit("주변 광고 \(total)건 수신, 그중 SmartScreen \(hits)대 발견")
        if hits > 0 {
            emit("\n결과: PC 광고는 정상입니다.")
            emit("      폰이 못 찾는다면 아이폰 쪽 문제입니다.")
        } else if total > 0 {
            emit("\n결과: 주변 BLE 는 잘 들리는데 SmartScreen 광고만 안 보입니다.")
            emit("      그 PC 가 실제로는 광고를 못 내보내고 있습니다.")
        } else {
            emit("\n결과: 주변 BLE 광고가 하나도 안 잡힙니다.")
            emit("      이 PC 의 블루투스를 확인하세요.")
        }
        emit("-------------------------------------")
        return code
    }

    // MARK: - --bt-check

    /// --bt-check
    /// 이 Mac 에서 "빠른 모드"(Mac 이 BLE 주변장치가 되어 컴패니언 앱과 연결)를 쓸 수 있는지 확인한다.
    /// 결과를 설정 폴더의 BtCheck_result.txt 로도 남긴다 (UTF-8 BOM). Windows 는 exe 옆에 쓰지만
    /// .app 묶음 안에 쓰면 서명이 깨진다.
    static func btCheck(args: [String]) -> Int32 {
        var text = ""
        func out(_ s: String) {
            emit(s)
            text += s + "\n"
        }

        out("SmartScreen 블루투스 어댑터 점검")
        out("=====================================\n")
        emitTerminalPermissionHint()

        let c = DiagCentral()
        let p = DiagPeripheral()
        _ = spin(10) { c.stateKnown && p.stateKnown }
        let cs = c.manager.state
        let ps = p.manager.state
        let denied = BLEIds.authorizationDenied || cs == .unauthorized || ps == .unauthorized

        var found = false
        var le = false
        var peripheral = false
        var powered = false
        if denied {
            out("[실패] \(permissionText)")
        } else if !c.stateKnown {
            out("[실패] 블루투스 어댑터를 찾을 수 없습니다.")
            out("       블루투스가 꺼져 있거나 어댑터가 없는 PC입니다.")
        } else {
            found = true
            le = cs != .unsupported
            // 주변장치 관리자가 unsupported 가 아니면 역할을 지원한다 (꺼져 있어도 지원 여부는 안다)
            peripheral = le && p.stateKnown && ps != .unsupported
            powered = cs == .poweredOn
            out("  저전력 블루투스(BLE) 지원 : \(yesNo(le))")
            out("  주변장치 역할 지원        : \(yesNo(peripheral))")
            out("  중앙장치 역할 지원        : \(yesNo(le))")
            out("  클래식 블루투스 지원      : 예")   // Mac 은 모두 지원한다
        }

        out("\n-------------------------------------")
        if denied {
            out("결과: 블루투스 권한을 켠 뒤 다시 실행해 주세요.")
        } else if found && le && !powered {
            out("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        } else if found && le && peripheral {
            out("결과: 빠른 모드를 쓸 수 있습니다.\n")
            out("아이폰에 컴패니언 앱(SSBeacon)을 설치하면")
            out("자리를 뜬 뒤 10~15초 안에 화면이 잠깁니다.\n")
            // 드라이버가 "예" 라고 해도 실제로 전파를 못 내보내는 어댑터가 있었다 -
            // 바깥에서 보는 것(폰의 연결 표시, 다른 PC 의 AdvScan)만이 확정이다.
            out("[주의] 이 값은 드라이버가 보고하는 것이라 실제와 다를 수 있습니다.")
            out("       일부 USB 동글은 \"예\" 라고 답하면서도 전파를 못 내보냅니다.")
            out("       SmartScreen 을 실행해 폰 앱이 연결되는지로 확인하세요.")
            out("       또는 다른 PC 에서 AdvScan.exe 를 돌려 송출을 확인하세요.")
        } else if found && le {
            out("결과: 빠른 모드를 쓸 수 없습니다. (주변장치 역할 미지원)\n")
            out("느린 모드로는 동작합니다. 다만 아이폰은 잠금 상태에서")
            out("신호를 거의 안 보내므로 감지가 느리거나 끊깁니다.")
            out("블루투스 5.0 이상 USB 동글을 쓰면 빠른 모드가 될 수 있습니다.")
        } else if found {
            out("결과: 이 어댑터로는 SmartScreen을 쓸 수 없습니다. (BLE 미지원)")
        } else {
            out("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        }
        out("-------------------------------------")

        let url = Paths.configDir.appendingPathComponent("BtCheck_result.txt")
        out("\n이 내용은 BtCheck_result.txt 파일로도 저장했습니다.")
        out("(\(url.path))")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try? data.write(to: url)
        return 0
    }

    // MARK: - 공통

    /// 이 명령을 실행한 터미널 앱의 이름. macOS 는 블루투스 권한을 그 앱에 묻고 그 이름으로 보인다.
    private static var terminalAppName: String {
        switch ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "" {
        case "", "Apple_Terminal": return "터미널"
        case "iTerm.app": return "iTerm"
        case "vscode": return "Visual Studio Code"
        case "WarpTerminal": return "Warp"
        case let other: return other
        }
    }

    /// 권한이 없을 때. 앱의 문구("SmartScreen 을 켜 주세요")와 다르다 - 여기서 켤 것은 터미널 앱이다.
    private static var permissionText: String {
        return "블루투스 권한이 없어요. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 "
            + "\"\(terminalAppName)\" (이 명령을 실행한 앱) 을 켠 뒤 다시 실행하세요."
    }

    private static func emitTerminalPermissionHint() {
        emit("※ 블루투스 허용 창이 \"\(terminalAppName)\" 이름으로 뜰 수 있습니다. [허용] 을 누르세요.")
        emit("  (터미널에서 실행하면 macOS 는 블루투스 권한을 SmartScreen 이 아니라 그 앱에 묻습니다)")
    }

    private static func yesNo(_ b: Bool) -> String {
        return b ? "예" : "아니오"
    }

    /// 출력하고 바로 내보낸다 (파이프로 받을 때도 진행이 보이게).
    private static func emit(_ s: String) {
        print(s)
        fflush(stdout)
    }

    /// 플래그 뒤의 인자만 남긴다. main 이 전체 인자를 넘기든 플래그 뒤만 넘기든 같게 읽는다.
    /// "-" 로 시작하는 것(-psn_..., -NS...)은 버린다.
    private static func operands(_ args: [String], flag: String) -> [String] {
        var a = args
        if let i = a.firstIndex(of: flag) {
            a = Array(a[(i + 1)...])
        }
        return a.filter { !$0.hasPrefix("-") }
    }

    /// 메인 런루프를 돌리며 done() 이 참이 되기를 기다린다. 시간 안에 참이 되면 true.
    /// CoreBluetooth 콜백(메인 큐)은 런루프가 도는 동안 처리된다.
    @discardableResult
    private static func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
        // 런루프에 입력원이 하나도 없으면 run 이 곧바로 돌아와 헛돈다 - 타이머 하나를 걸어 둔다
        let keepAlive = Timer(timeInterval: 0.1, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .default)
        defer { keepAlive.invalidate() }
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            let now = Date()
            if now >= deadline { return false }
            let next = min(deadline, now.addingTimeInterval(0.1))
            if !RunLoop.main.run(mode: .default, before: next) {
                usleep(10_000)
            }
        }
        return true
    }

    private static func waitPoweredOn(_ d: DiagCentral) -> Bool {
        _ = spin(10) { d.stateKnown }
        if !d.stateKnown && CBManager.authorization == .notDetermined {
            // 허용 창이 떠서 답을 기다리는 중이다. 처음 보는 창이라 읽고 누를 시간을 더 준다.
            emit("블루투스 허용 창이 떴으면 [허용] 을 누르세요. 기다립니다...")
            _ = spin(50) { d.stateKnown }
        }
        return d.manager.state == .poweredOn
    }

    /// 블루투스를 쓸 수 없을 때의 안내 (Windows 의 "[실패] BLE 오류 0x..." 자리).
    private static func emitCentralFailure(_ d: DiagCentral) {
        let st = d.manager.state
        if BLEIds.authorizationDenied || st == .unauthorized {
            emit("[실패] \(permissionText)")
        } else if st == .unsupported || !d.stateKnown {
            emit("[실패] 블루투스 어댑터를 찾을 수 없습니다.")
            emit("       블루투스가 꺼져 있거나 어댑터가 없는 PC입니다.")
        } else {
            emit("결과: 블루투스를 켠 뒤 다시 실행해 주세요.")
        }
    }

    /// 도구용 상태 글자 (Windows ProbeScan 의 StatusText).
    private static func statusText(_ e: Error?) -> String {
        guard let e = e else { return "Unreachable (연결 실패)" }
        switch BLEIds.classify(e) {
        case .unreachable: return "Unreachable (연결 실패)"
        case .protocolError: return "ProtocolError"
        case .accessDenied: return "AccessDenied (페어링 요구)"
        case .other: return "?"
        }
    }
}

// MARK: - --probe-scan 의 기록

/// 두 스캔에서 본 후보 하나 (기기 식별자로 합친 것). 같은 기기를 두 관리자가 다 보면 객체가 둘이다.
private struct UnionCand {
    var viaF: CBPeripheral?      // 필터 스캔 관리자가 준 객체
    var viaR: CBPeripheral?      // 직접 읽기 관리자가 준 객체
    var retrieved = false        // 식별자로 바로 가져왔다 (스캔 없음)
    var rssi = -127              // 본 것 중 가장 센 값
    var plain = false            // 일반 서비스 목록에 신원 UUID (앱이 화면에 떠 있음)
    var overflowKey = false      // overflow UUID 목록에 신원 UUID
    var rawList = false          // 직접 읽기 광고의 UUID 목록에서 봤다
    var bit = -1                 // 직접 읽기가 읽은 하나짜리 overflow 비트
    var name = ""

    /// 신원 UUID 를 직접 봤다 (앱의 sure 와 같은 뜻) - 먼저 시도한다
    var sure: Bool { return viaF != nil || rawList }
}

private struct FilterSeen {
    var rssi = -127
    var plain = false
    var overflow = false
}

private struct OverflowSeen {
    var rssi = -127
    var bits: [Int] = []
}

/// 한 단계의 숫자. 콜백 클로저가 고치므로 클래스다.
private final class PhaseStats {
    let seconds: Int
    var ranFilter = false
    var ranRaw = false
    var filterAdverts = 0
    var filter: [UUID: FilterSeen] = [:]      // 필터가 준 기기
    var rawAdverts = 0
    var appleAdverts = 0
    var overflow: [UUID: OverflowSeen] = [:]  // 제조사 데이터가 overflow 모양인 기기
    var rawListed = Set<UUID>()               // 거르지 않은 광고의 UUID 목록에 신원 UUID 가 있던 기기

    init(seconds: Int) {
        self.seconds = seconds
    }
}

/// 세 단계를 통틀어 모은 것.
private final class ProbeBook {
    let only: String
    var cands: [UUID: UnionCand] = [:]
    var appleKeys = Set<String>()            // Apple 광고에서 본 광고 키 이름
    var overflowKeys = Set<String>()         // 그중 overflow 모양 광고에 실린 키
    var privateSamples: [String: String] = [:]   // 공개되지 않은 키 -> 값의 예

    init(only: String) {
        self.only = only
    }
}

private struct TokenHit {
    let cand: UnionCand
    let id: UUID
    let token: String
}

// MARK: - 진단 도구 전용 CoreBluetooth 대리자 (메인 큐)

/// 사건을 깃발로만 남긴다. 순서대로 쓰인 도구 코드가 spin 으로 깃발을 기다린다.
private final class DiagCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var onDiscover: ((CBPeripheral, [String: Any], Int) -> Void)?
    var target: UUID?
    var connected = false
    var connectFailed = false
    var connectError: Error?
    var disconnected = false
    var servicesDone = false
    var servicesError: Error?
    var charsDone = false
    var charsError: Error?
    var readDone = false
    var readError: Error?

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil, options: nil)
    }

    var stateKnown: Bool {
        let s = manager.state
        return s != .unknown && s != .resetting
    }

    func begin(_ p: CBPeripheral) {
        target = p.identifier
        connected = false
        connectFailed = false
        connectError = nil
        disconnected = false
        servicesDone = false
        servicesError = nil
        charsDone = false
        charsError = nil
        readDone = false
        readError = nil
        p.delegate = self
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        onDiscover?(peripheral, advertisementData, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier == target { connected = true }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral.identifier == target {
            connectFailed = true
            connectError = error
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral.identifier == target && connected { disconnected = true }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == target else { return }
        servicesDone = true
        servicesError = error
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard peripheral.identifier == target else { return }
        charsDone = true
        charsError = error
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral.identifier == target else { return }
        readDone = true
        readError = error
    }
}

private final class DiagPeripheral: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil, options: nil)
    }

    var stateKnown: Bool {
        let s = manager.state
        return s != .unknown && s != .resetting
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {}
}
