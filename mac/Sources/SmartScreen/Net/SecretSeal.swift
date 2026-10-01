import Foundation
import Darwin
import IOKit
import SmartScreenCore

/// Mac DPAPI: Seal + machine-bound key (IOPlatformUUID, uid, salt file 0600).
///
/// config.ini 는 사용자 폴더의 평문 파일이다. 폰 토큰이 거기 있는 것과 refresh 토큰이 거기 있는
/// 것은 위험이 다르다: 폰 토큰은 화면을 열어 둘 수 있을 뿐이고, refresh 토큰은 계정 자체를 연다.
/// 그래서 Windows 는 DPAPI 로 이 사용자 + 이 PC 에 묶는다. 여기서는 같은 묶음을 이렇게 만든다:
///
///   키 = SHA-256("SmartScreen seal v1" || IOPlatformUUID || "|" || uid || "|" || salt)
///   salt = configDir/seal.salt 의 난수 32 바이트 (0600, 처음 봉할 때 만든다)
///
/// config.ini 만 다른 Mac 으로 복사해 가면 IOPlatformUUID 가 달라 풀리지 않고, 같은 Mac 의
/// 다른 사용자는 uid 와 (읽을 수 없는) salt 가 달라 풀리지 않는다 - DPAPI 와 같은 결과다.
/// authRefresh 에는 Windows 처럼 봉한 값의 표준 base64 가 들어가므로 세션 시작(세 갈래),
/// 회전 -> 봉한 문자열 -> config 저장 흐름이 그대로 같다.
///
/// Keychain 을 쓰지 않는다: 임시(ad-hoc) 서명 빌드는 업데이트마다 코드 해시가 바뀌고, 그러면
/// Keychain 이 업데이트 뒤마다 묻거나 조용히 거절해 사용자가 업데이트마다 로그아웃된다.
enum SecretSeal {
    // 봉하는 쪽은 로그인 스레드와 세션 갱신(클립보드 일꾼) 둘이다. 둘이 동시에 처음 봉하면서
    // salt 를 하나씩 만들면 한쪽이 봉한 값은 영영 열리지 않는다. 그래서 salt 를 읽고 만드는 일을
    // 한 줄로 세운다. (다른 프로세스와의 경합은 link(2) 가 막는다 - createSalt.)
    private static let lock = NSLock()
    private static let saltBytes = 32

    /// 빈 평문은 봉하지 않는다 (Windows ProtectSecret 도 거절한다). 실패하면 nil -
    /// 부르는 쪽은 "이 로그인은 다시 켜면 풀린다" 로 다룬다.
    static func protect(_ plain: String) -> String? {
        if plain.isEmpty { return nil }
        guard let key = machineKey(create: true) else { return nil }
        return Seal.seal(plain, key: key)
    }

    /// 봉한 값을 연다. salt 파일이 없으면 만들지 않고 실패한다 - 열 것이 없는데 새 salt 를
    /// 만들면 아무것도 얻지 못하고 파일만 남는다. 다른 Mac/사용자에서 온 값, Windows 의 DPAPI
    /// 값, 변조된 값 -> nil.
    static func unprotect(_ sealed: String) -> String? {
        if sealed.isEmpty { return nil }
        guard let key = machineKey(create: false) else { return nil }
        return Seal.open(sealed, key: key)
    }

    // ---- private ----

    private static var saltPath: String {
        return Paths.configDir.appendingPathComponent("seal.salt", isDirectory: false).path
    }

    private static func machineKey(create: Bool) -> Data? {
        // 기계 id 를 못 읽으면 봉하지도 열지도 않는다. 빈 id 로 만든 키는 이 Mac 에 묶이지 않는다.
        guard let machineId = platformUUID(), !machineId.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var salt = readSalt()
        if salt == nil && create {
            salt = createSalt()
        }
        guard let s = salt else { return nil }
        return Seal.deriveKey(machineId: machineId, uid: UInt32(getuid()), salt: s)
    }

    /// IOPlatformExpertDevice 의 IOPlatformUUID (하드웨어 UUID, 시스템 정보의 그 값).
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service == 0 { return nil }
        defer { _ = IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString,
                                                         kCFAllocatorDefault, 0) else { return nil }
        let value: CFTypeRef = prop.takeRetainedValue()
        return value as? String
    }

    /// 정확히 32 바이트일 때만 salt 로 친다. 없거나 읽을 수 없거나 길이가 다르면 nil.
    private static func readSalt() -> Data? {
        guard let d = FileManager.default.contents(atPath: saltPath), d.count == saltBytes else { return nil }
        return d
    }

    /// 새 salt 를 만든다. 임시 파일(0600)에 쓰고 fsync 한 뒤 제자리에 놓는다.
    /// salt 파일이 아직 없으면 link(2) 로 놓는다 - 다른 프로세스(--clip-test 등)가 먼저 만들었으면
    /// EEXIST 로 실패하고, 그때는 그쪽 salt 를 쓴다 (덮어쓰면 그쪽이 봉한 값이 열리지 않는다).
    /// 볼륨이 하드 링크를 지원하지 않으면 open(O_EXCL) 로 만든다 (createSaltExclusive).
    /// 이미 있는데 망가진 파일(길이가 다르다)이면 rename(2) 으로 바꾼다 - 그 파일로는 어차피
    /// 아무것도 열리지 않는다.
    private static func createSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        arc4random_buf(&bytes, saltBytes)

        let dest = saltPath
        let tmp = dest + ".\(getpid()).tmp"
        _ = unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 { return nil }
        // umask 와 상관없이 소유자만 읽고 쓴다.
        _ = fchmod(fd, 0o600)
        let written: Int = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            return write(fd, raw.baseAddress, raw.count)
        }
        let synced = fsync(fd) == 0
        let closed = close(fd) == 0
        if written != saltBytes || !synced || !closed {
            _ = unlink(tmp)
            return nil
        }

        if FileManager.default.fileExists(atPath: dest) {
            // 다른 프로세스가 그 사이에 만들었으면 그것을 쓴다.
            if let s = readSalt() {
                _ = unlink(tmp)
                return s
            }
            // 읽을 수조차 없는 파일은 건드리지 않는다 - 잠깐의 읽기 실패로 멀쩡한 salt 를 바꾸면
            // 이미 봉해 둔 로그인이 영영 열리지 않는다. 읽히는데 32 바이트가 아니면 망가진 것이다.
            if FileManager.default.contents(atPath: dest) == nil {
                _ = unlink(tmp)
                return nil
            }
            if rename(tmp, dest) != 0 {
                _ = unlink(tmp)
                return nil
            }
            return Data(bytes)
        }
        if link(tmp, dest) != 0 {
            let e = errno
            _ = unlink(tmp)
            if e == EEXIST {
                return readSalt()      // 다른 프로세스가 방금 만들었다
            }
            // 하드 링크를 못 쓰는 볼륨이다 (SMB 네트워크 홈 폴더, FAT/exFAT: ENOTSUP, EPERM ...).
            // 여기서 포기하면 그런 Mac 에서는 봉하기가 늘 실패해 로그인이 재시작을 넘기지 못한다
            // (Windows DPAPI 는 네트워크 프로필에서도 된다).
            return createSaltExclusive(bytes, dest: dest)
        }
        _ = unlink(tmp)
        return Data(bytes)
    }

    /// link(2) 대신 open(O_CREAT|O_EXCL) 로 "없을 때만 만들기" 를 한다. 같은 프로세스 안의 경합은
    /// SecretSeal.lock 이 이미 한 줄로 세웠고, 쓰다 만 파일(32 바이트가 아님)은 readSalt 가 거절한다.
    /// 다른 프로세스가 그사이 망가진 파일로 보고 rename 으로 바꿔 놓았을 수 있으므로, 다 쓴 뒤에는
    /// 우리 바이트가 아니라 지금 파일에 있는 salt 를 돌려준다 - 무엇으로 봉하든 디스크의 salt 와 같게.
    /// 실패해도 만든 파일을 지우지 않는다: 그새 다른 프로세스가 놓은 멀쩡한 salt 일 수 있고,
    /// 망가진 파일은 다음 createSalt 의 rename 경로가 바꾼다.
    private static func createSaltExclusive(_ bytes: [UInt8], dest: String) -> Data? {
        let fd = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 {
            if errno == EEXIST {
                return readSalt()      // 다른 프로세스가 방금 만들었다
            }
            return nil
        }
        // umask 와 상관없이 소유자만 읽고 쓴다 (SMB 에서는 실패할 수 있다 - 무시한다).
        _ = fchmod(fd, 0o600)
        let written: Int = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            return write(fd, raw.baseAddress, raw.count)
        }
        let synced = fsync(fd) == 0
        let closed = close(fd) == 0
        if written != saltBytes || !synced || !closed {
            return nil
        }
        return readSalt()
    }
}
