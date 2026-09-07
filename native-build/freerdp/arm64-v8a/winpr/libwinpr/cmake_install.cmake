# Install script for directory: E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/entry/libs/FreeRDP-3.10.3/winpr/libwinpr

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/freerdp/arm64-v8a")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "E:/HarmonyOs/DevelopTools/huawei/devecostudio/application/DevEco Studio/sdk/default/openharmony/native/llvm/bin/llvm-objdump.exe")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "libraries" OR NOT CMAKE_INSTALL_COMPONENT)
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libwinpr3.so.3.10.3"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libwinpr3.so.3"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHECK
           FILE "${file}"
           RPATH "$ORIGIN/../lib:$ORIGIN/..")
    endif()
  endforeach()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/libwinpr3.so.3.10.3"
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/libwinpr3.so.3"
    )
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libwinpr3.so.3.10.3"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libwinpr3.so.3"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHANGE
           FILE "${file}"
           OLD_RPATH ":::::::::::::::::::::::::"
           NEW_RPATH "$ORIGIN/../lib:$ORIGIN/..")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "E:/HarmonyOs/DevelopTools/huawei/devecostudio/application/DevEco Studio/sdk/default/openharmony/native/llvm/bin/llvm-strip.exe" "${file}")
      endif()
    endif()
  endforeach()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "libraries" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/libwinpr3.so")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/synch/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/library/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/file/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/comm/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/pipe/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/interlocked/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/security/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/environment/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/crypto/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/registry/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/path/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/io/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/memory/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/ncrypt/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/input/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/shell/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/utils/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/error/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/timezone/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/sysinfo/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/pool/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/handle/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/thread/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/winsock/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/sspi/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/sspicli/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/crt/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/bcrypt/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/rpc/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/wtsapi/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/dsparse/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/smartcard/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/nt/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/clipboard/cmake_install.cmake")

endif()

