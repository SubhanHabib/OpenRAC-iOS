# iPhone and iPad

OpenRAC runs on iPhones and iPads with:

- a 64-bit Apple GPU with Metal (every device iOS 17 runs on),
- iOS or iPadOS 17 or newer.

There is no emulation. The app holds the same translated game code as the
desktop build, compiled with Xcode's iOS SDK, and the game data comes from
your own disc. It draws with the Vulkan renderer on Metal
through [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0),
linked into the program.

## At a glance

- One app per game: `OpenRAC.app`, with the game's name and icon on the home
  screen.
- The released app (`OpenRAC_rac1-ntsc_<version>_ios.ipa`) has nothing of
  the game in it: on its first start it asks for your disc image and sets
  it up on the device (below). Ratchet & Clank (NTSC) only for now.
- A build of your own can instead take a data folder set up on a Mac
  (`tools/build_ios.py --data`, or the Files app / the Finder).
- Held sideways, full screen; the touch pad appears when you touch the
  screen, and a controller (MFi, Xbox, DualShock 4, DualSense) works
  everywhere.
- Saves, settings and logs are in the app's Documents folder, which the
  Files app shows under On My iPhone → OpenRAC.
- On the simulator, a Mac's GPU holds 60 frames a second in the levels.

## Installing the released app

iOS installs only apps signed for the device. The release's `.ipa` is
signed by nobody in particular; a sideloading tool signs it again with your
own Apple ID (a free one works) and installs it:

- [AltStore](https://altstore.io) or [SideStore](https://sidestore.io):
  open the `.ipa` with it (the share sheet, or the tool's My Apps → +).
- [Sideloadly](https://sideloadly.io), from a Mac or a PC with the device on
  the cable.

A free Apple ID's apps run for seven days, after which the tool signs them
again (AltStore and SideStore do it on their own; with Sideloadly, install
again). Saves and the data folder stay. The device must be in Developer
Mode (Settings → Privacy & Security, after the first install).

## Setting up your disc on the device

The first start shows the setup screen. It needs your own disc image of
Ratchet & Clank (NTSC, SCUS-97199) as a `.iso` (the one the desktop launcher
takes; `baserom/README.md` says how to make one):

1. Put the `.iso` in Files → On My iPhone → Ratchet & Clank (NTSC), or
   copy it there from a computer (the Finder's device window, Files tab; on
   Windows, the Apple Devices app). The screen then offers it. "Choose disc
   image…" opens one from anywhere in Files instead (iCloud Drive, a USB
   drive), which is copied in.
2. The app checks the disc against `games/rac1/game.json`, as the desktop
   extractor does, and refuses another game or version.
3. It reads the boot files and makes the 21 levels: 15 to 30 minutes. Keep
   the app on the screen (it keeps the screen on); if it goes to the
   background it carries on when it is back.

About 5 GB is used: the disc image (4.2 GB, kept: the game reads it) and the
levels (0.9 GB). A `.iso` put in the app's folder is linked, not copied, so
it takes no more space; delete one chosen from elsewhere afterwards if you
like. `Documents/data/setup.log` has the scripts' output.

How it works: the app carries Python (BeeWare's
[Python-Apple-support](https://github.com/beeware/Python-Apple-support),
PSF licence) and the desktop's own scripts, `tools/extractor.py
--extract --boot-only` and `editor/extract.py port` (the desktop launcher's
two setup steps), and runs them in the game's process before the game
starts (`game/common/program/ios_setup.mm`). An app may not start
programs, so the levels are made one at a time on a thread
(`editor/extract.py worker_pool`).

## Building

On a Mac with Xcode (with the iOS platform), CMake 3.28+ and Ninja:

```bash
python3 tools/build_ios.py rac1-ntsc --disc baserom/SCUS_971.99.iso --install --data ~/openrac-data --launch
```

builds for the simulator, installs on the booted one, copies the data
folder into it and starts the game with its log in the terminal. With
`--device`, the same for an iPhone or iPad on the cable or the network:

```bash
python3 tools/build_ios.py rac1-ntsc --device --disc baserom/SCUS_971.99.iso --install --data ~/openrac-data
```

A device build is signed with your Apple Development identity and a
provisioning profile that names the device. The script picks the newest
profile in Xcode's folders whose application identifier covers
`dev.openrac.<game>` (a team's wildcard profile does) and whose certificate
is in your keychain; `--identity` and `--profile` choose them instead, and
`--bundle-id` another identifier. A free Apple ID works: make any app for
the device in Xcode once and its profile is there (its apps expire after
seven days). The device must be in Developer Mode.

`--setup` adds Python and the setup screen (downloading Python-Apple-support,
a fixed release checked against its SHA-256). `--ipa FILE` makes the
release's app: `--device`, no disc, `--setup`, signed ad hoc (unless
`--identity` and `--profile` are given) and packed as an `.ipa`:

```bash
python3 tools/build_ios.py rac1-ntsc --device --ipa build/ios/OpenRAC.ipa
```

The `ios-release` workflow (`.github/workflows/ios-release.yml`) builds it,
and a tag `v*` puts it on a draft release.

What the script runs, by hand:

```bash
cd port
export OPENRAC_MOLTENVK_XCFRAMEWORK=/path/to/MoltenVK/MoltenVK/static/MoltenVK.xcframework
cmake --preset ios-simulator -DPython3_EXECUTABLE=$(command -v python3)
cmake --build build/ios-simulator --target openrac-rac1-ntsc
xcrun simctl install booted build/ios-simulator/apps/openrac-rac1-ntsc/OpenRAC.app
```

`ios-device` is the device's preset; it takes `OPENRAC_IOS_SIGN_IDENTITY`
and `OPENRAC_IOS_PROFILE`. `OPENRAC_IOS_PYTHON_XCFRAMEWORK` (the
`Python.xcframework` of Python-Apple-support's iOS package) adds the setup
on the device: `port/ios/python.sh` puts Python's standard library, its
extension modules as frameworks (iOS loads code only from frameworks) and
the setup's scripts into the bundle, and `port/ios/sign.sh` signs the
frameworks with the program.

## The data folder

The game reads what the extractor makes, as on a desktop
(`tools/extractor.py --extract --boot-only`, then the levels with
`editor/extract.py port`), from the app's `Documents/data`:

```
Documents/
  data/
    iso_data/rac1/      SYSTEM.CNF, SCUS_971.99, disc.iso
    port/ntsc/          level_00 ... level_xx
    openrac-<game>.log  this run's log, and the last five (made by the game)
    crashes/            crash reports (made by the game)
  args.txt              more arguments, one a line (optional)
  data.aar              entries for data/, unpacked at the next start (optional)
  OpenRAC/              memory cards, settings, controls (made by the game)
  screenshots/
```

The desktop launcher's game folder has this layout already: copy its data
folder.

A device takes files one at a time, a few a second over the network, and
`port/` is thousands of small ones. `Documents/data.aar`, an Apple Archive of
data folder entries, is unpacked into `Documents/data` when the game starts
and then deleted: `build_ios.py --device --data` sends the levels that way
(about 230 MB for Ratchet & Clank, against 16,000 files), and by hand

```bash
aa archive -d ~/openrac-data -include-path port -exclude-field uid,gid,flg,xat,acl -o data.aar
```

makes one to drop into the app's folder in the Finder (the device's Files
tab) or the Files app. `args.txt` takes the desktop's command-line arguments, one a line
(`--level 3`, `--no-mods`), `#` for a comment, and `env NAME=value` sets a
variable before the game reads them (`env OPENRAC_OVERLAY=1`); see
[DEBUGGING.md](DEBUGGING.md).

## How it is done

- **Build.** `cmake --preset ios-simulator` or `ios-device` cross-compiles
  the port (`CMAKE_SYSTEM_NAME=iOS`, arm64, iOS 17); hostgen still runs on
  the Mac. `port/cmake/IOS.cmake` defines `OPENRAC_IOS` for every source,
  links MoltenVK's static library into the game and makes the application
  bundle: its Info.plist, the icon at each size from the game's PNG (`sips`),
  and the signature after each link (`port/ios/sign.sh`: ad hoc for the
  simulator, with no entitlements, since the Mac will not start an ad hoc
  program that claims any; for a device, the profile embedded and its
  entitlements with the bundle's identifier).
- **Start.** SDL3 (static) runs UIKit's application and calls the game's
  `main` as `SDL_main`. iOS gives an app no command line, so
  `game/common/program/ios_launch.cpp` makes one: the arguments given (a
  simulator's `simctl launch ... -- --level 3`), then `Documents/args.txt`,
  then `--data Documents/data` and `--window` where they are not given.
  Before that it unpacks `Documents/data.aar` (AppleArchive, on a thread
  while the main one keeps serving UIKit, which stops an app whose launch
  holds it for long).
- **Graphics.** The renderer's Vulkan backend, on MoltenVK. An iOS app opens
  no library of its own, so MoltenVK is in the program; SDL finds its
  `vkGetInstanceProcAddr` there (`SDL_Vulkan_LoadLibrary(nullptr)`,
  `platform/window.cpp`). MoltenVK defines every `vk*` function and volk a
  pointer of each name, so the library is first linked into one object
  (`ld -r`) whose only global is `vkGetInstanceProcAddr`, and volk's pointer
  of that name is renamed (`cmake/Dependencies.cmake`). The device is asked
  for `VK_KHR_portability_subset`, as on a Mac.
- **Game memory.** The 4 GB reservation fits in an app's address space
  (64 GB on a current device) without `extended-virtual-addressing`. iOS has
  no shared memory objects (`shm_open` is denied in the sandbox), so the RAM's
  uncached views are made with `vm_remap` of the RAM's pages instead
  (`runtime/memory.cpp`): the same pages at each address, as on the desktops.
- **The phone's behaviour.** Where Android has the touch screen's behaviour,
  iOS takes it (`OPENRAC_IOS` beside `__ANDROID__`): always full screen, the
  drawer and touch pad, the debug overlay's scale, leaving with `_Exit`.
  The home indicator is hidden until swiped.
- **Leaving the screen.** An app in the background may not use the GPU.
  When the app leaves the screen (the home screen, the app switcher,
  Control Center) the game's next read of its events waits until it is back
  (`platform/pump.cpp`), then the Vulkan surface is made again. SDL gives
  those events to its event watchers only and never queues them, so the
  pump watches for them and hands them to the game in order afterwards.
- **Files.** `data_home()` is `Documents/OpenRAC`; screenshots and
  performance captures go to `Documents`. Show folder opens the Files app
  (`shareddocuments://`).

## Not done yet

- Going Commando and the other games: their setup builds code from the
  disc with a compiler (zig's clang, as on Android), which an iOS app cannot
  run.
- A Metal backend of its own: MoltenVK translates the Vulkan backend's
  calls to Metal as they are made, which costs some CPU time per draw. The
  Vulkan backend (`port/renderer`, about 21,000 lines with its shaders) is
  what such a backend would replace; MoltenVK keeps one renderer for every
  platform until the translation's cost shows on a device.
