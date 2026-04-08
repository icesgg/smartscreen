cmake_minimum_required(VERSION 3.20)
project(SmartScreen LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(SmartScreen WIN32
    client/main.cpp
    client/globals.cpp
    client/config.cpp
    client/bluetooth.cpp
    client/blackscreen.cpp
    client/enterprise/supabase.cpp
    client/p2p/discovery.cpp
    client/p2p/transfer.cpp
)

target_include_directories(SmartScreen PRIVATE client client/enterprise client/p2p)

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
)

target_compile_definitions(SmartScreen PRIVATE UNICODE _UNICODE)
target_compile_options(SmartScreen PRIVATE /utf-8)
