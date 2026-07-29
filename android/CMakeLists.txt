cmake_minimum_required(VERSION 3.13)
project(RNDuckDB)

set(CMAKE_VERBOSE_MAKEFILE ON)
set(CMAKE_CXX_STANDARD 20)

# Path to DuckDB source (submodule at react-native-duckdb/duckdb/)
set(DUCKDB_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../../duckdb")

# Run extension configuration script to generate extension_config_local.cmake.
# APP_ROOT_DIR is passed from build.gradle (rootProject.projectDir.parentFile).
# DUCKDB_EXTENSIONS is set from gradle.properties when Expo config plugin is used.
find_program(NODE_EXECUTABLE node REQUIRED)

set(CONFIGURE_ARGS
  ${NODE_EXECUTABLE} ${CMAKE_SOURCE_DIR}/../../scripts/configure-extensions.js
  --duckdb-path ${DUCKDB_SOURCE_DIR}
  --app-root ${APP_ROOT_DIR}
)

# When extensions are provided via gradle.properties (Expo managed workflow),
# pass them directly — this overrides package.json discovery.
if(NOT "${DUCKDB_EXTENSIONS}" STREQUAL "")
  list(APPEND CONFIGURE_ARGS --extensions "${DUCKDB_EXTENSIONS}")
endif()

execute_process(
  COMMAND ${CONFIGURE_ARGS}
  RESULT_VARIABLE CONFIGURE_RESULT
)
if(NOT CONFIGURE_RESULT EQUAL 0)
  message(FATAL_ERROR "react-native-duckdb: Extension configuration failed (exit ${CONFIGURE_RESULT})")
endif()

# DuckDB build options — disable everything we don't need on mobile
set(BUILD_SHELL OFF CACHE BOOL "" FORCE)
set(BUILD_UNITTESTS OFF CACHE BOOL "" FORCE)
set(BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(ENABLE_SANITIZER OFF CACHE BOOL "" FORCE)
set(ENABLE_UBSAN OFF CACHE BOOL "" FORCE)
set(EXTENSION_STATIC_BUILD OFF CACHE BOOL "" FORCE)
set(BUILD_EXTENSIONS_ONLY OFF CACHE BOOL "" FORCE)
set(DUCKDB_EXPLICIT_PLATFORM "android_${ANDROID_ABI}" CACHE STRING "" FORCE)

# Check if httpfs is in the extension config (needs OpenSSL + libcurl)
set(EXT_CONFIG_PATH "${DUCKDB_SOURCE_DIR}/extension/extension_config_local.cmake")
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content)
  if(_ext_config_content MATCHES "httpfs")
    # httpfs requires OpenSSL + libcurl which only support 64-bit ABIs.
    # 32-bit Android devices are effectively extinct (Google required 64-bit since 2019).
    if(ANDROID_ABI STREQUAL "armeabi-v7a" OR ANDROID_ABI STREQUAL "x86")
      message(WARNING "react-native-duckdb: httpfs skipped for ${ANDROID_ABI} (32-bit not supported). httpfs requires 64-bit ABIs (arm64-v8a, x86_64).")
      # Strip httpfs from extension config so DuckDB doesn't try to build it.
      # Safe because configure-extensions.js regenerates this file each CMake invocation.
      file(STRINGS "${EXT_CONFIG_PATH}" _ext_lines)
      file(WRITE "${EXT_CONFIG_PATH}" "")
      foreach(_line IN LISTS _ext_lines)
        if(NOT _line MATCHES "duckdb_extension_load\\(httpfs")
          file(APPEND "${EXT_CONFIG_PATH}" "${_line}\n")
        endif()
      endforeach()
    else()
      message(STATUS "react-native-duckdb: httpfs detected, building OpenSSL + libcurl for ${ANDROID_ABI}")

      # Pass NDK path from build.gradle so the cross-compilation script can find the toolchain
      if(ANDROID_NDK_FOR_HTTPFS)
        set(ENV{ANDROID_NDK_ROOT} "${ANDROID_NDK_FOR_HTTPFS}")
      endif()

      set(VENDOR_DIR "${CMAKE_SOURCE_DIR}/../../vendor")
      execute_process(
        COMMAND bash "${CMAKE_SOURCE_DIR}/../../scripts/build-openssl-curl.sh" android "${ANDROID_ABI}"
        RESULT_VARIABLE _httpfs_deps_result
      )
      if(NOT _httpfs_deps_result EQUAL 0)
        message(FATAL_ERROR "react-native-duckdb: Failed to build OpenSSL/curl for httpfs (${ANDROID_ABI})")
      endif()

      # CMake's FindOpenSSL and FindCURL modules don't reliably locate libs during
      # NDK cross-compilation (sysroot search paths don't include our vendor dir).
      # Spell out every path so DuckDB's httpfs extension links correctly.
      set(OPENSSL_ROOT_DIR "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}" CACHE PATH "" FORCE)
      set(OPENSSL_INCLUDE_DIR "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/include" CACHE PATH "" FORCE)
      set(OPENSSL_SSL_LIBRARY "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/lib/libssl.a" CACHE FILEPATH "" FORCE)
      set(OPENSSL_CRYPTO_LIBRARY "${VENDOR_DIR}/openssl/android-${ANDROID_ABI}/lib/libcrypto.a" CACHE FILEPATH "" FORCE)
      set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "" FORCE)
      set(CURL_ROOT "${VENDOR_DIR}/curl/android-${ANDROID_ABI}" CACHE PATH "" FORCE)
      set(CURL_INCLUDE_DIR "${VENDOR_DIR}/curl/android-${ANDROID_ABI}/include" CACHE PATH "" FORCE)
      set(CURL_LIBRARY "${VENDOR_DIR}/curl/android-${ANDROID_ABI}/lib/libcurl.a" CACHE FILEPATH "" FORCE)
      set(_HTTPFS_ENABLED TRUE)

      # libcurl depends on system zlib — ensure both DuckDB and our lib can link it.
      # Set this globally so DuckDB's own shared lib target can also find zlib.
      find_library(ZLIB_LIB z)
      set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -lz")
    endif()
  endif()
endif()

# Check if iceberg is in the extension config — needs AWSSDK + roaring + friends
# from vcpkg (same shape as iOS, see scripts/build-duckdb-ios.sh). Iceberg
# depends on AWSSDK C++ + aws-c-* CRT libs, which are 64-bit only for the
# same reasons httpfs is (no vcpkg triplet for 32-bit android).
set(_ICEBERG_ENABLED FALSE)
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content_iceberg)
  if(_ext_config_content_iceberg MATCHES "iceberg")
    if(ANDROID_ABI STREQUAL "armeabi-v7a" OR ANDROID_ABI STREQUAL "x86")
      message(WARNING "react-native-duckdb: iceberg skipped for ${ANDROID_ABI} (32-bit not supported). iceberg's AWSSDK deps are 64-bit-only.")
      # Strip iceberg from extension config so DuckDB doesn't try to build it.
      # Mirror the httpfs 32-bit-skip pattern above.
      file(STRINGS "${EXT_CONFIG_PATH}" _ext_lines_iceberg)
      file(WRITE "${EXT_CONFIG_PATH}" "")
      foreach(_line IN LISTS _ext_lines_iceberg)
        if(NOT _line MATCHES "duckdb_extension_load\\(iceberg")
          file(APPEND "${EXT_CONFIG_PATH}" "${_line}\n")
        endif()
      endforeach()
    else()
      # Resolve VCPKG_ROOT — default $HOME/vcpkg, env override.
      if(DEFINED ENV{VCPKG_ROOT})
        set(_VCPKG_ROOT "$ENV{VCPKG_ROOT}")
      else()
        set(_VCPKG_ROOT "$ENV{HOME}/vcpkg")
      endif()

      # Auto-copy bundled x64-android-release triplet into vcpkg if missing.
      # Upstream vcpkg ships arm64-android-release but not x64-android-release;
      # we bundle the custom triplet in scripts/vcpkg-triplets/ and copy it in
      # so `vcpkg install …:x64-android-release` resolves.
      set(_BUNDLED_TRIPLET "${CMAKE_SOURCE_DIR}/../../scripts/vcpkg-triplets/x64-android-release.cmake")
      set(_INSTALLED_TRIPLET "${_VCPKG_ROOT}/triplets/community/x64-android-release.cmake")
      if(EXISTS "${_BUNDLED_TRIPLET}" AND NOT EXISTS "${_INSTALLED_TRIPLET}")
        message(STATUS "react-native-duckdb: copying bundled triplet ${_BUNDLED_TRIPLET} -> ${_INSTALLED_TRIPLET}")
        configure_file("${_BUNDLED_TRIPLET}" "${_INSTALLED_TRIPLET}" COPYONLY)
      endif()

      # ABI -> vcpkg triplet
      if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(_VCPKG_TRIPLET "arm64-android-release")
      elseif(ANDROID_ABI STREQUAL "x86_64")
        set(_VCPKG_TRIPLET "x64-android-release")
      endif()

      set(_VCPKG_INSTALL "${_VCPKG_ROOT}/installed/${_VCPKG_TRIPLET}")
      if(NOT EXISTS "${_VCPKG_INSTALL}/share/awssdk/AWSSDKConfig.cmake")
        message(FATAL_ERROR "react-native-duckdb: iceberg requires vcpkg triplet ${_VCPKG_TRIPLET} at ${_VCPKG_INSTALL} (missing share/awssdk/AWSSDKConfig.cmake). Run:\n  ${_VCPKG_ROOT}/vcpkg install 'aws-sdk-cpp[core,sso,sts]:${_VCPKG_TRIPLET}' roaring:${_VCPKG_TRIPLET} snappy:${_VCPKG_TRIPLET} liblzma:${_VCPKG_TRIPLET} jansson:${_VCPKG_TRIPLET}\n(Requires ANDROID_NDK_HOME env var pointing at your NDK install.)")
      endif()

      message(STATUS "react-native-duckdb: iceberg detected, using vcpkg triplet ${_VCPKG_TRIPLET} at ${_VCPKG_INSTALL}")

      # Same CMAKE_FIND_ROOT_PATH_MODE gotcha as iOS: under cross-compile
      # cmake defaults these to ONLY (restricted to Android sysroot), and
      # vcpkg's install prefix lives outside the sysroot. Relax to BOTH
      # so find_package(AWSSDK) + find_package(roaring CONFIG) resolve.
      list(APPEND CMAKE_PREFIX_PATH "${_VCPKG_INSTALL}")
      set(AWSSDK_ROOT_DIR "${_VCPKG_INSTALL}" CACHE PATH "" FORCE)
      set(AWSSDK_DIR "${_VCPKG_INSTALL}/share/awssdk" CACHE PATH "" FORCE)
      list(APPEND CMAKE_FIND_ROOT_PATH "${_VCPKG_INSTALL}")
      set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
      set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
      set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

      set(_ICEBERG_ENABLED TRUE)
      set(_ICEBERG_VCPKG_LIB "${_VCPKG_INSTALL}/lib")
    endif()
  endif()
endif()

# Check if VSS extension is in the config — needs aligned_alloc workaround on Android.
# Android Bionic's aligned_alloc requires API level 28+, but we target API 24.
# The usearch library (bundled in duckdb-vss) calls aligned_alloc directly.
# We provide an inline wrapper using posix_memalign (available since API 16).
if(EXISTS "${EXT_CONFIG_PATH}")
  file(READ "${EXT_CONFIG_PATH}" _ext_config_content_vss)
  if(_ext_config_content_vss MATCHES "vss")
    message(STATUS "react-native-duckdb: VSS detected, adding aligned_alloc workaround for Android API ${ANDROID_NATIVE_API_LEVEL}")
    set(_VSS_ENABLED TRUE)
  endif()
endif()

# Always build DuckDB with Release optimizations (-O3 -DNDEBUG), even for debug
# app builds. This matches the iOS behavior where DuckDB.xcframework is always
# pre-built with -DCMAKE_BUILD_TYPE=Release. Without this, AGP maps debug builds
# to CMAKE_BUILD_TYPE=Debug which compiles DuckDB at -O0 — causing ~30x slowdowns.
#
# We use a wrapper subdirectory to scope add_compile_options to DuckDB only.
# The wrapper's add_compile_options(-O3 -DNDEBUG) applies to DuckDB and its
# children but NOT to our RNDuckDB target (which is defined in this file).
add_subdirectory(duckdb-release-wrapper ${CMAKE_CURRENT_BINARY_DIR}/duckdb EXCLUDE_FROM_ALL)

# Our library source files
file(GLOB_RECURSE cpp_files RELATIVE ${CMAKE_SOURCE_DIR}
  "../cpp/**.cpp"
  "cpp-adapter.cpp"
)

add_library(${CMAKE_PROJECT_NAME} SHARED ${cpp_files})

include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/RNDuckDB+autolinking.cmake)

# Include paths: DuckDB source headers + our C++ code
target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
  ${DUCKDB_SOURCE_DIR}/src/include
  ${CMAKE_SOURCE_DIR}/../cpp
)

set_target_properties(
  ${CMAKE_PROJECT_NAME} PROPERTIES
  CXX_STANDARD ${CMAKE_CXX_STANDARD}
  CXX_EXTENSIONS OFF
  POSITION_INDEPENDENT_CODE ON
)

find_package(ReactAndroid REQUIRED CONFIG)
find_package(fbjni REQUIRED CONFIG)
find_library(LOG_LIB log)

# Link DuckDB static library + extension libraries (same pattern as DuckDB shell)
target_link_libraries(
  ${CMAKE_PROJECT_NAME}
  duckdb_static
  ${LOG_LIB}
  android
  fbjni::fbjni
  ReactAndroid::jsi
)
link_extension_libraries(${CMAKE_PROJECT_NAME} PRIVATE)

# Link vendor OpenSSL + libcurl static libs into our .so when httpfs is enabled.
# DuckDB's httpfs extension references OpenSSL/curl symbols but doesn't link them
# itself — the consuming library (us) must provide them at final link time.
if(_HTTPFS_ENABLED)
  find_library(ZLIB_LIB z)
  target_link_libraries(${CMAKE_PROJECT_NAME}
    ${OPENSSL_SSL_LIBRARY}
    ${OPENSSL_CRYPTO_LIBRARY}
    ${CURL_LIBRARY}
    ${ZLIB_LIB}
  )
endif()

# Link vcpkg-installed AWSSDK + CRT + roaring into our .so when iceberg is
# enabled. iceberg's compiled .o files (pulled in via link_extension_libraries)
# reference Aws::* + roaring_* symbols; the actual implementations live in
# these .a archives. Wrap in --start-group/--end-group because static-lib
# link order across the AWS C SDK is finicky (aws-crt-cpp depends on
# aws-c-*, which depend on each other in a cycle at link time). GNU-style
# linkers (LLVM ld64 on NDK) honor these markers.
if(_ICEBERG_ENABLED)
  target_link_libraries(${CMAKE_PROJECT_NAME}
    -Wl,--start-group
    ${_ICEBERG_VCPKG_LIB}/libaws-cpp-sdk-sts.a
    ${_ICEBERG_VCPKG_LIB}/libaws-cpp-sdk-sso.a
    ${_ICEBERG_VCPKG_LIB}/libaws-cpp-sdk-core.a
    ${_ICEBERG_VCPKG_LIB}/libaws-crt-cpp.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-s3.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-auth.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-http.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-mqtt.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-event-stream.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-io.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-compression.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-sdkutils.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-cal.a
    ${_ICEBERG_VCPKG_LIB}/libaws-c-common.a
    ${_ICEBERG_VCPKG_LIB}/libaws-checksums.a
    ${_ICEBERG_VCPKG_LIB}/libs2n.a
    ${_ICEBERG_VCPKG_LIB}/libroaring.a
    -Wl,--end-group
  )
endif()

if (REACTNATIVE_MERGED_SO OR ReactAndroid_VERSION_MINOR GREATER_EQUAL 76)
  target_link_libraries(
    ${CMAKE_PROJECT_NAME}
    ReactAndroid::reactnative
  )
else()
  target_link_libraries(
    ${CMAKE_PROJECT_NAME}
    ReactAndroid::turbomodulejsijni
    ReactAndroid::react_nativemodule_core
  )
endif()

target_compile_options(
  ${CMAKE_PROJECT_NAME}
  PRIVATE
  -fexceptions
  -frtti
  -O2
  -DONANDROID
)
