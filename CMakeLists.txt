# Generated Cmake Pico project file

cmake_minimum_required(VERSION 3.13)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Initialise pico_sdk from installed location
# (note this can come from environment, CMake cache etc)

# == DO NOT EDIT THE FOLLOWING LINES for the Raspberry Pi Pico VS Code Extension to work ==
if(WIN32)
    set(USERHOME $ENV{USERPROFILE})
else()
    set(USERHOME $ENV{HOME})
endif()
set(sdkVersion 2.2.0)
set(toolchainVersion 14_2_Rel1)
set(picotoolVersion 2.2.0-a4)
set(picoVscode ${USERHOME}/.pico-sdk/cmake/pico-vscode.cmake)
if (EXISTS ${picoVscode})
    include(${picoVscode})
endif()
# ====================================================================================

# Use pico-sdk from lib/pico-sdk (override pico-vscode.cmake)
set(PICO_SDK_PATH ${CMAKE_CURRENT_LIST_DIR}/lib/pico-sdk)

# Custom board
set(PICO_BOARD harucom_board CACHE STRING "Board type")
set(PICO_BOARD_HEADER_DIRS ${CMAKE_CURRENT_LIST_DIR}/include/boards)
set(PICO_PLATFORM rp2350-arm-s CACHE STRING "Platform")

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)

project(harucom_os C CXX ASM)

# Version from git tags
find_package(Git)
if(GIT_FOUND)
    execute_process(
        COMMAND ${GIT_EXECUTABLE} describe --tags --always
        WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}
        OUTPUT_VARIABLE HARUCOM_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
endif()
if(NOT HARUCOM_VERSION)
    set(HARUCOM_VERSION "unknown")
endif()

# Build date
execute_process(
    COMMAND date +%Y%m%d
    OUTPUT_VARIABLE HARUCOM_BUILD_DATE
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

message(STATUS "harucom_os version: ${HARUCOM_VERSION} (${HARUCOM_BUILD_DATE})")

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

add_executable(harucom_os src/main.c)

pico_set_program_name(harucom_os "harucom_os")
pico_set_program_version(harucom_os "${HARUCOM_VERSION}")

set_target_properties(harucom_os PROPERTIES
    OUTPUT_NAME "harucom_os-${HARUCOM_VERSION}-${HARUCOM_BUILD_DATE}"
)

# Enable UART output for debug
pico_enable_stdio_uart(harucom_os 1)
pico_enable_stdio_usb(harucom_os 1)

target_link_libraries(harucom_os
        pico_stdlib)

target_include_directories(harucom_os PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}/src
)

string(APPEND CMAKE_EXE_LINKER_FLAGS "-Wl,--print-memory-usage")

pico_add_extra_outputs(harucom_os)

