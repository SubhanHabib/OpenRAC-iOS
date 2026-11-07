#!/usr/bin/env python3
"""
Builds OpenRAC for iPhone and iPad (docs/port/IOS.md): a game as an
application bundle, for the simulator or a device, and puts it there with its
data.

  python3 tools/build_ios.py [GAME] [--device | --simulator] [--disc IMAGE]
                             [--install] [--data DIR] [--launch] [--udid ID]
                             [--identity SHA1] [--profile FILE] [--bundle-id ID]
                             [--setup] [--ipa FILE]

GAME is one of the port's games (port/game/<id>/hostgen.json), rac1-ntsc when
none is named. The steps:

  1. MoltenVK (Apache-2.0), Vulkan on Metal: the release's static
     MoltenVK.xcframework (MoltenVK-all.tar, a fixed version checked against
     its SHA-256) into build/ios/, unless OPENRAC_MOLTENVK_XCFRAMEWORK names
     one already
  2. the port with Xcode's iOS SDK (port's ios-simulator or ios-device
     preset; hostgen still runs on the Mac): port/build/<preset>/apps/
     openrac-GAME/OpenRAC.app, signed after the link (port/ios/sign.sh)
  3. --install: the bundle on the booted simulator (simctl), or on the
     device (devicectl; --udid names one when more than one is connected)
  4. --data DIR: the game's data folder, as the extractor made it
     (iso_data/<game>/... and port/<version>/...), into the app's
     Documents/data, where the game looks (port/game/common/program/
     ios_launch.cpp). A simulator's copy is a clone (APFS: no space taken);
     a device's goes over the cable or the network, its folders of many
     files packed as one Apple Archive (Documents/data.aar) that the game
     unpacks at its next start
  5. --launch: starts it, with the game's log in this terminal on the
     simulator

A device build is signed with an Apple Development identity and a
provisioning profile that names the device. --identity (the SHA-1 that
`security find-identity -v -p codesigning` prints) and --profile choose them;
without them the newest profile in Xcode's folders whose application
identifier covers the bundle identifier (dev.openrac.GAME, or --bundle-id),
and whose certificate is one of this Mac's identities, is used. A free
Apple ID's team works too: make any app for the device in Xcode once and its
wildcard or exact profile is there.

--setup puts Python in the game (BeeWare's Python-Apple-support, a fixed
release checked against its SHA-256, unless OPENRAC_PYTHON_XCFRAMEWORK names
a Python.xcframework), with the extractor's scripts: on its first start the
game asks for the player's disc image and makes its data folder on the device
(port/game/common/program/ios_setup.mm), so the app holds nothing of the game.
--ipa FILE (with --device, implying --setup) packs that app as an .ipa for
AltStore, SideStore or Sideloadly, which sign it again with the player's own
Apple ID: built without any disc and signed ad hoc unless --identity and
--profile are given.

--disc IMAGE is the player's disc image: what the decompilation still has only
as assembly is translated from it, as for the desktops (tools/build_port.py
--disc). Needs Xcode, CMake and Ninja. Standard library only.
"""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

from openrac_common import digest, paths, proc

ROOT = paths.repo_root()
PORT = ROOT / "port"
BUILD = ROOT / "build/ios"
DEFAULT_GAME = "rac1-ntsc"
# MoltenVK's release (https://github.com/KhronosGroup/MoltenVK/releases): the archive with the
# static library for both the device and the simulator.
MOLTENVK_VERSION = "1.4.2"
MOLTENVK_FILE = "MoltenVK-all.tar"
MOLTENVK_SHA256 = "562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276"
# Python for the setup on the device (https://github.com/beeware/Python-Apple-support/releases):
# the iOS support package, whose Python.xcframework the game links.
PYTHON_RELEASE = "3.14-b14"
PYTHON_FILE = "Python-3.14-iOS-support.b14.tar.gz"
PYTHON_SHA256 = "703ff822529f46edcbcd8b88096b2544f6990f3109ad38b4b4b61bb489a7c1ee"
# A data folder's subfolder with more files than this goes to a device in the archive.
PACK_FILES = 64
PROFILE_FOLDERS = (
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
)


def download(url: str, archive: Path, sha256: str) -> Path:
    """URL at ARCHIVE, unless it is there already with the SHA-256; any other content is refused."""
    if archive.is_file() and digest.sha256(archive) == sha256:
        return archive
    archive.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {url}", flush=True)
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as response, open(archive.with_suffix(".part"), "wb") as f:
        while chunk := response.read(1 << 20):
            h.update(chunk)
            f.write(chunk)
    if h.hexdigest() != sha256:
        sys.exit(f"{archive.name}: its SHA-256 is {h.hexdigest()}, not {sha256}")
    archive.with_suffix(".part").replace(archive)
    return archive


def moltenvk() -> Path:
    """The static MoltenVK.xcframework: OPENRAC_MOLTENVK_XCFRAMEWORK, else the pinned release's."""
    given = os.environ.get("OPENRAC_MOLTENVK_XCFRAMEWORK")
    if given:
        if not (Path(given) / "Info.plist").is_file():
            sys.exit(f"OPENRAC_MOLTENVK_XCFRAMEWORK={given} is not an xcframework")
        return Path(given)
    out = BUILD / f"MoltenVK-{MOLTENVK_VERSION}"
    framework = out / "MoltenVK/MoltenVK/static/MoltenVK.xcframework"
    if (framework / "Info.plist").is_file():
        return framework
    archive = download(f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{MOLTENVK_VERSION}/{MOLTENVK_FILE}",
                       BUILD / "downloads" / f"MoltenVK-{MOLTENVK_VERSION}-{MOLTENVK_FILE}", MOLTENVK_SHA256)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        # Only the static framework and the license: the archive's dynamic libraries and tools are
        # not used.
        members = [m for m in tar.getmembers()
                   if m.name.startswith("MoltenVK/MoltenVK/static/") or m.name == "MoltenVK/LICENSE"]
        tar.extractall(out, members=members, filter="data")
    return framework


def python_apple() -> Path:
    """Python-Apple-support's Python.xcframework: OPENRAC_PYTHON_XCFRAMEWORK, else the pinned
    release's."""
    given = os.environ.get("OPENRAC_PYTHON_XCFRAMEWORK")
    if given:
        if not (Path(given) / "Info.plist").is_file():
            sys.exit(f"OPENRAC_PYTHON_XCFRAMEWORK={given} is not an xcframework")
        return Path(given)
    out = BUILD / f"Python-{PYTHON_RELEASE}"
    framework = out / "Python.xcframework"
    if (framework / "Info.plist").is_file():
        return framework
    archive = download(f"https://github.com/beeware/Python-Apple-support/releases/download/{PYTHON_RELEASE}/{PYTHON_FILE}",
                       BUILD / "downloads" / PYTHON_FILE, PYTHON_SHA256)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.name.startswith("Python.xcframework/")]
        tar.extractall(out, members=members, filter="data")
    return framework


def pack_ipa(app: Path, ipa: Path) -> None:
    """APP as an .ipa: the bundle in Payload/, zipped (what AltStore, SideStore and Sideloadly
    install, signing it again for the player)."""
    with tempfile.TemporaryDirectory() as work:
        payload = Path(work) / "Payload"
        payload.mkdir()
        proc.run(["ditto", app, payload / app.name], echo=True)
        ipa.parent.mkdir(parents=True, exist_ok=True)
        ipa.unlink(missing_ok=True)
        proc.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", payload, ipa], echo=True)
    print(f"{ipa}")


def identities() -> dict[str, str]:
    """This Mac's code signing identities: SHA-1 to name."""
    listed = proc.run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True).stdout
    found = {}
    for line in listed.splitlines():
        parts = line.strip().split(" ", 2)
        if len(parts) == 3 and parts[0].endswith(")") and len(parts[1]) == 40:
            found[parts[1].upper()] = parts[2].strip().strip('"')
    return found


def read_profile(path: Path) -> dict:
    decoded = proc.run(["security", "cms", "-D", "-i", path], capture=True, check=False)
    if decoded.returncode != 0:
        return {}
    return plistlib.loads(decoded.stdout.encode())


def covers(application_id: str, team: str, bundle_id: str) -> bool:
    """Whether a profile's application identifier (TEAM.id or TEAM.prefix*) covers BUNDLE_ID."""
    wanted = f"{team}.{bundle_id}"
    if application_id.endswith("*"):
        return wanted.startswith(application_id[:-1])
    return application_id == wanted


def signing(bundle_id: str, identity: str | None, profile: Path | None, udid: str | None) -> tuple[str, Path]:
    """The identity and the profile a device build is signed with."""
    mine = identities()
    if profile is not None:
        chosen = [(profile, read_profile(profile))]
    else:
        chosen = []
        for folder in PROFILE_FOLDERS:
            for path in folder.glob("*.mobileprovision"):
                info = read_profile(path)
                team = (info.get("TeamIdentifier") or [""])[0]
                app = info.get("Entitlements", {}).get("application-identifier", "")
                if not info or not covers(app, team, bundle_id) or "ProvisionedDevices" not in info:
                    continue
                if udid is not None and udid not in info["ProvisionedDevices"]:
                    continue
                chosen.append((path, info))
        # The newest first; an exact identifier before a wildcard.
        chosen.sort(key=lambda p: (not p[1]["Entitlements"]["application-identifier"].endswith("*"),
                                   p[1]["CreationDate"]), reverse=True)
    for path, info in chosen:
        certificates = {hashlib.sha1(c).hexdigest().upper() for c in info.get("DeveloperCertificates", [])}
        usable = [h for h in mine if h in certificates and (identity is None or h == identity.upper())]
        if usable:
            print(f"signing with {mine[usable[0]]} and {info.get('Name')} ({path})")
            return usable[0], path
    sys.exit(f"No provisioning profile for {bundle_id} with one of this Mac's identities: make an app "
             "for the device in Xcode once (or name them with --identity and --profile)")


def connected_device(given: str | None) -> tuple[str, str]:
    """The device: devicectl's identifier and its UDID (what a profile lists). GIVEN is either, or
    its name; without it, the only iPhone or iPad connected."""
    out = BUILD / "devices.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    proc.run(["xcrun", "devicectl", "list", "devices", "--json-output", out, "--quiet"], capture=True)
    devices = [d for d in json.loads(out.read_text())["result"]["devices"]
               if d.get("hardwareProperties", {}).get("platform") == "iOS"]
    if given:
        ready = [d for d in devices
                 if given in (d["identifier"], d["hardwareProperties"].get("udid"), d["deviceProperties"].get("name"))]
    else:
        ready = [d for d in devices if d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
    if len(ready) != 1:
        names = ", ".join(f"{d['deviceProperties']['name']} ({d['identifier']})" for d in devices) or "none"
        sys.exit(f"Name the device with --udid (known: {names})")
    return ready[0]["identifier"], ready[0]["hardwareProperties"]["udid"]


def configure_and_build(game: str, preset: str, framework: Path, disc: Path | None,
                        sign: tuple[str, Path] | None, bundle_id: str | None,
                        python: Path | None = None) -> Path:
    # Each setting given every time, empty when not wanted: the build folder's cache keeps the last.
    defines = [f"-DPython3_EXECUTABLE={sys.executable}", f"-DOPENRAC_MOLTENVK_XCFRAMEWORK={framework}",
               f"-DOPENRAC_{game.upper().replace('-', '_')}_RETAIL_IMAGE={disc or ''}",
               f"-DOPENRAC_IOS_PYTHON_XCFRAMEWORK={python or ''}"]
    if sign is not None:
        defines += [f"-DOPENRAC_IOS_SIGN_IDENTITY={sign[0]}", f"-DOPENRAC_IOS_PROFILE={sign[1]}"]
    else:
        defines += ["-DOPENRAC_IOS_SIGN_IDENTITY=", "-DOPENRAC_IOS_PROFILE="]
    if bundle_id is not None:
        defines.append(f"-DOPENRAC_IOS_BUNDLE_ID={bundle_id}")
    env = dict(os.environ, OPENRAC_MOLTENVK_XCFRAMEWORK=str(framework))
    proc.run(["cmake", "--preset", preset, *defines], cwd=PORT, env=env, echo=True)
    proc.run(["cmake", "--build", PORT / "build" / preset, "--target", f"openrac-{game}"], cwd=PORT, env=env,
             echo=True)
    app = PORT / "build" / preset / "apps" / f"openrac-{game}" / "OpenRAC.app"
    print(f"{app}")
    return app


def simulator(app: Path, bundle_id: str, data: Path | None, install: bool, launch: bool, udid: str | None) -> None:
    target = udid or "booted"
    if install:
        proc.run(["xcrun", "simctl", "install", target, app], echo=True)
    if data is not None:
        container = proc.run(["xcrun", "simctl", "get_app_container", target, bundle_id, "data"],
                             capture=True).stdout.strip()
        dest = Path(container) / "Documents/data"
        dest.mkdir(parents=True, exist_ok=True)
        # cp -c clones on APFS: the disc image and the levels take no space twice.
        for item in sorted(data.iterdir()):
            proc.run(["cp", "-c", "-R", item, dest], echo=True)
    if launch:
        proc.run(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", target, bundle_id],
                 echo=True, check=False)


def device(app: Path, bundle_id: str, data: Path | None, install: bool, launch: bool, target: str) -> None:
    if install:
        proc.run(["xcrun", "devicectl", "device", "install", "app", "--device", target, app], echo=True)
    if data is not None:
        def send(source: Path, destination: str) -> None:
            proc.run(["xcrun", "devicectl", "device", "copy", "to", "--device", target, "--source", source,
                      "--destination", destination, "--domain-type", "appDataContainer",
                      "--domain-identifier", bundle_id], echo=True)

        # devicectl sends a file a request, a few a second: the folders of many files (the levels,
        # thousands) go as one Apple Archive, Documents/data.aar, which the game unpacks into
        # Documents/data at its next start (ios_launch.cpp). The rest (the disc image) as it is.
        packed = []
        for item in sorted(data.iterdir()):
            if item.is_dir() and sum(1 for _ in item.rglob("*")) > PACK_FILES:
                packed.append(item.name)
            else:
                send(item, f"Documents/data/{item.name}")
        if packed:
            with tempfile.TemporaryDirectory() as work:
                archive = Path(work) / "data.aar"
                # Owners, flags and extended attributes are the Mac's: the device's own instead.
                command = ["aa", "archive", "-d", data, "-o", archive, "-exclude-field", "uid,gid,flg,xat,acl"]
                for name in packed:
                    command += ["-include-path", name]
                proc.run(command, echo=True)
                send(archive, "Documents/data.aar")
    if launch:
        proc.run(["xcrun", "devicectl", "device", "process", "launch", "--device", target,
                  "--terminate-existing", bundle_id], echo=True, check=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("game", nargs="?", default=DEFAULT_GAME)
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--simulator", action="store_true", help="for the iOS simulator (the default)")
    where.add_argument("--device", action="store_true", help="for an iPhone or iPad")
    parser.add_argument("--disc", type=Path, metavar="IMAGE", help="the game's disc image (tools/build_port.py --disc)")
    parser.add_argument("--install", action="store_true", help="install the app on the simulator or the device")
    parser.add_argument("--data", type=Path, metavar="DIR", help="copy the game's data folder into the app")
    parser.add_argument("--launch", action="store_true", help="start the game")
    parser.add_argument("--udid", help="the simulator or the device (default: the booted one, the connected one)")
    parser.add_argument("--identity", help="the code signing identity's SHA-1 (device)")
    parser.add_argument("--profile", type=Path, help="the provisioning profile (device)")
    parser.add_argument("--bundle-id", help="the bundle identifier (default: dev.openrac.GAME)")
    parser.add_argument("--setup", action="store_true",
                        help="Python in the game: the player sets their disc up on the device")
    parser.add_argument("--ipa", type=Path, metavar="FILE",
                        help="pack the app as an .ipa to share (with --device; built without a disc, with --setup)")
    args = parser.parse_args()
    if args.ipa is not None:
        if not args.device:
            sys.exit("--ipa is for a device build (--device)")
        if args.disc is not None:
            sys.exit("--ipa makes an app to share, which holds nothing of a disc: drop --disc")
        args.setup = True
    if sys.platform != "darwin":
        sys.exit("The iOS build needs a Mac with Xcode")
    if not (PORT / "game" / args.game / "hostgen.json").is_file():
        sys.exit(f"{args.game} is not one of the port's games (port/game/<id>/hostgen.json)")
    if args.data is not None and not (args.data / "iso_data").is_dir():
        sys.exit(f"--data {args.data}: not a data folder (it has no iso_data/)")
    bundle_id = args.bundle_id or f"dev.openrac.{args.game}"
    framework = moltenvk()
    sign = None
    target = None
    if args.device:
        udid = None
        if args.udid or args.install or args.data or args.launch:
            target, udid = connected_device(args.udid)
        # An .ipa to share is signed ad hoc: the player's sideloading tool signs it for their device.
        if args.ipa is None or args.identity or args.profile:
            sign = signing(bundle_id, args.identity, args.profile, udid)
    python = python_apple() if args.setup else None
    app = configure_and_build(args.game, "ios-device" if args.device else "ios-simulator", framework,
                              args.disc.resolve() if args.disc else None, sign, args.bundle_id, python)
    if args.ipa is not None:
        pack_ipa(app, args.ipa.resolve())
    data = args.data.resolve() if args.data else None
    if args.device:
        if target is not None:
            device(app, bundle_id, data, args.install, args.launch, target)
    else:
        simulator(app, bundle_id, data, args.install, args.launch, args.udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
