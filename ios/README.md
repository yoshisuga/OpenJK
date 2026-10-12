# Jedi Outcast and Jedi Academy on iOS (OpenJK, experimental)

This branch (`ios-spike`) builds OpenJK's single player for iPhone and iPad:

- **Jedi Knight II: Jedi Outcast**, as **OpenJO**
- **Jedi Knight: Jedi Academy**, as **OpenJA**

They're two separate apps, because OpenJK builds each game's engine
separately (Jedi Outcast is the same source with `JK2_MODE`). It's an
experiment, so expect rough edges. You need your own copy of each game (GOG or
Steam); no game data is included. Multiplayer isn't included.

## How it works

- **Graphics:** OpenJK's vanilla renderer uses desktop OpenGL 1.x, which iOS
  doesn't have. [gl4es](https://github.com/yoshisuga/gl4es) translates it to
  OpenGL ES 2 and is linked into the renderer only (`OPENJK_GL4ES`). The
  renderer's GL calls are renamed onto gl4es's (`code/rd-vanilla/gl4es_names.h`).
  This needs the fork's fixes to gl4es; see its history.
- **Window, input, sound:** SDL 2.30, as on other platforms.
- **Touch controls:** a UIKit overlay over SDL's window (`shared/ios/ios_touch.m`,
  with `shared/ios/ios_bridge.cpp` as its way into the engine):
  - **Moving and looking:** a move stick under the left thumb, and drag to look.
  - **Right side:** FIRE, ALT, JUMP, CROUCH, USE and FORCE.
  - **Top left:** NEXT WPN, FORCE WHEEL, ITEM, STYLE (saber stance), VIEW, GYRO
    and ⚙︎ (look and gyro speed).
  - **Top right:** QUICK SAVE and QUICK LOAD (hold until the ring fills), and MENU.
  - **Force wheel and item wheel:** tap FORCE WHEEL or ITEM for the next power or
    to use the item. Slide out of the button, or hold it, to pick from a wheel.
    Jedi Outcast's wheel has 7 powers and Jedi Academy's has 12.
  - **Menus and videos:** in the menus, tap where you want. A tap skips a video.
  - **Gyro aiming:** the GYRO button turns it on and off.
- **Wheel helpers in the game code:** the wheels need to know which powers and
  items you have, and that lives in the game code. On iOS only, both games'
  cgame (`codeJK2/cgame`, `code/cgame`) add the `forceselect` and `invselect`
  commands and keep `cg_iosforce` and `cg_iosinv` up to date.
- **Brightness:** iOS has no hardware gamma, so the Brightness slider is a pass
  over the finished frame.
- **Resolution:** the game always fills the screen. The height you choose in
  the menus sets how sharp it is, up to the screen's native pixels.

## Building

You need macOS with Xcode, CMake and Ninja. Clone this repository into an empty
folder; the script puts SDL2, gl4es and the builds next to it.

```
mkdir OpenJK-iOS && cd OpenJK-iOS
git clone -b ios-spike https://github.com/yoshisuga/OpenJK.git
```

`ios/build.sh <device|sim> [jo|ja]` builds one game: `jo` for Jedi Outcast (the
default) or `ja` for Jedi Academy.

**Simulator:**

```
OpenJK/ios/build.sh sim jo      # build/sim/OpenJO.app
OpenJK/ios/build.sh sim ja      # build/sim/OpenJA.app
xcrun simctl install booted build/sim/OpenJO.app
```

**iPhone or iPad:** you need a development signing identity and a provisioning
profile that covers the bundle IDs. A wildcard team profile works.

```
export IOS_CODESIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"
export IOS_TEAM_ID=XXXXXXXXXX
export IOS_BUNDLE_ID=com.example.openjo
export IOS_PROVISIONING_PROFILE=/path/to/profile.mobileprovision
OpenJK/ios/build.sh device jo   # build/device/OpenJO.app, com.example.openjo
OpenJK/ios/build.sh device ja   # build/device/OpenJA.app, com.example.openja
xcrun devicectl device install app --device <device-id> build/device/OpenJO.app
```

Jedi Academy's bundle ID is `IOS_BUNDLE_ID` with its last part changed to
`openja`. Set `IOS_BUNDLE_ID_JA` to choose a different one.

## Game files

Each app has its own `Documents/base`. Copy each game's `GameData/base` files
into its app:

- **Jedi Outcast** (OpenJO): `assets0.pk3`, `assets1.pk3`, `assets2.pk3`, `assets5.pk3`
- **Jedi Academy** (OpenJA): `assets0.pk3` to `assets3.pk3`

You can copy them with the Files app (On My iPhone > OpenJO or OpenJA), with
Finder file sharing, or with:

```
xcrun devicectl device copy to --device <device-id> --domain-type appDataContainer \
    --domain-identifier com.example.openja --source assets0.pk3 --destination Documents/base/assets0.pk3
```

## Not done yet

- hiding the touch buttons when a game controller is connected
- a keyboard button for the console and cheats
- pausing the game while a wheel is open
- multiplayer
