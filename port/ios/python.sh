#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 the OpenRAC contributors
#
# Puts Python and the disc's setup scripts into an iOS build's application bundle
# (cmake/IOS.cmake runs it after every link, before ios/sign.sh):
#
#   python.sh <bundle.app> <Python.xcframework> <slice> <repo> <bundle id> <game> <version>
#
# The game sets the player's disc up itself on its first start (game/common/program/ios_setup.mm),
# with the extractor's own scripts in the Python linked into it: BeeWare's Python-Apple-support
# (Python.xcframework, PSF licence). The bundle gets
#
#   Frameworks/Python.framework             the interpreter, which the game links
#   Frameworks/<module>.framework           each of the standard library's extension modules: iOS
#                                           loads code from frameworks only, so each .so is moved
#                                           into one and a .fwork file left where it was, which
#                                           the interpreter follows (what the framework's own
#                                           build/utils.sh does for an Xcode project)
#   python/lib/python3.x                    the standard library, without its tests and the
#                                           modules no phone runs (Tk, IDLE, pip's installer)
#   python/openrac                          tools/extractor.py, tools/openrac_common and editor/,
#                                           with the files of the repository they read
#                                           (games/*/game.json, the game's lighting profiles)
#                                           and the STANDALONE note that marks their root
#
# The frameworks are signed by sign.sh with the program.
set -eu

bundle=$1
xcframework=$2
slice=$3
repo=$4
bundle_id=$5
game=$6
version=$7

slice_dir="$xcframework/$slice"
if [ ! -d "$slice_dir/Python.framework" ]; then
  echo "python.sh: $xcframework has no $slice slice" >&2
  exit 1
fi

frameworks="$bundle/Frameworks"
lib="$bundle/python/lib"
mkdir -p "$frameworks"
rm -rf "$frameworks/Python.framework" "$bundle/python"
for old in "$frameworks"/*.framework; do
  # The extension modules' frameworks of an earlier run (each has an .origin file).
  if ls "$old"/*.origin >/dev/null 2>&1; then rm -rf "$old"; fi
done

# The interpreter, without the headers the game was compiled with.
rsync -a --exclude Headers "$slice_dir/Python.framework" "$frameworks/"

# The standard library: the common part, then the slice's (its sysconfig data, lib-dynload).
mkdir -p "$lib"
rsync -a --exclude 'libpython*.dylib' --exclude __pycache__ \
  --exclude test --exclude tests --exclude idlelib --exclude tkinter --exclude turtledemo \
  --exclude ensurepip --exclude pydoc_data --exclude '*.exe' \
  "$xcframework/lib/" "$lib/"
for arch_lib in "$slice_dir"/lib-*; do
  rsync -a --exclude 'libpython*.dylib' "$arch_lib/" "$lib/"
  break  # one architecture: the device's arm64, or the simulator's first (arm64)
done
stdlib=$(ls -d "$lib"/python3.* | head -n 1)
python_ver=$(basename "$stdlib")

# Each extension module as a framework.
dylib_plist="$xcframework/build/iOS-dylib-Info-template.plist"
find "$stdlib/lib-dynload" -name '*.so' | while read -r so; do
  name=$(basename "$so" | cut -d . -f 1)
  folder="Frameworks/$name.framework"
  mkdir -p "$bundle/$folder"
  cp "$dylib_plist" "$bundle/$folder/Info.plist"
  plutil -replace CFBundleExecutable -string "$name" "$bundle/$folder/Info.plist"
  plutil -replace CFBundleIdentifier -string "$(echo "$bundle_id.$name" | tr _ -)" "$bundle/$folder/Info.plist"
  mv "$so" "$bundle/$folder/$name"
  echo "$folder/$name" > "${so%.so}.fwork"
  echo "python/lib/$python_ver/lib-dynload/$(basename "${so%.so}").fwork" > "$bundle/$folder/$name.origin"
done

# OpenRAC's scripts, at their places in the repository: the scripts find the repository's files
# from their own (paths.repo_root, games.py, mobys.py).
scripts="$bundle/python/openrac"
mkdir -p "$scripts/tools" "$scripts/editor" "$scripts/games" "$scripts/port/enhanced/lighting/profiles"
cp "$repo/tools/extractor.py" "$scripts/tools/"
rsync -a --exclude __pycache__ --exclude 'test_*' "$repo/tools/openrac_common" "$scripts/tools/"
rsync -a --exclude __pycache__ --exclude 'test_*' \
  --include '*/' --include '*.py' --include '*.tsv' --include '*.json' --exclude '*' \
  --prune-empty-dirs "$repo/editor/" "$scripts/editor/"
# The note that makes the folder a copy of OpenRAC's tools (openrac_common/paths.py repo_root), as
# a desktop's standalone copy has (tools/bundle_standalone.py).
printf 'OpenRAC: the setup scripts of an iOS app (port/ios/python.sh), for %s %s.\n' "$game" "$version" \
  > "$scripts/STANDALONE"
for catalogue in "$repo"/games/*/game.json; do
  mkdir -p "$scripts/games/$(basename "$(dirname "$catalogue")")"
  cp "$catalogue" "$scripts/games/$(basename "$(dirname "$catalogue")")/"
done
for profile in "$game" "$game-$version"; do
  if [ -d "$repo/port/enhanced/lighting/profiles/$profile" ]; then
    rsync -a "$repo/port/enhanced/lighting/profiles/$profile" "$scripts/port/enhanced/lighting/profiles/"
  fi
done

# Compiled ahead, when this Mac's Python makes the same bytecode (the same 3.x): the bundle is
# read only, so the phone could not keep what it compiles. Hashes, not times, say whether a
# compiled file is current, since copying the bundle changes its files' times.
host_ver=$(python3 -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)
if [ "$host_ver" = "$python_ver" ]; then
  python3 -m compileall -q -j 0 --invalidation-mode unchecked-hash "$stdlib" "$scripts" >/dev/null || true
fi
