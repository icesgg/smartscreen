import Foundation

// "내 자리에 맞게 재보기" 마법사의 판정과 글 (Windows client/main.cpp WzJudge, 마법사 WM_PAINT).
//
// 같은 "보통" 도 책상과 어댑터에 따라 10~20 dB 달라져서, 재보지 않으면 3단계는 그냥 임의의
// 숫자다. 재는 김에 어댑터도 본다. 값싼 동글 중에 신호 세기를 제대로 내주지 않는 것이
// 있는데, 드라이버는 멀쩡하다고 보고하므로 (docs/PROXIMITY.md 의 어댑터 표: BARROT 두 종이
// 지원한다고 보고하고 동작하지 않았다) 실제로 재 보는 것 말고는 확인할 방법이 없다.
//
// 폰을 들고 나가게 하면 2·3단계 안내를 읽을 사람이 화면 앞에 없다. 그래서 폰만 두고
// 돌아오게 하고, 다 왔는지는 버튼으로 받는다 - 걸어갔다 오는 시간을 초로 못박으면 자리가
// 먼 사람에게는 모자라고 가까운 사람은 기다리기만 한다.
//
// 신호는 두 갈래를 따로 잰다. 광고 신호(폰의 광고를 이 컴퓨터가 잰 세기)와 연결 신호(폰이
// GATT 연결의 세기를 재서 보내 주는 값). 1.1.6 부터 두 경로가 한 임계값을 썼는데, Windows
// 노트북에서는 둘이 2 dB 안이었지만 M1 맥북에서는 연결이 광고보다 12~15 dB 낮았다. 연결로 잰
// 기준은 폰이 다른 PC 에 붙어 이 컴퓨터가 광고로 판단하는 동안 맞지 않는다 (자리를 비워도
// 광고 세기가 그 위에 머문다 - 화면이 꺼지지 않았다). 사용자가 보는 숫자는 하나로 두고, 그
// 숫자는 광고 신호로 정하며, 연결 신호는 그 숫자와의 차이(gattRssiOffset)만 정한다.
//
// 글은 Windows 와 한 글자도 다르지 않아야 한다 (두 칸 띄어쓰기 포함). 그래서 문자열을
// 이어 붙이지 않고 한 덩어리로 둔다.

/// 연결 신호를 어떻게 했는가. 광고 판정이 ok 일 때만 정해진다.
public enum WizardGattOutcome: Equatable {
    /// 재서 썼다: gattRssiOffset = (연결 착석 최저값 - 2) - 광고 기준, [-40, 40] 으로 자른 값
    case measured
    /// 표본이 모자랐다 (폰 앱이 이 컴퓨터에 연결돼 있지 않았다). 지금의 차이를 그대로 둔다.
    case notMeasured
    /// 연결 신호의 착석과 비움이 겹쳤다. 지금의 차이를 그대로 둔다.
    case overlap
}

/// 판정 결과. ok 이면 base 를 measuredBaseRssi 로, gattOffset 을 gattRssiOffset 으로 저장하고
/// 거리를 "보통"(1) 으로 맞춘다.
public struct WizardVerdict {
    public let ok: Bool
    /// ok 일 때만 뜻이 있다 (광고 신호의 앉아 있을 때 최저값 - 2). ok 가 아니면 0.
    public let base: Int
    /// ok 일 때만 뜻이 있다: 저장할 gattRssiOffset. 연결 신호를 못 쟀거나 겹쳤으면 넘겨받은
    /// 지금 값 그대로. ok 가 아니면 0.
    public let gattOffset: Int
    /// ok 일 때만. 광고가 실패하면 연결 신호는 보지 않으므로 nil.
    public let gatt: WizardGattOutcome?
    public let title: String
    public let body: String
    /// events.log 에 남길 한 줄 ("재보기: ...")
    public let logLine: String

    public init(ok: Bool, base: Int, gattOffset: Int, gatt: WizardGattOutcome?,
                title: String, body: String, logLine: String) {
        self.ok = ok; self.base = base; self.gattOffset = gattOffset; self.gatt = gatt
        self.title = title; self.body = body; self.logLine = logLine
    }
}

public enum WizardJudge {
    /// 앉아 있는 단계 / 비운 단계 길이 (초). 2단계(폰 두고 오기)는 버튼으로 끝난다.
    public static let seatedSec = 60, awaySec = 45

    /// 판정에 필요한 표본 수 (앉아 있을 때 / 비웠을 때). 광고와 연결에 같은 수를 쓴다.
    public static let minSeated = 15, minAway = 8

    /// 단계 0...3 의 제목 (4 단계는 판정 결과의 제목). 번호 뒤는 두 칸.
    public static let phaseTitles: [String] = [
        "내 자리에 맞게 재보기",
        "1/3  자리에 앉아 계세요",
        "2/3  폰을 두고 오세요",
        "3/3  거의 다 됐어요",
    ]

    /// 단계 0...3 의 본문. 번호 매긴 줄도 "1." 뒤 두 칸.
    public static let phaseBodies: [String] = [
        "2분쯤 걸려요. 순서는 이렇습니다.\n\n1.  폰을 평소 두는 자리에 두고 1분 동안 앉아 있기\n2.  폰만 \"화면이 꺼지길 원하는 곳\" 에 두고 오기\n3.  자리에 앉아서 45초 기다리기",
        "폰은 평소 두는 자리에 그대로 두세요.\n컴퓨터는 건드리지 않아도 돼요.",
        "화면이 꺼지길 원하는 곳에 폰을 두고,\n자리로 돌아와서 아래 버튼을 눌러 주세요.\n\n폰은 가져오지 마세요. 재는 동안 거기 있어야 해요.",
        "그대로 기다려 주세요.\n폰을 가지러 가지 마세요.",
    ]

    /// 1·3 단계의 "남은 시간 · 받은 수" 줄. 세 칸씩 띄운 가운뎃점. 받은 수는 이번 단계에서
    /// 광고와 연결 각각.
    public static func liveLine(left: Int, adv: Int, gatt: Int) -> String {
        return "\(left)초 남음   ·   광고 \(adv)번   ·   연결 \(gatt)번"
    }

    /// WzCollect 의 표식 거르기: -100 이하(끊김/없음)와 0 이상(값 없음)은 측정값이 아니다.
    public static func isSample(_ rssi: Int) -> Bool {
        return rssi > -100 && rssi < 0
    }

    /// C 의 %+d: 0 과 양수 앞에 + 를 붙인다 (-15, +0, +3).
    public static func signed(_ v: Int) -> String {
        return v < 0 ? "\(v)" : "+\(v)"
    }

    /// WzJudge. 광고 신호의 순서가 중요하다: 표본 부족 → 어댑터 → 겹침 → 완료. 광고가 어디서든
    /// 실패하면 마법사 전체가 실패하고 (글과 로그는 연결 신호를 재기 전과 같다) 연결 신호는 보지
    /// 않는다. 광고가 되면 연결 신호로 차이를 정한다: 착석 15개·비움 8개 이상이고 겹치지 않으면
    /// 잰 차이, 아니면 currentGattOffset 그대로. 연결 신호에는 어댑터 검사가 없다 - 폰이 잰 값이다.
    public static func judge(seated: [Int], away: [Int],
                             gattSeated: [Int], gattAway: [Int],
                             currentGattOffset: Int) -> WizardVerdict {
        let (sLo, sHi) = range(seated)
        let (aLo, aHi) = range(away)
        let sn = seated.count
        let an = away.count

        if sn < minSeated || an < minAway {
            let body = "앉아 있을 때 \(sn)번, 비웠을 때 \(an)번밖에 못 받았어요.\n\n폰에서 SSBeacon 앱이 켜져 있는지, 그리고 이 컴퓨터의 블루투스가 켜져 있는지 확인해 주세요."
            return WizardVerdict(ok: false, base: 0, gattOffset: 0, gatt: nil,
                                 title: "신호를 거의 못 받았어요",
                                 body: body,
                                 logLine: "재보기: 표본 부족 (착석 \(sn), 비움 \(an))")
        }

        // 값이 전혀 흔들리지 않으면 재고 있는 게 아니다. 진짜 무선 신호는 아무도
        // 움직이지 않아도 1분이면 몇 dB 는 흔들린다.
        if (sHi - sLo) <= 1 {
            let body = "1분 동안 \(sn)번을 받았는데 값이 \(sLo) dBm 에서 거의 움직이지 않았어요.\n\n진짜로 재는 장치라면 가만히 있어도 값이 몇 칸은 흔들립니다. 이 장치는 신호 세기를 흉내만 내고 있어서 거리로 쓸 수 없어요.\n\n다른 블루투스 동글로 바꾸는 게 좋습니다."
            return WizardVerdict(ok: false, base: 0, gattOffset: 0, gatt: nil,
                                 title: "이 블루투스 장치는 세기를 못 재요",
                                 body: body,
                                 logLine: "재보기: 어댑터가 세기를 안 낸다 (착석 \(sn)개, \(sLo)..\(sHi) dBm)")
        }

        // 앉았을 때와 비웠을 때가 안 갈리면, 이 자리에서는 신호만으로 판단할 수 없다.
        // 사용자가 고칠 수 있는 유일한 경우라, 이것만 폰을 옮기라고 한다.
        if sLo - 2 <= aHi {
            let body = "앉아 있을 때 \(sLo)~\(sHi), 비웠을 때 \(aLo)~\(aHi) 로 겹칩니다.\n\n폰을 둔 곳이 책상과 너무 가까웠어요. 더 멀리 두고 다시 해 보세요."
            return WizardVerdict(ok: false, base: 0, gattOffset: 0, gatt: nil,
                                 title: "앉아 있을 때와 비울 때가 구분되지 않아요",
                                 body: body,
                                 logLine: "재보기: 구간이 겹친다 (착석 \(sLo)..\(sHi), 비움 \(aLo)..\(aHi))")
        }

        // "보통" 은 앉아 있을 때의 가장 약한 값보다 낮게 잡는다. 평균이 아니라
        // 끝값을 보는 이유는, 한 번만 밑돌아도 앉은 사람 앞에서 화면이 꺼지기 때문이다.
        let base = sLo - 2
        let advLog = "재보기: 착석 \(sLo)..\(sHi) (\(sn)개), 비움 \(aLo)..\(aHi) (\(an)개) -> 기준 \(base) dBm"

        // 연결 신호. 같은 규칙(착석 최저값 - 2 가 비움 최고값보다 위)으로 연결 쪽 기준을 잡고,
        // 저장하는 것은 광고 기준과의 차이뿐이다 - 거리 슬라이더가 광고 숫자를 옮기면 연결 쪽은
        // 그 차이만큼 따라간다. 폰 앱이 다른 PC 에 붙어 있었으면 연결 표본이 없다. 그때와 겹칠 때는
        // 지금 차이를 그대로 둔다: 지난번에 잰 차이는 이번 광고 기준과 함께 써도 여전히 맞는 값이다.
        let (gLo, gHi) = range(gattSeated)
        let (gaLo, gaHi) = range(gattAway)
        let gsn = gattSeated.count
        let gan = gattAway.count

        if gsn < minSeated || gan < minAway {
            let keep = currentGattOffset
            let body = "광고 신호\n  앉아 있을 때  \(sLo) ~ \(sHi)\n  자리 비웠을 때  \(aLo) ~ \(aHi)\n연결 신호\n  이번에는 못 쟀어요 (폰 앱이 이 컴퓨터에 연결돼 있지 않았어요)\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다."
            return WizardVerdict(ok: true, base: base, gattOffset: keep, gatt: .notMeasured,
                                 title: "다 됐어요",
                                 body: body,
                                 logLine: advLog + "; 연결 못 잼 (착석 \(gsn)개, 비움 \(gan)개) - 차이 \(signed(keep)) dB 그대로")
        }

        if gLo - 2 <= gaHi {
            let keep = currentGattOffset
            let body = "광고 신호\n  앉아 있을 때  \(sLo) ~ \(sHi)\n  자리 비웠을 때  \(aLo) ~ \(aHi)\n연결 신호\n  앉아 있을 때 \(gLo)~\(gHi), 비웠을 때 \(gaLo)~\(gaHi) 로 겹쳐서 이번 값은 쓰지 않았어요\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다."
            return WizardVerdict(ok: true, base: base, gattOffset: keep, gatt: .overlap,
                                 title: "다 됐어요",
                                 body: body,
                                 logLine: advLog + "; 연결 겹침 (착석 \(gLo)..\(gHi), 비움 \(gaLo)..\(gaHi)) - 차이 \(signed(keep)) dB 그대로")
        }

        // config.ini 를 읽을 때와 같은 [-40, 40] 으로 여기서 자른다. 안 자르면 로그에는 "차이 -45"
        // 가 남고 저장도 -45 로 되지만, [이대로 쓰기] 바로 뒤 다시 읽을 때 -40 이 되어 실제로는
        // -40 으로 돈다. 잰 범위는 본문과 로그에 그대로 남으니 자르기 전 값도 거기서 알 수 있다.
        let gattBase = gLo - 2
        let offset = min(max(gattBase - base, Choices.gattOffsetMin), Choices.gattOffsetMax)
        let body = "광고 신호\n  앉아 있을 때  \(sLo) ~ \(sHi)\n  자리 비웠을 때  \(aLo) ~ \(aHi)\n연결 신호\n  앉아 있을 때  \(gLo) ~ \(gHi)\n  자리 비웠을 때  \(gaLo) ~ \(gaHi)\n\n이 자리에 맞게 \"보통\" 을 맞췄어요. \"가까이\" 는 더 빨리 잠기고, \"멀리\" 는 더 늦게 잠깁니다."
        return WizardVerdict(ok: true, base: base, gattOffset: offset, gatt: .measured,
                             title: "다 됐어요",
                             body: body,
                             logLine: advLog + "; 연결 착석 \(gLo)..\(gHi) (\(gsn)개), 비움 \(gaLo)..\(gaHi) (\(gan)개) -> 차이 \(signed(offset)) dB")
    }

    /// WzRange: 비어 있으면 (999, -999)
    private static func range(_ v: [Int]) -> (Int, Int) {
        var lo = 999
        var hi = -999
        for x in v {
            lo = min(lo, x)
            hi = max(hi, x)
        }
        return (lo, hi)
    }
}
