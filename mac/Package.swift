// swift-tools-version:5.9
// SmartScreen for macOS. Windows 판(client/)과 같은 일을 하는 네이티브 앱이다.
//
// 두 덩어리로 나눈다:
//  - SmartScreenCore : AppKit/CoreBluetooth 없이 도는 판단 로직 (필터, 상태 기계,
//                      config.ini, 버전 비교, 경로 검증, PKCE...). `swift test` 가 이걸 본다.
//  - SmartScreen     : 앱 본체 (창, 블루투스, 잠금 화면, 서버).
//
// 빌드는 build_app.sh 가 한다 (.app 묶음 + 서명 + zip). CI 는 .github/workflows/mac.yml.
import PackageDescription

let package = Package(
    name: "SmartScreen",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SmartScreenCore",
            path: "Sources/SmartScreenCore"
        ),
        .executableTarget(
            name: "SmartScreen",
            dependencies: ["SmartScreenCore"],
            path: "Sources/SmartScreen"
        ),
        .testTarget(
            name: "SmartScreenCoreTests",
            dependencies: ["SmartScreenCore"],
            path: "Tests/SmartScreenCoreTests"
        ),
    ]
)
