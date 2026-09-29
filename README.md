# NuclearTrollstav

A small joke plugin for Valheim, for lighthearted moments: draw **Trollstav** (the troll-summoning staff,
`StaffRedTroll`) and a missile silo arms; use it and the missile launches. Plain BepInEx, nothing to install on a
server. Source, releases and issues: https://github.com/DoomMachine/Valheim-NuclearTrollstav

## What it does

- **Arm alert** ("Nuclear Silo Arm") when you take Trollstav in hand as your weapon: from the hotbar, the inventory,
  a gamepad or the radial menu, or by drawing your weapons again with the hide/show key. It plays when the game has
  finished equipping the staff, a fraction of a second after you choose it. Having the staff in your inventory or on
  the hotbar does nothing, and so do the game putting your gear back on when you log in, respawn or load a world,
  the staff being equipped automatically because you picked it up with empty hands, and it coming back into your
  hand after you eat.
- **Launch alert** ("Nuclear Missile Launch Sound") when you use the staff: at the moment its summoning attack
  casts - once per cast, and also when the game then refuses the troll because the summon limit has been reached.

## Keeping it bearable

- **Never on top of each other.** One alert plays at a time. If you draw the staff and use it straight away, the
  arm alert plays to the end, then comes a one-second pause, then the launch.
- **At most once every 30 minutes** for each of the two alerts (the setting `CooldownMinutes`), counted separately
  by every player for what they hear, whoever set it off, from the moment an alert starts playing. So after you
  heard a launch - yours or a friend's - you hear no launch for 30 minutes, while the arm alert keeps its own timer.
  The timers start again when the game restarts.
- **Never above your volume settings.** The alerts play on the game's own interface-sound channel, which follows
  the game's Volume and Effect volume settings, and the plugin's `Volume` (0 to 1, default 0.5) only turns them down
  from there. No alert starts while a cinematic plays, and a cinematic that silences the game silences one already
  playing too.
- An alert that cannot be heard (you are dead, a cinematic plays, a volume is at 0, or its sound file could not be
  loaded) is skipped without using up its 30 minutes. One already waiting for its turn is dropped the same way when
  you die or leave the world, or if it still cannot play 30 seconds after its turn came (time spent waiting for
  another alert to finish does not count, however long its sound).

## Multiplayer

- Players near you who **also run this plugin** hear your alerts: within 100 m by default (`HearingRange`),
  measured in 3D, so someone in a dungeon above or below you does not. Players without the plugin hear nothing and
  notice nothing.
- **Nothing is needed on the server**: the game's own server code passes the alert on to the other players, so a
  dedicated server needs no plugin (this one does not load there), and a hosting player's game passes it on whether
  or not it runs the plugin. The same holds whether you host, join a friend or play on a dedicated server.
- **Each player decides for themselves**: `ShareMyAlerts` (let others hear yours), `HearOthers` (hear theirs) and
  `HearingRange`. No host or server can change them. Each player hears the sound files of their own install.
- The message says only which alert it is and which player set it off - no position. Each listener measures the
  distance to that player itself, so only players the listener's game has loaded around them can be heard. At the
  game's code-default Draw distance ("square 288 m") that is everyone within at least 128 m, which covers the
  default range. The two lowest Draw distance settings load less (in some directions less than 100 m), a server can
  lower the distance for everyone, and a range beyond what the game loads reaches no further.
- The plugin writes nothing into the world, your character, your map or anyone else's game.

## Installing

NuclearTrollstav needs BepInEx 5 for Valheim (the BepInExPack for Valheim, for example). Download
`NuclearTrollstav-<version>.zip` from this repository's Releases and unpack it into `BepInEx/plugins/`, so that
`BepInEx/plugins/NuclearTrollstav/` holds `NuclearTrollstav.dll` and the two `.mp3` files (the zip also holds this
README and the licence). The sounds are looked up next to the DLL. When the game starts, `BepInEx/LogOutput.log`
says `NuclearTrollstav 1.0.0 loaded.` and, for each sound, `Arm sound loaded: ...` / `Launch sound loaded: ...`
with its length. To remove it, delete the `NuclearTrollstav` folder, and the .cfg too to forget the settings.

## Configuration (`BepInEx/config/DoomMachine.NuclearTrollstav.cfg`)

Edit the file with the game closed, or change the settings in game with a configuration manager mod, where all but
the two sound files take effect at once.

| Setting | Default | |
|---|---|---|
| `Sound.Volume` | `0.5` | 0 (silent) to 1; the game's Volume and Effect volume settings scale it too |
| `Sound.ArmSound` | `Nuclear Silo Arm.mp3` | The arm alert's MP3, in the plugin's folder (or a full path). Read when the game starts |
| `Sound.LaunchSound` | `Nuclear Missile Launch Sound.mp3` | The launch alert's MP3, likewise |
| `Alerts.CooldownMinutes` | `30` | Each alert at most once in this many minutes, whoever set it off; 0 = no limit |
| `Multiplayer.ShareMyAlerts` | `true` | Let nearby players who run the plugin hear your alerts |
| `Multiplayer.HearOthers` | `true` | Hear the alerts of nearby players who run the plugin |
| `Multiplayer.HearingRange` | `100` | Metres, 1 to 1000 |

The log has a line when an alert starts playing ("Launch alert (you): playing now.", or "... (a player 42 m away)
..."), and a line when one of your own alerts will not play, saying why (for example "one played less than 30 min
ago"). Another player's alert that reaches you - in range, with `HearOthers` on and while you are alive - gets the
same kind of line when it will not play, at most once every 10 seconds for each of the two alerts. Nothing is logged for
another player's alert you do not hear at all (out of range, `HearOthers` off, or while you are dead), nor for an
alert still waiting that is dropped when you die or leave the world, or 30 seconds after its turn came.

## Building

`dotnet build NuclearTrollstav.csproj -c Release` (needs the game with BepInEx; see the comment at the top of
`NuclearTrollstav.csproj`). `tests/` holds the rules that need no game (`dotnet run` there): the scheduling, the
cooldowns and the one-second gap, and the decisions in `src/AlertRules.cs` - when an equip or an attack sets off an
alert, whether another player's alert is heard, whether an alert can be heard right now, the volume clamp and the
message's bytes. `tools/preflight.ps1` checks a build against the installed game: its Harmony targets and every game
member it uses, what the game does that the alerts rely on, and that the plugin's game-side code feeds those
decisions their inputs from the right places and acts on them the right way round (its description lists each
check). Run it after every Valheim update. `tools/deploy.ps1` installs a build after running preflight, moving any
previous install into the repository's `retired/` folder (git-ignored). `tools/package.ps1` makes a release's zip
from a clean checkout; run in Windows PowerShell 5.1 with the same .NET SDK and against the same Valheim and BepInEx
files, the same commit gives the same bytes. The tools find the game the way the build does: `-ValheimDir`, else the
`VALHEIM` environment variable, else the same default path as the build (each tool has its own copy of the one in
`NuclearTrollstav.csproj`).

`docs/design.md` explains how the plugin works and why - the game code it relies on, the decisions taken and the
alternatives left aside - and what to do after a Valheim update. `docs/open-items.md` lists what is not yet tried in
play, not verified, open or only an idea.

## Credits

NuclearTrollstav was conceived, directed and tested by **DoomMachine**. The code, tests and docs were written by Claude,
Anthropic's AI model, in Claude Code under DoomMachine's direction; the commits are DoomMachine's, and Claude is
credited here rather than as a co-author.

## Licence

The code is under the MIT licence (see `LICENSE`), copyright DoomMachine. The two sound files (in `sounds/` in the
repository, beside the DLL in the release zip) are not covered by that licence.

NuclearTrollstav is not affiliated with or endorsed by Iron Gate or Coffee Stain.

## History

- **1.0.0** - first release. Played in single player before release (both sounds, the arm-then-launch chain, the
  cooldown); not yet played together with other players or on a dedicated server.
