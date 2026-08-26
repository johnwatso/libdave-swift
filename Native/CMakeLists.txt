cmake_minimum_required(VERSION 3.30)

project(libdave_swift_native LANGUAGES C CXX)

if(NOT DEFINED DAVE_SOURCE_DIR)
  message(FATAL_ERROR "DAVE_SOURCE_DIR must point to the pinned discord/libdave checkout")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(TESTING OFF CACHE BOOL "" FORCE)
set(PERSISTENT_KEYS ON CACHE BOOL "" FORCE)
set(PERSISTENT_KEYS_GENERIC ON CACHE BOOL "" FORCE)
set(INSTALL_VCPKG_LICENSES ON CACHE BOOL "" FORCE)

find_package(MLSPP CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)

add_subdirectory("${DAVE_SOURCE_DIR}/cpp" libdave-build)

# A test-only Discord external-sender simulator. It stays outside the shipped
# XCFramework and supplies live, internally consistent MLS artifacts to the
# Swift end-to-end test over a line-oriented stdin/stdout protocol.
add_executable(
  dave_external_sender_helper
  "${CMAKE_CURRENT_SOURCE_DIR}/Integration/dave_external_sender_helper.cpp"
  "${DAVE_SOURCE_DIR}/cpp/test/external_sender.cpp"
)
target_include_directories(
  dave_external_sender_helper
  PRIVATE
    "${DAVE_SOURCE_DIR}/cpp/includes"
    "${DAVE_SOURCE_DIR}/cpp/src"
    "${DAVE_SOURCE_DIR}/cpp/test"
)
target_link_libraries(
  dave_external_sender_helper
  PRIVATE
    libdave
    MLSPP::bytes
    MLSPP::mlspp
    OpenSSL::Crypto
)
set_target_properties(
  dave_external_sender_helper
  PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/integration"
)
