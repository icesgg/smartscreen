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

# 개발용 진단 도구. 페어링 없이 GATT 연결이 되는지 확인한다 (tools/probescan.cpp 머리말 참고).
add_executable(ProbeScan tools/probescan.cpp)
target_link_libraries(ProbeScan PRIVATE windowsapp ole32)
target_compile_definitions(ProbeScan PRIVATE UNICODE _UNICODE)
target_compile_options(ProbeScan PRIVATE /utf-8)
