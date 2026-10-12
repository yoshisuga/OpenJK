# Jedi Outcast on iOS (OpenJK, experimental)

This branch (`ios-spike`) builds OpenJK's **Jedi Knight II: Jedi Outcast single
player** for iPhone and iPad. It's an experiment, so expect rough edges. You
need your own copy of the game (GOG or Steam); no game data is included.

## How it works

- **Graphics:** OpenJK's vanilla renderer uses desktop OpenGL 1.x, which iOS
  doesn't have. [gl4es](https://github.com/yoshisuga/gl4es) translates it to
  OpenGL ES 2 and is linked into the renderer only (`OPENJK_GL4ES`). The
  renderer's GL calls are renamed onto gl4es's (`code/rd-vanilla/gl4es_names.h`).
  This needs the fork's fixes to gl4es; see its history.
- **Window, input, sound:** SDL 2.30, as on other platforms.
- **Touch controls:** a UIKit overlay over SDL's window (`shared/ios/ios_touch.m`,
  with `shared/ios/ios_bridge.cpp` as its way into the engine):
  - a move stick under the left thumb, and drag to look
  - FIRE, ALT, JUMP, CROUCH, USE and FORCE on the right
  - NEXT WPN, NEXT FORCE, ITEM, VIEW and GYRO top left, MENU top right
  - in the menus, tap where you want; a tap skips a video
  - **gyro aiming:** the GYRO button turns it on and off
- **Brightness:** iOS has no hardware gamma, so the Brightness slider is a pass
  over the finished frame.
- **Resolution:** the game always fills the screen, and the height you choose in
  the menus sets how sharp it is, up to the screen's native pixels.

## Building

You need macOS with Xcode, CMake and Ninja. Clone this repository into an empty
folder; the script puts SDL2, gl4es and the builds next to it.

```
mkdir OpenJK-iOS && cd OpenJK-iOS
git clone -b ios-spike https://github.com/yoshisuga/OpenJK.git
```

**Simulator:**

```
OpenJK/ios/build.sh sim
xcrun simctl install booted build/sim/OpenJO.app
```

**iPhone or iPad:** a development signing identity and a provisioning profile
that covers the bundle ID (a wildcard team profile works):

```
export IOS_CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
export IOS_TEAM_ID=XXXXXXXXXX
export IOS_BUNDLE_ID=com.example.openjo
export IOS_PROVISIONING_PROFILE=/path/to/profile.mobileprovision
OpenJK/ios/build.sh device
xcrun devicectl device install app --device <device-id> build/device/OpenJO.app
```

## Game files

Copy the game's `GameData/base` folder (`assets0.pk3` to `assets5.pk3`) into
the app's `Documents/base`. You can do that with the Files app (On My iPhone >
OpenJO), with Finder file sharing, or with:

```
xcrun devicectl device copy to --device <device-id> --domain-type appDataContainer \
    --domain-identifier com.example.openjo --source assets0.pk3 --destination Documents/base/assets0.pk3
```

## Not done yet

- a Force power wheel, the inventory, and quick save and load buttons
- hiding the touch buttons when a game controller is connected
- a keyboard button for the console and cheats
- Jedi Academy (the same approach should work for it)
