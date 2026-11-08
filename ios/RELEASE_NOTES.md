Experimental iPhone and iPad builds of Jedi Outcast and Jedi Academy single player, on the OpenJK engine, with touch controls. No game data is included: you need your own copy of each game (GOG or Steam).

### What's in v0.1

Two apps, both unsigned: sign and install them with a sideloading tool (AltStore, SideStore or Sideloadly). They install side by side, each with its own folder in the Files app. With a free Apple ID, each one counts toward the limit of 3 sideloaded apps.

- **OpenJO-iOS-unsigned.ipa**: Jedi Knight II: Jedi Outcast (the OpenJO app).
- **OpenJA-iOS-unsigned.ipa**: Jedi Knight: Jedi Academy (the OpenJA app).

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
