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

# Pico-PIO-USB (must be set before pico_sdk_init)
set(PICO_PIO_USB_PATH ${CMAKE_CURRENT_LIST_DIR}/lib/Pico-PIO-USB)

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

# --- Ruby (for PicoRuby build) ---
find_package(Ruby QUIET)
if(NOT Ruby_EXECUTABLE)
    message(FATAL_ERROR "Ruby interpreter not found.")
endif()
get_filename_component(_ruby_bindir "${Ruby_EXECUTABLE}" DIRECTORY)
find_program(RAKE rake HINTS "${_ruby_bindir}" REQUIRED)

get_filename_component(_toolchain_bindir "${CMAKE_C_COMPILER}" DIRECTORY)

# --- PicoRuby ---
set(PICORUBY_ROOT ${CMAKE_CURRENT_LIST_DIR}/lib/picoruby)
set(PICORUBY_BUILD_CONFIG harucom-os-pico2)

# Build libmruby.a
add_custom_command(
    OUTPUT ${PICORUBY_ROOT}/build/${PICORUBY_BUILD_CONFIG}/lib/libmruby.a
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${_toolchain_bindir}:${_ruby_bindir}:$ENV{PATH}"
        ${RAKE} MRUBY_CONFIG=${CMAKE_CURRENT_LIST_DIR}/build_config/${PICORUBY_BUILD_CONFIG}.rb
    WORKING_DIRECTORY ${PICORUBY_ROOT}
    COMMENT "Building PicoRuby (libmruby.a)..."
)

add_custom_target(build_picoruby
    DEPENDS ${PICORUBY_ROOT}/build/${PICORUBY_BUILD_CONFIG}/lib/libmruby.a
)

add_library(mruby STATIC IMPORTED)
set_target_properties(mruby PROPERTIES
    IMPORTED_LOCATION ${PICORUBY_ROOT}/build/${PICORUBY_BUILD_CONFIG}/lib/libmruby.a
)

# --- DVI driver library (timing-critical, always -O2) ---
add_library(picoruby-dvi
    mrbgems/picoruby-dvi/ports/rp2350/dvi_clock.c
    mrbgems/picoruby-dvi/ports/rp2350/dvi_output.c
)
target_include_directories(picoruby-dvi PUBLIC
    mrbgems/picoruby-dvi/include
    mrbgems/picoruby-dvi/ports/rp2350
    mrbgems/picoruby-dvi/ports/rp2350/fonts
)
target_link_libraries(picoruby-dvi pico_stdlib hardware_clocks hardware_dma)
target_compile_options(picoruby-dvi PRIVATE -O2)
target_compile_definitions(picoruby-dvi PRIVATE DVI_DIAGNOSTICS)

# --- Executable ---
add_executable(harucom_os
    src/main.c
    src/hal_task.c
    src/hal_machine.c
    src/psram.c
    src/flash_disk.c
    src/platform.c
    src/env.c
    ${PICORUBY_ROOT}/mrbgems/picoruby-rng/ports/rp2040/rng.c
    ${PICORUBY_ROOT}/mrbgems/picoruby-gpio/ports/rp2040/gpio.c
    ${PICORUBY_ROOT}/mrbgems/picoruby-io-console/ports/rp2040/io-console.c
    ${PICORUBY_ROOT}/mrbgems/picoruby-watchdog/ports/rp2040/watchdog.c
    mrbgems/picoruby-usb-host/ports/rp2350/usb_host.c
)

add_dependencies(harucom_os build_picoruby)

pico_set_program_name(harucom_os "harucom_os")
pico_set_program_version(harucom_os "${HARUCOM_VERSION}")

set(HARUCOM_RELEASE_NAME "harucom_os-${HARUCOM_VERSION}-${HARUCOM_BUILD_DATE}")

target_compile_definitions(harucom_os PRIVATE
    HARUCOM_VERSION="${HARUCOM_VERSION}"
    HARUCOM_BUILD_DATE="${HARUCOM_BUILD_DATE}"
    PICO_RP2350=1
    PICORB_VM_MRUBY=1
    MRB_INT64=1
    MRB_32BIT=1
    PICORB_ALLOC_ESTALLOC=1
    PICORB_ALLOC_ALIGN=8
    MRB_USE_CUSTOM_RO_DATA_P=1
    MRB_LINK_TIME_RO_DATA_P=1
    MRB_TICK_UNIT=1
    MRB_TIMESLICE_TICK_COUNT=10
    MRB_USE_TASK_SCHEDULER=1
    NO_CLOCK_GETTIME=1
    USE_FAT_FLASH_DISK=1
    NDEBUG=1
    BOARD_TUH_RHPORT=1
)

target_compile_options(harucom_os PRIVATE -fshort-enums)

target_include_directories(harucom_os PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/src
    ${CMAKE_CURRENT_LIST_DIR}/include
    ${PICORUBY_ROOT}/include
    ${PICORUBY_ROOT}/build/${PICORUBY_BUILD_CONFIG}/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-mruby/include
    ${PICORUBY_ROOT}/mrbgems/mruby-compiler2/include
    ${PICORUBY_ROOT}/mrbgems/mruby-compiler2/lib/prism/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-gpio/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-machine/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-io-console/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-watchdog/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-require/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-env/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-time/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-filesystem-fat/include
    ${PICORUBY_ROOT}/mrbgems/picoruby-filesystem-fat/lib/ff14b/source
    ${PICORUBY_ROOT}/mrbgems/picoruby-filesystem-fat/src/hal
    ${PICORUBY_ROOT}/build/${PICORUBY_BUILD_CONFIG}/mrbgems
    ${CMAKE_CURRENT_LIST_DIR}/mrbgems/picoruby-usb-host/include
)

# Enable UART output for debug (USB stdio disabled for USB host mode)
pico_enable_stdio_uart(harucom_os 1)
pico_enable_stdio_usb(harucom_os 0)

target_link_libraries(harucom_os
    pico_stdlib
    pico_multicore
    pico_unique_id
    pico_aon_timer
    hardware_timer
    hardware_gpio
    hardware_flash
    hardware_sync
    hardware_watchdog
    tinyusb_host
    tinyusb_pico_pio_usb
    mruby
    picoruby-dvi
)

# Core 0 needs 32 KB stack for mruby compiler (mrc_load_string_cxt).
# Default __STACK_SIZE is 0x800 (2 KB), which is insufficient.
target_link_options(harucom_os PRIVATE -Wl,--defsym=__STACK_SIZE=0x8000)

string(APPEND CMAKE_EXE_LINKER_FLAGS "-Wl,--print-memory-usage")

pico_add_extra_outputs(harucom_os)

# Copy release artifacts with version-stamped names
add_custom_command(TARGET harucom_os POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_BINARY_DIR}/harucom_os.elf
        ${CMAKE_BINARY_DIR}/${HARUCOM_RELEASE_NAME}.elf
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_BINARY_DIR}/harucom_os.uf2
        ${CMAKE_BINARY_DIR}/${HARUCOM_RELEASE_NAME}.uf2
    COMMENT "Creating release files: ${HARUCOM_RELEASE_NAME}.{elf,uf2}"
)
