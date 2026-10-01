import AppKit
import Darwin
import SmartScreenCore

// SingleInstance.swift - 한 번에 하나만 뜨게 한다 (Windows 의 이름 있는 뮤텍스 SmartScreen_Mutex_v1).
//
// configDir/instance.lock 에 flock(LOCK_EX) 을 잡고 프로세스가 끝날 때까지 놓지 않는다. 잠금은 파일
// 설명자에 붙어 있어서 프로세스가 죽으면 커널이 풀어 준다 (Windows 의 버려진 뮤텍스와 같다).
//
// 이미 잡혀 있으면 바로 포기하지 않고 10 초까지 다시 해 본다. 업데이트 직후다: updater 가 예전
// 프로세스가 끝나기를 기다렸다 해도 잠금이 풀리는 데 잠깐 걸릴 수 있다. 바로 "이미 실행 중" 으로
// 끝내면 새 버전이 아무 말 없이 안 뜬 것처럼 보인다.
//
// O_CLOEXEC 가 중요하다: 이 프로세스가 띄우는 자식(업데이트 적용기 updater)이 설명자를 물려받으면
// 우리가 끝난 뒤에도 잠금이 남고, 적용기가 다시 띄운 새 버전이 10 초를 기다리다 "이미 실행 중" 으로
// 끝난다.
//
// Finder 에서 이미 떠 있는 앱을 다시 열면 macOS 는 보통 두 번째 프로세스를 만들지 않고 떠 있는 앱을
// 깨운다 (applicationShouldHandleReopen). 이 잠금은 그 밖의 경우 - 다른 경로의 복사본, 터미널에서
// 직접 실행, 업데이트 직후의 재실행 - 를 위한 것이다.

enum SingleInstance {
    /// 잡은 잠금 파일의 설명자. 프로세스가 끝날 때까지 닫지 않는다.
    private static var lockFd: Int32 = -1
    private static let waitMs: UInt64 = 10_000
    private static let retryMicros: useconds_t = 100_000

    /// 잠금을 잡는다. 10 초 안에 못 잡으면 "SmartScreen is already running." 을 보이고 끝낸다 (exit 0).
    /// NSApplication.shared 를 만든 뒤에 부른다 (알림 상자를 띄울 수 있어야 한다).
    static func acquireOrExit() {
        if acquire() { return }
        Alerts.info("SmartScreen is already running.", title: "SmartScreen")
        exit(0)
    }

    private static func acquire() -> Bool {
        if lockFd >= 0 { return true }
        let path = Paths.configDir.appendingPathComponent("instance.lock", isDirectory: false).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0 {
            // 잠금 파일을 못 만드는 Mac 에서 앱이 아예 안 뜨는 것보다는 잠금 없이 뜨는 편이 낫다
            let e = errno
            EventLog.write("single instance: could not open instance.lock (errno \(e)) - starting without the lock")
            return true
        }
        let deadline = Mono.now() + waitMs
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFd = fd
                return true
            }
            let e = errno
            // 남이 잡고 있으면 EWOULDBLOCK (Darwin 에서는 EAGAIN 과 같은 값)
            if e != EAGAIN && e != EINTR {
                // 잠금을 지원하지 않는 파일 시스템 같은 경우. 이것도 막지는 않는다.
                EventLog.write("single instance: flock failed (errno \(e)) - starting without the lock")
                close(fd)
                return true
            }
            if Mono.now() >= deadline {
                close(fd)
                return false
            }
            usleep(retryMicros)
        }
    }
}
