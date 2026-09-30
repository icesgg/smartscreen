import Foundation

/// 이 빌드의 버전. build_app.sh 가 client/version.h 의 세 숫자로 Info.plist 의
/// CFBundleShortVersionString 을 채운다 - Windows 판과 같은 번호를 쓴다.
/// 묶음 밖(swift test, swift run)에서는 Info.plist 가 없어 "0.0.0" 이다.
public enum BuildInfo {
    public static var version: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "0.0.0"
    }
}
