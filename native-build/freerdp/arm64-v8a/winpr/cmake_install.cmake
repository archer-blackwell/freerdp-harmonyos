# Install script for directory: E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/entry/libs/FreeRDP-3.10.3/winpr

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

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3" TYPE FILE FILES
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/WinPRConfig.cmake"
    "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/WinPRConfigVersion.cmake"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3/WinPRTargets.cmake")
    file(DIFFERENT _cmake_export_file_changed FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3/WinPRTargets.cmake"
         "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/CMakeFiles/Export/ce6e391bd0ea3bd91a2228a2e6f384f9/WinPRTargets.cmake")
    if(_cmake_export_file_changed)
      file(GLOB _cmake_old_config_files "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3/WinPRTargets-*.cmake")
      if(_cmake_old_config_files)
        string(REPLACE ";" ", " _cmake_old_config_files_text "${_cmake_old_config_files}")
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3/WinPRTargets.cmake\" will be replaced.  Removing files [${_cmake_old_config_files_text}].")
        unset(_cmake_old_config_files_text)
        file(REMOVE ${_cmake_old_config_files})
      endif()
      unset(_cmake_old_config_files)
    endif()
    unset(_cmake_export_file_changed)
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3" TYPE FILE FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/CMakeFiles/Export/ce6e391bd0ea3bd91a2228a2e6f384f9/WinPRTargets.cmake")
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/WinPR3" TYPE FILE FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/CMakeFiles/Export/ce6e391bd0ea3bd91a2228a2e6f384f9/WinPRTargets-release.cmake")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/winpr3.pc")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/libwinpr/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/tools/cmake_install.cmake")
  include("E:/HarmonyOs/Worker/ProjectFiles/freerdp-harmonyos/native-build/freerdp/arm64-v8a/winpr/include/cmake_install.cmake")

endif()

