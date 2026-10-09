cmake_minimum_required(VERSION 3.20)

project(xrbridge LANGUAGES CXX)

option(XRBRIDGE_TESTING "Expose the local GL copy test hook (never for packaging)" OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(OPENXR_INCLUDE_DIR "" CACHE PATH
    "Directory containing openxr/openxr.h and openxr/openxr_platform.h")
set(LUAJIT_INCLUDE_DIR "" CACHE PATH
    "Directory containing LuaJIT's lua.h and lauxlib.h")
set(LUAJIT_LIBRARY "" CACHE FILEPATH
    "LuaJIT library matching the LÖVE runtime")

if(NOT OPENXR_INCLUDE_DIR)
    find_path(OPENXR_INCLUDE_DIR NAMES openxr/openxr.h
        HINTS "$ENV{OPENXR_SDK}" "$ENV{OPENXR_ROOT}" /opt/openxr
        PATH_SUFFIXES include)
endif()
if(NOT OPENXR_INCLUDE_DIR OR
   NOT EXISTS "${OPENXR_INCLUDE_DIR}/openxr/openxr.h" OR
   NOT EXISTS "${OPENXR_INCLUDE_DIR}/openxr/openxr_platform.h")
    message(FATAL_ERROR "OpenXR headers not found. Set OPENXR_INCLUDE_DIR.")
endif()

if(NOT LUAJIT_INCLUDE_DIR)
    find_path(LUAJIT_INCLUDE_DIR NAMES lua.h
        HINTS "$ENV{LUAJIT_DIR}" "$ENV{LUAJIT_ROOT}"
        PATH_SUFFIXES src include include/luajit-2.1)
endif()
if(NOT LUAJIT_INCLUDE_DIR OR NOT EXISTS "${LUAJIT_INCLUDE_DIR}/lua.h")
    message(FATAL_ERROR "LuaJIT headers not found. Set LUAJIT_INCLUDE_DIR.")
endif()

if(NOT LUAJIT_LIBRARY)
    find_library(LUAJIT_LIBRARY NAMES luajit-5.1 luajit lua51
        HINTS "$ENV{LUAJIT_DIR}" "$ENV{LUAJIT_ROOT}"
        PATH_SUFFIXES lib lib64 src)
endif()
if(NOT LUAJIT_LIBRARY)
    message(FATAL_ERROR "LuaJIT library not found. Set LUAJIT_LIBRARY.")
endif()

add_library(xrbridge MODULE xrbridge.cpp VisibilitySelection.cpp)
# Preserve the Lua selector's ordered double operations only in this kernel.
set_source_files_properties(VisibilitySelection.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
target_include_directories(xrbridge PRIVATE
    "${OPENXR_INCLUDE_DIR}"
    "${LUAJIT_INCLUDE_DIR}")
target_compile_options(xrbridge PRIVATE -Wall -Wextra -Wpedantic)

if(WIN32)
    target_compile_definitions(xrbridge PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
    target_link_libraries(xrbridge PRIVATE "${LUAJIT_LIBRARY}" opengl32)
    set_target_properties(xrbridge PROPERTIES
        PREFIX ""
        OUTPUT_NAME "xrbridge"
        SUFFIX ".dll")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(LOVE_ROOT "" CACHE PATH "Pinned LÖVE 11.5 source tree")
    set(LOVE_LIBRARY "" CACHE FILEPATH "Pinned LÖVE 11.5 shared library")
    set(OPENXR_LOADER_LIBRARY "" CACHE FILEPATH
        "Pinned OpenXR loader library (static PIC archive on SteamOS)")
    if(NOT LOVE_ROOT)
        set(LOVE_ROOT "/opt/love-11.5")
    endif()
    if(NOT LOVE_LIBRARY)
        find_library(LOVE_LIBRARY NAMES love-11.5
            PATHS /opt/love/lib "${LOVE_ROOT}/build/lib")
    endif()
    if(NOT LOVE_LIBRARY)
        message(FATAL_ERROR "Pinned LÖVE 11.5 library not found; set LOVE_LIBRARY.")
    endif()
    if(NOT EXISTS "${LOVE_ROOT}/src/common/runtime.h" OR
       NOT EXISTS "${LOVE_ROOT}/src/modules/graphics/Canvas.h")
        message(FATAL_ERROR "LOVE_ROOT must identify the matching LÖVE 11.5 source tree.")
    endif()
    file(STRINGS "${LOVE_ROOT}/src/common/version.h" LOVE_VERSION_LINE
        REGEX "^#define LOVE_VERSION_STRING \"11\\.5\"$")
    if(NOT LOVE_VERSION_LINE)
        message(FATAL_ERROR "LOVE_ROOT must be the exact LÖVE 11.5 source tree.")
    endif()
    get_filename_component(LOVE_LIBRARY_FILENAME "${LOVE_LIBRARY}" NAME)
    if(NOT LOVE_LIBRARY_FILENAME STREQUAL "liblove-11.5.so")
        message(FATAL_ERROR
            "Linux xrbridge must link the pinned liblove-11.5.so (got ${LOVE_LIBRARY_FILENAME}).")
    endif()
    if(NOT OPENXR_LOADER_LIBRARY)
        find_library(OPENXR_LOADER_LIBRARY NAMES openxr_loader
            PATHS /opt/openxr/lib /opt/openxr/lib64)
    endif()
    if(NOT OPENXR_LOADER_LIBRARY)
        message(FATAL_ERROR "OpenXR loader not found; set OPENXR_LOADER_LIBRARY.")
    endif()

    find_package(OpenGL REQUIRED COMPONENTS OpenGL GLX)
    find_package(X11 REQUIRED)
    target_compile_definitions(xrbridge PRIVATE XRBRIDGE_LOVE_ABI_11_5=1)
    if(XRBRIDGE_TESTING)
        target_compile_definitions(xrbridge PRIVATE XRBRIDGE_TESTING=1)
    endif()
    target_include_directories(xrbridge PRIVATE
        "${LOVE_ROOT}/src"
        "${LOVE_ROOT}/src/modules")
    target_link_libraries(xrbridge PRIVATE
        "${LUAJIT_LIBRARY}"
        "${LOVE_LIBRARY}"
        "${OPENXR_LOADER_LIBRARY}"
        OpenGL::GL
        X11::X11
        ${CMAKE_DL_LIBS}
        pthread)
    set_target_properties(xrbridge PROPERTIES
        PREFIX ""
        OUTPUT_NAME "xrbridge"
        SUFFIX ".so"
        BUILD_RPATH "/opt/love/lib")
else()
    message(FATAL_ERROR "xrbridge supports Windows/WGL and Linux/GLX only")
endif()
