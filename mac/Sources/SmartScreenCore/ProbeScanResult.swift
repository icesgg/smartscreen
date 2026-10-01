import Foundation

/// --probe-scan 요약의 "결과:" 줄 (BLEDiagnostics.emitSummary). CoreBluetooth 없이 정하고 시험한다.
///
/// 이 줄 하나로 다음 세션이 Mac 앱의 어느 스캔을 살릴지 정한다. 그래서 확인한 것만 말한다:
///  - 길(필터 / 직접 읽기)은 **토큰을 준 후보**가 어느 스캔에서 왔는지로 정한다. 등록된 토큰이 있으면
///    그것과 같은 토큰만 "내 폰" 으로 친다 - 다른 토큰만 읽었으면 내 폰을 찾았다는 증거가 아니다.
///  - 스캔이 폰을 봤는데 토큰을 못 읽었으면 (연결이 실패하는 것은 흔하다 - 이 Mac 이 직전 연결을
///    아직 물고 있을 때 Unreachable) "판정 못 함" 이다. 첫 판은 이것을 "둘 다 안 됨 - 남은 길은 GATT
///    뿐" 이라고 말해서, 다시 실행하면 될 일을 광고 경로가 죽었다는 결론으로 바꿨다.
///  - "둘 다 안 됨" 은 어느 스캔도 후보를 하나도 못 냈고 두 스캔을 다 돌렸을 때만이다.
public enum ProbeScanResult {

    /// 후보 하나에 붙어 본 결과.
    public enum Attempt: Equatable {
        case notTried         // 시도 상한(6대)에 걸려 붙어 보지 않았다
        case unreachable      // 붙지 못했다, 또는 서비스 탐색이 실패했다
        case noIdentService   // 서비스 목록은 받았는데 신원 서비스가 없다
        case noToken          // 신원 서비스는 있는데 토큰을 못 읽었다
        case token(String)    // 토큰을 읽었다 (대문자 hex)
    }

    /// 판정에 쓰는 후보의 모양.
    public struct Candidate: Equatable {
        /// 필터 스캔이 줬다 (식별자로 바로 가져온 것은 빼고). 필터는 신원 서비스를 광고한 기기만
        /// 주므로 강한 증거다.
        public var byFilter: Bool
        /// 거르지 않은 스캔의 광고 UUID 목록에 신원 UUID 가 있었다 (강한 증거)
        public var rawList: Bool
        /// 거르지 않은 스캔이 읽은 하나짜리 overflow 비트 (-1 = 없음). 약한 증거 - 다른 iOS 앱의
        /// overflow UUID 도 비트 하나를 켠다
        public var bit: Int
        public var attempt: Attempt

        public init(byFilter: Bool, rawList: Bool, bit: Int, attempt: Attempt) {
            self.byFilter = byFilter
            self.rawList = rawList
            self.bit = bit
            self.attempt = attempt
        }

        var strong: Bool { return byFilter || rawList }
        var byRaw: Bool { return bit >= 0 || rawList }
        var hasPath: Bool { return byFilter || byRaw }

        var token: String? {
            if case .token(let t) = attempt { return t }
            return nil
        }
    }

    /// 강한 후보(필터 / UUID 목록)에서 토큰을 못 읽은 까닭. 가장 멀리 간 것을 말한다.
    public enum NoTokenReason: Equatable {
        case noToken          // 신원 서비스까지 봤는데 토큰 읽기가 실패했다
        case noIdentService   // 붙어서 서비스 목록을 받았는데 신원 서비스가 없다
        case unreachable      // 붙지 못했다
        case notTried         // 붙어 보지 못했다 (시도 상한)
    }

    public enum Verdict: Equatable {
        case notScanned                                    // 식별자를 주어 스캔을 건너뛰었다
        case both                                          // 내 폰의 토큰: 필터와 직접 읽기가 모두 줬다
        case filter                                        // 내 폰의 토큰: 필터만
        case raw(bitLearned: Bool)                         // 내 폰의 토큰: 직접 읽기만 (비트로 / UUID 목록으로)
        case otherTokens(filter: Bool, raw: Bool)          // 판정 못 함: 등록된 것과 다른 토큰만 읽었다
        case seenNoToken(filter: Bool, list: Bool, reason: NoTokenReason)   // 판정 못 함: 봤지만 토큰 없음
        case bitOnlyNoToken                                // 판정 못 함: 비트 하나짜리만 있었고 토큰 없음
        case nothingRawUntested                            // 필터는 아무것도 못 찾고 직접 읽기는 못 돌렸다
        case none                                          // 둘 다 안 됨: 어느 스캔도 후보를 못 냈다
    }

    /// - Parameters:
    ///   - scanned: 세 단계 스캔을 돌렸다 (식별자를 주면 건너뛴다)
    ///   - rawTested: 거르지 않은 스캔을 한 번이라도 돌렸다 (2단계 또는 3단계)
    ///   - registered: config.ini 의 phoneToken (빈 문자열 = 등록 안 됨, 비교하지 않는다)
    ///   - candidates: 스캔이 낸 모든 후보 (시도하지 않은 것 포함)
    public static func decide(scanned: Bool, rawTested: Bool, registered: String,
                              candidates: [Candidate]) -> Verdict {
        if !scanned { return .notScanned }
        // 스캔을 돌렸으면 모든 후보가 어느 한 스캔에서 왔다. 길이 없는 후보는 식별자로 가져온 것뿐이다.
        let cands = candidates.filter { $0.hasPath }
        let hits = cands.filter { $0.token != nil }
        let reg = registered.uppercased()
        let mine = reg.isEmpty ? hits : hits.filter { $0.token?.uppercased() == reg }

        if !mine.isEmpty {
            let f = mine.contains { $0.byFilter }
            let r = mine.contains { $0.byRaw }
            if f && r { return .both }
            if f { return .filter }
            return .raw(bitLearned: mine.contains { $0.bit >= 0 })
        }
        if !hits.isEmpty {
            return .otherTokens(filter: hits.contains { $0.byFilter }, raw: hits.contains { $0.byRaw })
        }

        let seenF = cands.contains { $0.byFilter }
        let seenList = cands.contains { $0.rawList }
        if seenF || seenList {
            let strong = cands.filter { $0.strong }.map { $0.attempt }
            let reason: NoTokenReason
            if strong.contains(.noToken) {
                reason = .noToken
            } else if strong.contains(.noIdentService) {
                reason = .noIdentService
            } else if strong.contains(.unreachable) {
                reason = .unreachable
            } else {
                reason = .notTried
            }
            return .seenNoToken(filter: seenF, list: seenList, reason: reason)
        }
        if cands.contains(where: { $0.bit >= 0 }) { return .bitOnlyNoToken }
        return rawTested ? .none : .nothingRawUntested
    }

    /// 요약에 찍을 줄들. 첫 줄이 "결과: ..." 이고 나머지는 6칸 들여 쓴 설명이다.
    /// - Parameters:
    ///   - rawTested: decide 에 준 것과 같은 값
    ///   - skipped: 시도 상한에 걸려 붙어 보지 않은 후보 수
    ///   - maxProbes: 그 상한
    public static func lines(_ v: Verdict, rawTested: Bool, skipped: Int, maxProbes: Int) -> [String] {
        var out: [String] = []
        var undecided = false
        switch v {
        case .notScanned:
            out.append("결과: 식별자를 주어 스캔을 건너뛰었습니다 - 어느 길인지는 가리지 않습니다.")
        case .both:
            out.append("결과: 둘 다 - 필터 경로와 직접 읽기 경로가 모두 잠긴 폰을 찾았습니다.")
        case .filter:
            out.append("결과: 필터 경로 - macOS 의 서비스 필터가 잠긴 폰을 찾아 줍니다 "
                       + (rawTested ? "(직접 읽기로는 못 찾았습니다)."
                                    : "(직접 읽기는 시험하지 못했습니다 - 다시 실행해 보세요)."))
        case .raw(let bitLearned):
            out.append(bitLearned
                       ? "결과: 직접 읽기 경로 - 필터로는 못 찾고, 제조사 데이터의 overflow 비트로 찾았습니다."
                       : "결과: 직접 읽기 경로 - 필터로는 못 찾고, 거르지 않은 스캔의 UUID 목록으로 찾았습니다 (비트는 배우지 않음).")
        case .otherTokens(let f, let r):
            undecided = true
            let via = f && r ? "필터와 직접 읽기" : (f ? "필터" : "직접 읽기")
            out.append("결과: 판정 못 함 - 읽은 토큰이 모두 등록된 토큰과 다릅니다 (그 폰은 \(via)로 찾았습니다).")
            out.append("      앱을 지웠다 다시 설치했으면 [등록하기] 를 다시 한 뒤, 아니면 옆 사람의 폰이니 "
                       + "내 폰을 잠가 둔 채 다시 실행하세요.")
        case .seenNoToken(let f, let list, let reason):
            undecided = true
            let which = f && list ? "필터, UUID 목록" : (f ? "필터" : "UUID 목록")
            out.append("결과: 판정 못 함 - 광고로 폰을 찾았지만 (\(which)) 토큰을 못 읽었습니다.")
            switch reason {
            case .noToken:
                out.append("      신원 서비스까지 봤는데 토큰 읽기가 실패 - 1~2분 뒤 다시 실행하세요.")
            case .noIdentService:
                out.append("      연결은 됨, 신원 서비스 없음 - 폰 앱 버전을 확인하세요 "
                           + "(앱을 지웠다 다시 설치한 뒤 한 번 실행해야 반영됩니다).")
            case .unreachable:
                out.append("      연결 실패 - 1~2분 뒤 다시 실행하세요 "
                           + "(이 Mac 이 직전 연결을 아직 물고 있는 경우가 많습니다).")
            case .notTried:
                out.append("      붙어 보지 못했습니다 - 다시 실행하세요.")
            }
        case .bitOnlyNoToken:
            undecided = true
            out.append("결과: 판정 못 함 - 비트 하나짜리 기기는 있었지만 SmartScreen 폰인지 토큰으로 "
                       + "확인하지 못했습니다 - 다시 실행하세요.")
        case .nothingRawUntested:
            out.append("결과: 필터로는 못 찾음, 직접 읽기는 시험하지 못함 - 다시 실행해 보세요.")
        case .none:
            out.append("결과: 둘 다 안 됨 - 광고로는 잠긴 폰을 찾지 못했습니다. 남은 길은 GATT 경로뿐입니다:")
            out.append("      SmartScreen 을 켜고 보호를 켠 뒤, 고급 창 아래 GATT 줄(linked / waiting / off)을 보세요.")
            out.append("      (그 전에 폰 앱의 \"광고\" 원이 초록색인지 - 광고 중인지 - 확인하세요)")
        }
        if undecided {
            if skipped > 0 {
                out.append("      후보 \(skipped)대는 \(maxProbes)대 상한에 걸려 붙어 보지 못했습니다 "
                           + "(폰을 이 Mac 가까이 두면 앞쪽에 옵니다).")
            }
            if !rawTested {
                out.append("      직접 읽기는 시험하지 못했습니다 (두 번째 스캔 관리자가 켜지지 않았다).")
            }
            out.append("      이 결과로 어느 길인지 결론 내지 마세요.")
        }
        return out
    }
}
