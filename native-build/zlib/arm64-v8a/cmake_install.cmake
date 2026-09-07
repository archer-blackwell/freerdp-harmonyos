# Install script for directory: E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-src/zlib-1.3.1

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib")
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

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  foreach(file
      "$ENV{DESTDIR}/E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1.3.1"
      "$ENV{DESTDIR}/E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      file(RPATH_CHECK
           FILE "${file}"
           RPATH "")
    endif()
  endforeach()
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1.3.1;E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib" TYPE SHARED_LIBRARY FILES
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/libz.so.1.3.1"
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/libz.so.1"
    )
  foreach(file
      "$ENV{DESTDIR}/E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1.3.1"
      "$ENV{DESTDIR}/E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so.1"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "E:/HarmonyOs/DevelopTools/huawei/devecostudio/application/DevEco Studio/sdk/default/openharmony/native/llvm/bin/llvm-strip.exe" "${file}")
      endif()
    endif()
  endforeach()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.so")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib" TYPE SHARED_LIBRARY FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/libz.so")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib/libz.a")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/lib" TYPE STATIC_LIBRARY FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/libz.a")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/include/zconf.h;E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/include/zlib.h")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/include" TYPE FILE FILES
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/zconf.h"
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-src/zlib-1.3.1/zlib.h"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/share/man/man3/zlib.3")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/share/man/man3" TYPE FILE FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-src/zlib-1.3.1/zlib.3")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/share/pkgconfig/zlib.pc")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-install/deps/arm64-v8a/zlib/share/pkgconfig" TYPE FILE FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/zlib.pc")
endif()

if(CMAKE_INSTALL_COMPONENT)
  set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
file(WRITE "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/zlib/arm64-v8a/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
