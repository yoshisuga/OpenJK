Experimental iPhone and iPad builds of Jedi Outcast and Jedi Academy single player, on the OpenJK engine, with touch controls. No game data is included: you need your own copy of each game (GOG or Steam).

### What's in 0.1

Two apps, both unsigned (see How to install below). They install side by side, each with its own folder in the Files app. With a free Apple ID, each one counts toward the limit of 3 sideloaded apps.

- **OpenJO-iOS-unsigned.ipa**: Jedi Knight II: Jedi Outcast (the OpenJO app).
- **OpenJA-iOS-unsigned.ipa**: Jedi Knight: Jedi Academy (the OpenJA app).

### How to install

1. **Download** OpenJO-iOS-unsigned.ipa and/or OpenJA-iOS-unsigned.ipa from the Assets list below.
2. **Sign and install it with a sideloading tool.** The .ipa is unsigned, and an iPhone only runs apps signed with an Apple certificate, so you sign it yourself. Some common free tools:
    - **[AltStore](https://altstore.io)** (AltStore Classic): install AltServer on a Mac or Windows PC and use it to put AltStore on your phone. Then in AltStore, go to *My Apps*, tap **+** and pick the .ipa. (AltStore PAL, the EU app marketplace, can't install this file.)
    - **[SideStore](https://sidestore.io)**: a version of AltStore that, after a one-time setup with a computer, signs and refreshes apps on the phone itself. Tap **+** in *My Apps* and pick the .ipa.
    - **[Sideloadly](https://sideloadly.io)**: a Mac or Windows program. Connect your phone, drop the .ipa in, sign in with your Apple ID, and it installs the app.
3. **The first time, iOS may ask for two more things:**
    - **Developer Mode:** go to *Settings > Privacy & Security > Developer Mode*, turn it on, restart the phone, and confirm.
    - **"Untrusted Developer":** go to *Settings > General > VPN & Device Management*, tap your Apple ID under *Developer App*, and tap *Trust*.

These tools ask for your Apple ID and password, because they sign the app with it. They're made by third parties, not Apple; some people use a separate Apple ID just for sideloading.

**With a free Apple ID, apps stay signed for 7 days.** After that the app won't open until you refresh it (AltStore and SideStore can do this for you) or install it again. Your game files and saves are kept when you refresh.

**Updating:** sideload the new .ipa with the same tool and Apple ID. It replaces the app and keeps your game files and saves.

### Game files

Open each app once, then copy the game's files from its `GameData/base` folder into Files > On My iPhone > OpenJO (or OpenJA) > base. Make the `base` folder if it isn't there.

- **Jedi Outcast:** `assets0.pk3`, `assets1.pk3`, `assets2.pk3` and `assets5.pk3`
- **Jedi Academy:** `assets0.pk3` to `assets3.pk3`

### Controls

- **Move and look:** a move stick under your left thumb; drag anywhere else to look.
- **Right side:** FIRE, ALT, JUMP, CROUCH, USE and FORCE.
- **Top left:** NEXT WPN, FORCE WHEEL, ITEM, STYLE (saber stance), VIEW, GYRO and ⚙︎ (look and gyro speed).
- **Top right:** QUICK SAVE and QUICK LOAD (hold until the ring fills), and MENU.
- **Force wheel and item wheel:** tap for the next power or to use the item; slide out of the button, or hold it, to pick from a wheel.

### Not done yet

- Hiding the touch buttons when a game controller is connected.
- A keyboard button for the console and cheats.
- Pausing the game while a wheel is open.
- Multiplayer.

This is an early test build, so expect rough edges. More about the port: https://github.com/yoshisuga/OpenJK/blob/ios-spike/ios/README.md
