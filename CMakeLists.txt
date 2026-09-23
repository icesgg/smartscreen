cmake_minimum_required(VERSION 3.20)
project(SmartScreen LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CRT를 정적 링크 → 다른 PC에서 VC++ 재배포 패키지 없이 exe 하나로 실행
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(SmartScreen WIN32
    client/main.cpp
    client/globals.cpp
    client/config.cpp
    client/bluetooth.cpp
    client/blackscreen.cpp
    client/ble_rssi.cpp
    client/ble_gatt.cpp
    client/ble_ident.cpp
    client/irk.cpp
    client/enterprise/supabase.cpp
    client/p2p/discovery.cpp
    client/p2p/transfer.cpp
    client/video/player.cpp
)

target_include_directories(SmartScreen PRIVATE client client/enterprise client/p2p client/video)

target_link_libraries(SmartScreen PRIVATE
    ws2_32
    bthprops
    user32
    gdi32
    comctl32
    shell32
    gdiplus
    comdlg32
    winhttp
    mfplat
    mf
    mfplay
    mfuuid
    ole32
    propsys
    windowsapp
    bcrypt
)

target_compile_definitions(SmartScreen PRIVATE UNICODE _UNICODE)
target_compile_options(SmartScreen PRIVATE /utf-8)

# 진단 도구들. 배포 묶음에 같이 넣으므로 제품과 같은 빌드에서 나와야 한다 -
# 손으로 복사해 두면 소스가 바뀌어도 낡은 exe 가 그대로 따라간다.

# 어댑터가 무엇을 지원한다고 보고하는지 (드라이버 보고값이라 믿을 수 없다)
add_executable(BtCheck tools/btcheck.cpp)
# 다른 PC 에서 돌려 이 PC 의 BLE 광고가 실제로 나가는지 확인
add_executable(AdvScan tools/advscan.cpp)
# 페어링 없이 잠긴 폰에서 신원 토큰을 읽을 수 있는지 (tools/probescan.cpp 머리말 참고)
add_executable(ProbeScan tools/probescan.cpp)

foreach(t BtCheck AdvScan ProbeScan)
    target_link_libraries(${t} PRIVATE windowsapp ole32)
    target_compile_definitions(${t} PRIVATE UNICODE _UNICODE)
    target_compile_options(${t} PRIVATE /utf-8)
endforeach()
