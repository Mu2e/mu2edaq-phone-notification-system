# mu2edaq-phone-notification-system: C++ publisher library.
#
# Builds on Linux, macOS, and Windows 11 (MSVC). The Python server and
# publisher live under src/mu2edaq_notify and are installed with pip
# (see bootstrap.sh); this CMake project covers the C++ side only.
#
#   cmake -S . -B build
#   cmake --build build
#   ctest --test-dir build        # CppUnit tests (skipped if CppUnit absent)

cmake_minimum_required(VERSION 3.16)
project(mu2edaq_notify VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(CURL REQUIRED)

add_library(mu2edaq_notify src/cpp/notify.cpp)
add_library(mu2edaq::notify ALIAS mu2edaq_notify)
target_include_directories(mu2edaq_notify PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src/include>
    $<INSTALL_INTERFACE:include>)
target_link_libraries(mu2edaq_notify PUBLIC CURL::libcurl)
if(WIN32)
    target_link_libraries(mu2edaq_notify PUBLIC ws2_32)
endif()

add_executable(publish_example src/cpp/examples/publish_example.cpp)
target_link_libraries(publish_example PRIVATE mu2edaq_notify)

# Tests -------------------------------------------------------------------
include(CTest)
if(BUILD_TESTING)
    find_library(CPPUNIT_LIBRARY cppunit)
    find_path(CPPUNIT_INCLUDE_DIR cppunit/TestFixture.h)
    if(CPPUNIT_LIBRARY AND CPPUNIT_INCLUDE_DIR)
        add_executable(test_notify src/cpp/tests/test_notify.cpp)
        target_include_directories(test_notify PRIVATE ${CPPUNIT_INCLUDE_DIR})
        target_link_libraries(test_notify PRIVATE mu2edaq_notify
                              ${CPPUNIT_LIBRARY})
        add_test(NAME notify_cpp COMMAND test_notify)
    else()
        message(STATUS "CppUnit not found; C++ unit tests disabled")
    endif()
endif()

# Install -------------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS mu2edaq_notify publish_example
        EXPORT mu2edaq_notify-targets
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY src/include/mu2edaq_notify
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT mu2edaq_notify-targets
        NAMESPACE mu2edaq::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/mu2edaq_notify)
install(FILES man/mu2edaq-notify.1 man/mu2edaq-notify-server.1
        DESTINATION ${CMAKE_INSTALL_MANDIR}/man1 OPTIONAL)
install(FILES man/mu2edaq_notify.3 man/mu2edaq_notify_cpp.3
        DESTINATION ${CMAKE_INSTALL_MANDIR}/man3 OPTIONAL)
