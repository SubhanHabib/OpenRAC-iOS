# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 the OpenRAC contributors
#
# What an iOS build adds (docs/port/IOS.md); included from port/CMakeLists.txt when CMake
# targets iOS (the ios-simulator and ios-device presets). Nothing here touches another build.
#
#   OPENRAC_IOS               defined for every source: the phone's behaviour where Android's is
#                             the touch screen's, and Apple's otherwise
#   openrac_moltenvk_static   MoltenVK (Apache-2.0), Vulkan on Metal, linked into the game: an
#                             iOS app opens no library of its own, so SDL and volk find
#                             vkGetInstanceProcAddr in the program itself
#   openrac_ios_app()         a game as an application bundle with its Info.plist and icons,
#                             signed for the simulator (ad hoc) or a device (OPENRAC_IOS_SIGN_IDENTITY)
#   OPENRAC_IOS_PYTHON_XCFRAMEWORK
#                             Python in the game, which then sets the player's disc up on its first
#                             start (program/ios_setup.mm): a build without the disc that anyone
#                             can install and give their own

include_guard(GLOBAL)

set(OPENRAC_IOS ON)
add_compile_definitions(OPENRAC_IOS=1)

if(NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
  message(FATAL_ERROR "OpenRAC's iOS build is arm64 only (game memory is a 4 GB reservation)")
endif()
if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
  set(OPENRAC_IOS_SIMULATOR ON)
else()
  set(OPENRAC_IOS_SIMULATOR OFF)
endif()

# ---- MoltenVK ----
# The static library from the release's MoltenVK.xcframework (MoltenVK-all.tar, or MoltenVK-ios.tar
# for a device only): the slice for the simulator or the device.
set(OPENRAC_MOLTENVK_XCFRAMEWORK "" CACHE PATH "MoltenVK's static MoltenVK.xcframework")
if(NOT OPENRAC_MOLTENVK_XCFRAMEWORK)
  message(FATAL_ERROR "Set OPENRAC_MOLTENVK_XCFRAMEWORK to MoltenVK's static MoltenVK.xcframework "
                      "(https://github.com/KhronosGroup/MoltenVK/releases, MoltenVK-all.tar)")
endif()
if(OPENRAC_IOS_SIMULATOR)
  file(GLOB openrac_moltenvk_slice "${OPENRAC_MOLTENVK_XCFRAMEWORK}/ios-*-simulator/libMoltenVK.a")
else()
  set(openrac_moltenvk_slice "${OPENRAC_MOLTENVK_XCFRAMEWORK}/ios-arm64/libMoltenVK.a")
endif()
if(NOT EXISTS "${openrac_moltenvk_slice}")
  message(FATAL_ERROR "${OPENRAC_MOLTENVK_XCFRAMEWORK} has no iOS ${CMAKE_OSX_SYSROOT} slice")
endif()
message(STATUS "MoltenVK: ${openrac_moltenvk_slice}")
# The library is linked as one object whose only global is vkGetInstanceProcAddr (ld -r, the rest
# made local): MoltenVK defines every vk* function, and volk the same names as its function
# pointers, which the linker would otherwise take for one another.
if(OPENRAC_IOS_SIMULATOR)
  set(openrac_moltenvk_target "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}-simulator")
else()
  set(openrac_moltenvk_target "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()
set(openrac_moltenvk_sysroot "")
if(_CMAKE_OSX_SYSROOT_PATH)
  set(openrac_moltenvk_sysroot -isysroot "${_CMAKE_OSX_SYSROOT_PATH}")
endif()
set(openrac_moltenvk_object "${CMAKE_BINARY_DIR}/moltenvk/MoltenVK.o")
add_custom_command(
  OUTPUT "${openrac_moltenvk_object}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/moltenvk"
  COMMAND "${CMAKE_CXX_COMPILER}" -r -nostdlib -target ${openrac_moltenvk_target} ${openrac_moltenvk_sysroot}
          -Wl,-all_load "${openrac_moltenvk_slice}" -Wl,-exported_symbol,_vkGetInstanceProcAddr
          -o "${openrac_moltenvk_object}"
  DEPENDS "${openrac_moltenvk_slice}"
  COMMENT "MoltenVK as one object"
  VERBATIM)
add_custom_target(openrac_moltenvk_object DEPENDS "${openrac_moltenvk_object}")
add_library(openrac_moltenvk_static INTERFACE)
add_dependencies(openrac_moltenvk_static openrac_moltenvk_object)
target_link_libraries(openrac_moltenvk_static INTERFACE
  "${openrac_moltenvk_object}"
  "-framework Metal" "-framework QuartzCore" "-framework IOSurface" "-framework UIKit"
  "-framework Foundation" "-framework CoreGraphics")

# ---- the application bundle ----
#   openrac_ios_app(openrac-rac1-ntsc NAME "Ratchet & Clank (NTSC)" ID dev.openrac.rac1-ntsc ICON <png>)
#
# builds the target as <build>/apps/<target>/OpenRAC.app: the program OpenRAC, Info.plist (a game
# held sideways, full screen, with its Documents folder shown in the Files app, where the player
# puts the data folder, and a ProMotion screen's 120 Hz), the icon in each size the home screen
# asks for, and the signature.
set(OPENRAC_IOS_SIGN_IDENTITY "" CACHE STRING
    "Code signing identity for a device build (security find-identity -v -p codesigning); empty: ad hoc")
set(OPENRAC_IOS_PROFILE "" CACHE FILEPATH "Provisioning profile embedded in a device build")
set(OPENRAC_IOS_BUNDLE_ID "" CACHE STRING "Bundle identifier, when the profile names another than dev.openrac.<id>")
# BeeWare's Python-Apple-support (https://github.com/beeware/Python-Apple-support, PSF licence):
# its Python.xcframework, which tools/build_ios.py --python downloads. Empty: no setup on the
# device, the data folder made on a Mac.
set(OPENRAC_IOS_PYTHON_XCFRAMEWORK "" CACHE PATH "Python-Apple-support's Python.xcframework (setup on the device)")
if(OPENRAC_IOS_PYTHON_XCFRAMEWORK)
  if(OPENRAC_IOS_SIMULATOR)
    file(GLOB openrac_python_slice LIST_DIRECTORIES true "${OPENRAC_IOS_PYTHON_XCFRAMEWORK}/ios-*-simulator")
  else()
    set(openrac_python_slice "${OPENRAC_IOS_PYTHON_XCFRAMEWORK}/ios-arm64")
  endif()
  if(NOT EXISTS "${openrac_python_slice}/Python.framework")
    message(FATAL_ERROR "${OPENRAC_IOS_PYTHON_XCFRAMEWORK} has no iOS ${CMAKE_OSX_SYSROOT} slice")
  endif()
  get_filename_component(openrac_python_slice_name "${openrac_python_slice}" NAME)
  message(STATUS "Python for the setup on the device: ${openrac_python_slice}")
endif()

function(openrac_ios_app target)
  cmake_parse_arguments(PARSE_ARGV 1 app "" "NAME;ID;ICON;GAME;VERSION" "")
  set(bundle_id "${app_ID}")
  if(OPENRAC_IOS_BUNDLE_ID)
    set(bundle_id "${OPENRAC_IOS_BUNDLE_ID}")
  endif()
  set(bundle_dir "${CMAKE_BINARY_DIR}/apps/${target}")
  set(bundle "${bundle_dir}/OpenRAC.app")
  string(REPLACE "&" "&amp;" name "${app_NAME}")
  string(REPLACE "<" "&lt;" name "${name}")
  if(OPENRAC_IOS_SIMULATOR)
    set(platform "iPhoneSimulator")
  else()
    set(platform "iPhoneOS")
  endif()
  set(plist "${CMAKE_CURRENT_BINARY_DIR}/generated/${target}-Info.plist")
  file(CONFIGURE OUTPUT "${plist}" CONTENT [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>OpenRAC</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>OpenRAC</string>
	<key>CFBundleDisplayName</key>
	<string>${name}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>${platform}</string>
	</array>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
			</array>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
				<string>AppIcon76x76</string>
				<string>AppIcon83.5x83.5</string>
			</array>
		</dict>
	</dict>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>MinimumOSVersion</key>
	<string>${CMAKE_OSX_DEPLOYMENT_TARGET}</string>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
		<string>metal</string>
	</array>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UIRequiresFullScreen</key>
	<true/>
	<key>UIStatusBarHidden</key>
	<true/>
	<key>UIViewControllerBasedStatusBarAppearance</key>
	<false/>
	<key>UILaunchScreen</key>
	<dict>
		<key>UIColorName</key>
		<string></string>
	</dict>
	<key>UIApplicationSupportsIndirectInputEvents</key>
	<true/>
	<key>UIFileSharingEnabled</key>
	<true/>
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>GCSupportsControllerUserInteraction</key>
	<true/>
	<key>GCSupportedGameControllers</key>
	<array>
		<dict>
			<key>ProfileName</key>
			<string>ExtendedGamepad</string>
		</dict>
	</array>
	<key>GCSupportsGameMode</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Bluetooth finds the game controllers that do not pair with the iPhone itself (a Steam Controller).</string>
	<key>CADisableMinimumFrameDurationOnPhone</key>
	<true/>
</dict>
</plist>
]])
  set_target_properties(${target} PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${plist}"
    OUTPUT_NAME "OpenRAC"
    RUNTIME_OUTPUT_DIRECTORY "${bundle_dir}")
  # The bundle's Info.plist is copied by CMake as a template; nothing in it is left for it to fill.
  set_property(TARGET ${target} APPEND PROPERTY LINK_OPTIONS
    # SDL's and MoltenVK's Objective-C categories, which nothing names. (The game's memory, a
    # 4 GB reservation, fits in an app's address space without extended-virtual-addressing.)
    "-ObjC")
  # AppleArchive: Documents/data.aar, unpacked at the start (ios_launch.cpp).
  target_link_libraries(${target} PRIVATE openrac_moltenvk_static AppleArchive)
  add_dependencies(${target} openrac_moltenvk_object)

  # The icons: the home screen's sizes from the game's PNG (sips, which every Mac has).
  set(icons "")
  set(resize "")
  foreach(pair IN ITEMS "AppIcon60x60@2x.png:120" "AppIcon60x60@3x.png:180" "AppIcon76x76@2x.png:152"
                        "AppIcon83.5x83.5@2x.png:167" "AppIcon1024.png:1024")
    string(REPLACE ":" ";" pair "${pair}")
    list(GET pair 0 file)
    list(GET pair 1 size)
    list(APPEND icons "${bundle}/${file}")
    list(APPEND resize COMMAND sips -s format png -z ${size} ${size} "${app_ICON}" --out "${bundle}/${file}")
  endforeach()
  add_custom_command(
    OUTPUT ${icons}
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${bundle}"
    ${resize}
    DEPENDS "${app_ICON}"
    COMMENT "iOS icons for ${target}"
    VERBATIM)
  add_custom_target(${target}_icon DEPENDS ${icons})
  add_dependencies(${target} ${target}_icon)
  # The signature seals the icons and Info.plist: new ones link the program again, and so sign it again.
  set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS ${icons} "${plist}")

  # The setup on the device: Python linked in and put into the bundle with the scripts it runs
  # (ios/python.sh), before the signature.
  if(OPENRAC_IOS_PYTHON_XCFRAMEWORK)
    target_sources(${target} PRIVATE "${OPENRAC_GAME_DIR}/common/program/ios_setup.mm")
    target_compile_definitions(${target} PRIVATE OPENRAC_IOS_SETUP=1
      "OPENRAC_IOS_GAME=\"${app_GAME}\"" "OPENRAC_IOS_VERSION=\"${app_VERSION}\"")
    target_include_directories(${target} PRIVATE "${openrac_python_slice}/Python.framework/Headers")
    target_link_options(${target} PRIVATE "-F${openrac_python_slice}" "-Wl,-rpath,@executable_path/Frameworks")
    target_link_libraries(${target} PRIVATE "-framework Python" "-framework UniformTypeIdentifiers")
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND sh "${PROJECT_SOURCE_DIR}/ios/python.sh" "${bundle}" "${OPENRAC_IOS_PYTHON_XCFRAMEWORK}"
              "${openrac_python_slice_name}" "${PROJECT_SOURCE_DIR}/.." "${bundle_id}" "${app_GAME}" "${app_VERSION}"
      COMMENT "Python and the setup's scripts into ${bundle}"
      VERBATIM)
    # A new script, or a change to one, links the program again: what puts them in the bundle and
    # signs it runs after a link.
    file(GLOB_RECURSE setup_scripts CONFIGURE_DEPENDS "${PROJECT_SOURCE_DIR}/../editor/*.py"
         "${PROJECT_SOURCE_DIR}/../tools/openrac_common/*.py")
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${PROJECT_SOURCE_DIR}/ios/python.sh"
                 "${PROJECT_SOURCE_DIR}/../tools/extractor.py" ${setup_scripts})
  endif()

  # Signed after every link (ios/sign.sh): ad hoc for the simulator; for a device with the identity
  # and the provisioning profile, whose entitlements the signature takes.
  set(identity "-")
  if(OPENRAC_IOS_SIGN_IDENTITY AND NOT OPENRAC_IOS_SIMULATOR)
    set(identity "${OPENRAC_IOS_SIGN_IDENTITY}")
  endif()
  set(profile "-")
  if(OPENRAC_IOS_PROFILE AND NOT OPENRAC_IOS_SIMULATOR)
    set(profile "${OPENRAC_IOS_PROFILE}")
  endif()
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND sh "${PROJECT_SOURCE_DIR}/ios/sign.sh" "${bundle}" "${identity}" "${profile}" "${bundle_id}"
    COMMENT "Signing ${bundle}"
    VERBATIM)
endfunction()
