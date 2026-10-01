import Foundation

/// 내장 서버 값 (Windows main.cpp kDefaultSupabaseUrl / kDefaultAnonKey, iOS 앱도 같은 값).
///
/// anon key 가 여기 박혀 있는 것은 설계대로다 - 공개되도록 만들어진 값이고, device_tokens 를
/// 지키는 것은 키가 아니라 RLS 다.
///
/// 덮어쓰기 규칙 (부르는 자리마다): config 의 값이 비어 있지 않으면 그것이 이긴다.
/// 앱은 이 기본값을 config 에 써 넣지 않는다 - 한 번 적힌 값은 실행 파일의 기본값이
/// 바뀌어도 그 PC 에 남는다 (1.1.4 이하에서 등록한 PC 에 serverUrl/anonKey 가 남은 이유).
public enum ServerDefaults {
    public static let supabaseUrl = "https://vnonoschrzbgvyeduosm.supabase.co"
    public static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZub25vc2NocnpiZ3Z5ZWR1b3NtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2NzkyNjQsImV4cCI6MjA5MTI1NTI2NH0.KqkmH7UtcR4ihFDMmAMfWRH0O2P2s__Jglzr5QWIzfc"
    /// 두 "대시보드" 단추가 여는 주소
    public static let dashboardUrl = "https://icesgg.github.io/smartscreen/dashboard.html"

    /// cfg.serverUrl if non-empty else the built-in URL.
    public static func url(_ cfg: AppConfig) -> String {
        return cfg.serverUrl.isEmpty ? supabaseUrl : cfg.serverUrl
    }

    /// cfg.anonKey if non-empty else the built-in key.
    public static func key(_ cfg: AppConfig) -> String {
        return cfg.anonKey.isEmpty ? anonKey : cfg.anonKey
    }
}
