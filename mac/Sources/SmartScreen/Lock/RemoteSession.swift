import CoreGraphics
import Foundation

// RemoteSession.swift - Windows IsRemoteSession() (client/blackscreen.cpp) 의 Mac 판.
//
// Windows 는 GetSystemMetrics(SM_REMOTESESSION) 을 물었다. Mac 에는 RDP 라는 개념이 없으므로
// "우리 GUI 세션이 실제 화면(콘솔)에 붙어 있지 않다" 로 옮긴다: 화면 공유로 다른 사용자/가상
// 세션에 로그인했을 때, 또는 빠른 사용자 전환으로 이 세션이 뒤로 밀려났을 때가 그렇다.
//
// 이 판정은 콘솔에서 떨어진 세션만 안다. 콘솔 사용자 화면을 그대로 보여 주는 도구(화면 공유 /
// ARD 로 같은 사용자 세션을 보기, TeamViewer, AnyDesk, Chrome 원격 데스크톱)는 여기 걸리지
// 않는다. Windows 판이 RDP 만 아는 것과 같은 한계다 - 지금 코드는 모르는 척하지 않고 모른다.
enum RemoteSession {
    /// 세션이 원격으로 연결/재연결되면 값이 바뀌므로 그때그때 물어본다 (캐시하지 않는다).
    /// 사전을 못 얻거나 키가 없으면 원격이 아니라고 본다 - 모르는 것을 원격이라 우기면
    /// 자동 잠금이 조용히 꺼진다.
    static func isRemote() -> Bool {
        guard let cf = CGSessionCopyCurrentDictionary() else { return false }
        let dict = cf as NSDictionary
        // kCGSessionOnConsoleKey 매크로의 실제 문자열. CFSTR 매크로가 Swift 로 들어오는지에
        // 기대지 않으려고 글자 그대로 쓴다.
        guard let onConsole = dict.object(forKey: "kCGSSessionOnConsoleKey") as? Bool else { return false }
        return onConsole == false
    }
}
