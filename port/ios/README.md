# OpenRAC on iPhone and iPad

It's not on the App Store. There are two ways to get it on your iPhone or iPad:

- **Build it yourself** on a Mac and install it over a cable or Wi-Fi, signed with your own Apple ID. See [Building it yourself](#building-it-yourself). This is how it was made and tested.
- **Sideload the IPA** (experimental). AltStore, SideStore or Sideloadly signs it with your Apple ID and installs it. See [Sideloading the IPA](#sideloading-the-ipa-experimental).

## What you need

- **iOS 17 or newer.** Tested on an iPhone 16 Pro and an iPad Pro 11-inch (M4), at 60fps.
- **Your own disc image** of Ratchet & Clank (NTSC, `SCUS_971.99`) as a `.iso`. The PAL version doesn't work yet.
- **About 5 GB free** on your phone: the disc image (4.2 GB) plus the levels the app makes from it (about 1 GB).
- **A controller is optional.** There are touch controls, and MFi, Xbox, DualShock 4 and DualSense controllers work too.

## Building it yourself

### What you need

- **A Mac with Xcode** (from the App Store). Open it once so it can finish installing.
- **CMake, Ninja and Python 3.** With [Homebrew](https://brew.sh):
  ```bash
  brew install cmake ninja python
  ```
- **An Apple ID.** A free one works. Its apps stop opening after 7 days though, so you'll have to build again every week. A paid Apple Developer account signs for a year.
- **A cable**, the first time. After that it installs over Wi-Fi as long as your device and Mac are on the same network.

You don't need your disc on the Mac. You give it to the app on your phone.

### 1. Get the code

```bash
git clone https://github.com/SubhanHabib/OpenRAC-iOS.git
cd OpenRAC-iOS
```

### 2. Set up signing

This is the annoying part, but you only do it once.

1. Plug your iPhone into the Mac and tap **Trust** on the phone
2. On the phone, turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode. It'll restart
3. In Xcode, sign in with your Apple ID: Xcode → Settings → Accounts → **+**
4. Make a throwaway app so Xcode creates a signing profile for your phone:
   - File → New → Project → iOS → App
   - Name it whatever. Pick your team, and set the bundle identifier to something like `com.yourname.openrac`
   - Pick your iPhone at the top and press **Run** (▶)
   - Once it's on your phone you can delete it and close the project

Remember the bundle identifier, you need it in the next step.

### 3. Build and install

With your device plugged in, or on the same Wi-Fi once it's been plugged in once:

```bash
python3 tools/build_ios.py rac1-ntsc --device --setup --install --bundle-id com.yourname.openrac
```

Use the bundle identifier from step 2. The first build takes a while because it downloads MoltenVK and Python and builds the whole game. After that it's quicker.

If the app won't open and says the developer isn't trusted, go to Settings → General → VPN & Device Management, tap your Apple ID and trust it.

If you have more than one device around (an iPhone and an iPad, say), add `--udid <id>` to pick one. `xcrun devicectl list devices` lists them.

### 4. Add your game

1. Put your `.iso` on your phone. AirDrop it, or drag it into the Files tab when you select your iPhone in Finder. If it's in iCloud Drive, download it first
2. Open OpenRAC
3. Tap **Choose disc image…** and pick it. If you put it in Files → On My iPhone → OpenRAC, there's a **Use** button for it instead
4. Wait while it makes the levels. It took about 16 minutes on an iPhone 16 Pro and 10 on an M4 iPad. Keep the app open, the screen stays on by itself
5. The game starts when it's done

If it says it's the wrong disc, it's probably the PAL version or another game. If something else goes wrong, check `setup.log` in Files → On My iPhone → OpenRAC → data.

### Updating

```bash
git pull
python3 tools/build_ios.py rac1-ntsc --device --setup --install --bundle-id com.yourname.openrac
```

Same bundle identifier, so your levels and saves stay. On a free Apple ID, run this again whenever the app stops opening after 7 days.

## Sideloading the IPA (experimental)

The IPA isn't signed by anyone. The tool you use signs it with your Apple ID. Heads up: it installs on an iPad when it's re-signed the way these tools do it, but it hasn't been tried through the tools themselves yet. If you try it, let me know how it went, and say which device and tool you used.

1. Download `OpenRAC_rac1-ntsc_<version>_ios.ipa` from the [release page](https://github.com/SubhanHabib/OpenRAC-iOS/releases/latest)
2. Sideload it, signing in to the tool with your Apple ID:
   - **[AltStore](https://altstore.io)**: My Apps, **+**, pick the IPA
   - **[SideStore](https://sidestore.io)**: **+**, pick the IPA
   - **[Sideloadly](https://sideloadly.io)** (Mac or PC, with a cable): drag the IPA in, pick your phone, enter your Apple ID, press Start
3. On the phone, trust it: Settings → General → VPN & Device Management, your Apple ID, Trust. Turn on Developer Mode if it asks
4. Add your game: see [step 4](#4-add-your-game) above

Free Apple ID limits, whatever the tool:

- **7 days.** The app stops opening after 7 days. AltStore and SideStore can refresh it. With Sideloadly you just sideload it again. Your levels and saves stay as long as you use the same tool and the same Apple ID
- **3 apps.** You can only have 3 sideloaded apps at once, and AltStore and SideStore count as one

Coming from a build you made yourself, the IPA installs as a separate app with its own storage, so you'll need to add your game again.

### Making the IPA

```bash
python3 tools/build_ios.py rac1-ntsc --device --ipa build/ios/ipa/OpenRAC.ipa
```

This builds the app without a disc, with the setup screen, signs it ad hoc (no team or Apple ID) and zips it up as an IPA. The GitHub workflow does the same thing for every release (`.github/workflows/ios-release.yml`).

More detail on every flag is in [docs/port/IOS.md](../../docs/port/IOS.md).
