cmake_minimum_required(VERSION 3.20)
project(SmartScreen LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(SmartScreen WIN32 main.cpp)

target_link_libraries(SmartScreen PRIVATE
    ws2_32
    bthprops
    user32
    gdi32
    comctl32
    shell32
)

target_compile_definitions(SmartScreen PRIVATE UNICODE _UNICODE)
target_compile_options(SmartScreen PRIVATE /utf-8)
