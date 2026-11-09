cmake_minimum_required(VERSION 3.20)
project(monitor_sender LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET gstreamer-1.0)

add_executable(monitor_sender src/monitor_sender.cpp)
target_compile_options(monitor_sender PRIVATE -Wall -Wextra)
target_link_libraries(monitor_sender PRIVATE PkgConfig::GSTREAMER)
