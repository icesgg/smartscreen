import Foundation
import Darwin

/// 설정 폴더와 그 안의 파일들 (Windows GetConfigDir = %APPDATA%\SmartScreen).
///
/// Mac 은 ~/Library/Application Support/SmartScreen 이다. 파일 이름은 Windows 와 같다
/// (config.ini, events.log, enterprise_content/...) - 문서와 지원 절차가 두 판에서 같게.
///
/// $SMARTSCREEN_HOME 이 있으면 그 폴더를 쓴다 (시험용). 접근할 때마다 다시 읽는다:
/// 시험이 setenv 로 임시 폴더를 가리킨 뒤에 파일을 만지기 때문에 처음 값을 붙잡아 두면
/// 시험이 사용자의 진짜 설정을 건드린다.
public enum Paths {
    /// ~/Library/Application Support/SmartScreen (or $SMARTSCREEN_HOME if set; used by tests). Created on first use.
    public static var configDir: URL {
        let dir = baseDir()
        // Windows 도 GetConfigDir 를 부를 때마다 CreateDirectoryW 를 한다. 누가 폴더를
        // 지워도 다음 로그 한 줄, 다음 저장이 다시 만든다.
        ensureDir(dir)
        return dir
    }

    /// configDir/config.ini
    public static var configFile: URL {
        return configDir.appendingPathComponent("config.ini", isDirectory: false)
    }

    /// configDir/events.log
    public static var eventsLog: URL {
        return configDir.appendingPathComponent("events.log", isDirectory: false)
    }

    /// configDir/enterprise_content (created on demand)
    public static var enterpriseContentDir: URL {
        let u = configDir.appendingPathComponent("enterprise_content", isDirectory: true)
        ensureDir(u)
        return u
    }

    /// configDir/update (created on demand)
    public static var updateDir: URL {
        let u = configDir.appendingPathComponent("update", isDirectory: true)
        ensureDir(u)
        return u
    }

    /// 폴더를 (중간 폴더까지) 만든다. 이미 있으면 아무 일도 하지 않는다. 실패는 조용히
    /// 넘긴다 - 그 폴더에 쓰는 쪽이 자기 실패로 알아챈다 (로그는 줄이 사라질 뿐 죽지 않는다).
    public static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    private static func baseDir() -> URL {
        if let p = getenv("SMARTSCREEN_HOME") {
            let s = String(cString: p)
            if !s.isEmpty { return URL(fileURLWithPath: s, isDirectory: true) }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return support.appendingPathComponent("SmartScreen", isDirectory: true)
    }
}
