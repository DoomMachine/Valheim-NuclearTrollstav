# How NuclearTrollstav works, and why

For whoever changes the plugin next, including after a Valheim update. The game facts below were read from the
game's own code (Valheim 1.0.16, network version 40) unless a line says otherwise. `tools/preflight.ps1` re-checks
some of them against whatever game is installed: the `EquipItem` and `ShowHandItems` callers, `Pickup`, and the attack
trigger and its owner check. It does not re-check the others - among them that every cast makes a new `Attack` object,
Trollstav's item data, the volume routing, the relay, death and the pause. What is still open is in `open-items.md`.

## The two alerts

**Arm alert: `Humanoid.EquipItem(ItemData item, bool triggerEquipEffects)`**, a Prefix and a Postfix
(`src/Patches.cs`, decided by `AlertRules.ArmOnEquip`).
- Every way a player takes a weapon in hand ends in this call with `triggerEquipEffects` true: `Player.ToggleEquipped`
  (hotbar key, inventory right click, gamepad, radial menu), `Player.UpdateActionQueue` (the equip queue finishing -
  a short delay the game adds before a weapon is in hand), `Humanoid.ShowHandItems` (drawing the weapons again with
  the hide/show key, and the weapon coming back after eating), and `Valheim.UI.HammerItemElement`, which gives back the
  weapons held before when the hammer is put away through the radial menu - that counts too, like drawing the weapons
  again.
- The game passes **false** when the player did not choose: `Player.EquipInventoryItems` (saved gear put back at
  login, respawn and world load), `InventoryGui.OnSelectedItem` (moving items in the inventory) and
  `Humanoid.GiveDefaultItem` (creatures' gear). That flag is what keeps a login from playing the alert.
- `EquipItem` returns false at once for an item that is already equipped, leaving it in the hand, so a Postfix that
  only asked "is it in a hand now?" would fire for it. The Prefix records whether the item was in a hand before, and
  only "not in a hand, then in a hand" counts.
- Two calls with `triggerEquipEffects` true are not the player's choice and are marked and skipped: the automatic
  equip of a weapon picked up with empty hands (inside `Humanoid.Pickup`: a Prefix counts up, a Finalizer counts down,
  so the mark can never stick) and the weapon coming back after eating (`ShowHandItems(onlyRightHand: true)`, called
  from `Humanoid.UpdateUseVisual`; the hide/show key calls it with false).
- Drawing the weapons again with the hide/show key **counts** as taking the staff in hand (a decision: it is the
  player's own action, and the request called the arm sound "the drawing one").

**Launch alert: the private `Attack.ProjectileAttackTriggered()`**, a Postfix (decided by `AlertRules.LaunchOnAttack`).
- Trollstav's attack is a projectile attack with one burst (read from the game's item data). This method runs when
  the attack's animation reaches its trigger, after the attack's own checks, and it is called only from
  `Attack.OnAttackTrigger`. That is run by `Humanoid.OnAttackTrigger` only on the attacker's own client
  (`ZNetView.IsOwner`); its other caller, `Attack.StartWithoutAnimation`, runs only for a blocking item with block
  charges, which Trollstav does not have (its item data). So it is the use itself, on the player who used it.
- Every cast creates a new `Attack` object; the patch remembers the last one it alerted for, so one cast gives one
  alert whatever the animation does.
- It also plays when the game then refuses the troll because the summon limit is reached - the cast did happen.
- Not `Humanoid.StartAttack`: holding the button calls it again and again, it comes before the cast (about 1.3 s
  before, by the game's animation data; not confirmed in play), and a stagger can still cancel the attack after it.

**Recognising the staff:** its prefab name `StaffRedTroll`, or its name token `$item_staffredtroll`
(`AlertRules.IsTrollstav`). `ItemData.m_dropPrefab` is set for items loaded from a save too (`ItemDrop.Awake`).

## When an alert plays: one channel, one scheduler

`AlertScheduler` in `src/AlertRules.cs` decides for each player alone, for their own alerts and everyone else's:
- one alert at a time, and the next starts no earlier than 1 s after the previous one ends;
- at most one alert of each kind waits; when both wait, the arm alert goes first, but a launch that already waited
  through one arm alert goes before the next, so arm alerts can never hold a launch back for good;
- each kind plays at most once per cooldown (30 min by default), counted between the moments two alerts of that kind
  start playing. An alert holds its kind from the moment it is accepted, and gets the cooldown back if it never plays;
- an alert that still cannot start 30 s after its turn came is dropped; time spent waiting for another alert to
  finish does not count, however long its sound;
- everything waiting is dropped when the player leaves the world or dies.

An alert is accepted only while it could be heard (`AlertRules.Audible`): its sound is loaded, the player is in a world
and alive, the audio source exists (it only exists routed to the game's mixer, below), the plugin's volume is above 0,
no cinematic is playing, and the game's listener and effect volumes are above 0. So no cooldown is spent on a sound
nobody hears. `Player.IsDead()` is set the moment the player dies, while `Player.m_localPlayer` stays set for about 10 s
after death, until the game removes the body for the respawn.

The clock is `Time.realtimeSinceStartupAsDouble`: the single-player pause sets `Time.timeScale` to 0 but the game never
pauses audio, so a sound goes on playing through it.

## Volume: never above the player's settings

- One `AudioSource`, 2D, on an object of its own that survives scene changes, routed to the master mixer's **GUI**
  group. The game's `AudioMan.SetSFXVolume(master x effects)` sets that group's volume (`GuiVol`) together with the
  effects group's (`SfxVol`), so the alerts follow the game's Volume and Effect volume settings live. The plugin's
  `Volume` (0 to 1) only turns them down from there.
- Not the SFX group: that route has effects of its own and is turned down while a menu is open. GUI has no effects.
  (These two, and the group behind `GuiVol`, are from the game's audio asset, not its code.)
- `AudioMan.m_guiMixer` looks like the way to reach the group, but it is empty in the game's own `_AudioManager`
  prefab (asset data; no code sets it), so the group is found by its name:
  `AudioMan.instance.m_masterMixer.FindMatchingGroups("Master")`, keeping the one named `GUI`, with
  `Resources.FindObjectsOfTypeAll<AudioMixerGroup>()` as the fallback. If neither finds it, nothing plays: a source
  outside the mixer would ignore both settings.
- One source means two alerts can never sound at once, by construction.

**Loading the sounds:** `UnityWebRequestMultimedia.GetAudioClip(<full path>, AudioType.MPEG)`, decompressed into
memory, with `HideFlags.DontUnloadUnusedAsset` (the game unloads unused assets on respawn and world load). The path is
passed as a plain file path, never as a `file:` URL: Unity's URL decoding would turn a `+` in a folder name into a
space. Seen working in Valheim 1.0.16 with the two shipped MP3s. The file names are settings, read once at start.

## Sharing with other players

- **One routed call**, `DoomMachine.NuclearTrollstav.Alert`, sent to everybody, with one `ZPackage` holding 14 bytes
  (`AlertWire`): version 1, the alert's kind, and the sender's character's `ZDOID` (its user number and its id).
  **No position.**
- **Why nothing is needed on the server:** the server's `ZRoutedRpc` passes a call for everybody on to every other
  connected player whether or not it knows the name itself, and a player whose game never registered the name drops it
  without a trace. This is the same in the client and in the dedicated server's own build. The plugin does not load on
  a dedicated server (`BepInProcess("valheim.exe")`).
- The sender's own copy of the call runs at once, inside the sending call; the listener ignores it (a flag set around
  the send, the sender id, and the character itself).
- **Each listener decides:** it looks for the sender's character among the players its own game has loaded
  (`Player.GetAllPlayers()`), comparing the two numbers as they are - building a `ZDOID` from network data would add a
  user to the game's global user table - and measures the 3D distance itself against its own `HearingRange`. A
  character it has not loaded is treated as out of range, and a made-up one matches nobody.
- **Why no position** (the alternative considered): every player running the plugin on the server receives the
  message, however far away, so a position in it would tell them where the sender is. The price: only players the
  listener's game has loaded can be heard, and a range beyond that reaches no further.
- **Registration:** in a `Game.Start` Postfix and again before each send, once per `ZRoutedRpc` object. `ZNet.Awake`
  makes a new one every session, the old one stays in `ZRoutedRpc.instance` after logout, and registering one name
  twice throws.
- **The wire format never changes under this name:** a different layout gets a new call name; version 1 ignores bytes
  appended after its own 14.
- The sender tells the others at most once every 5 s per kind (a courtesy; the listeners' cooldowns are the real
  limit), and another player's refused alert is logged at most once every 10 s per kind.

## Logging (1.1.0)

The requester asked for a default output for the plugin's errors, on by default but switchable, and a verbose log of
everything that can be chosen to watch one event, besides the game's own logs.
- **Its own file, `BepInEx\NuclearTrollstav.log`** (`LogFile`, `src/LogFile.cs`), because the game rewrites
  `LogOutput.log` and `Player.log` at every start: the file is appended across sessions, and each time a session opens
  it, it gets a header (the date and time, the plugin's and the game's version, the two settings as they are then);
  every entry starts with its time. Every line is flushed at once, so it can be read while the game runs and is kept
  if the game crashes.
- **Limits:** when a session first opens it, a file of 1 MiB or more is renamed `.old.log`, replacing the one before
  - only when nothing else has the file open: an exclusive handle, sharing only Delete, is held across the delete of
  the old archive and the rename, so no other program (another copy of the game starting at the same moment) can open
  the file in between, and a rename that cannot happen does not cost the old archive. A session writes at most
  10,000 lines other than warnings and errors, and 2,000 lines of warnings and errors besides: a runaway error cannot
  fill the disk, and a long verbose session cannot crowd out the errors `ErrorLog` is for. Each allowance, once used
  up, gets one note and nothing more.
- **One writer per file**: the file is opened for writing by one game only (others may read it), and a second copy of
  the game running at the same time takes `NuclearTrollstav.2.log`, up to five - as BepInEx does with `LogOutput.log`.
  Two copies appending to one file overwrote each other's lines when that was tried while building it: each handle
  keeps its own position. A file that cannot be written stays off for the session, and says so once in BepInEx's log
  - at once at the start, too.
- **Fed by a BepInEx log listener** (`FileLogListener`, `src/FileLog.cs`), not by changing every log call: BepInEx hands
  every line of every source to every listener, from whatever thread logged it, with no lock and no guard against a
  listener that logs (`BepInEx.Logging.Logger`, decompiled 2026-10-02), and each listener filters for itself.
  `LogRules.ShouldWrite` decides: with `ErrorLog`, the plugin's own Warning, Error and Fatal lines; with `VerboseLog`,
  all of its lines; with either, another source's line at those levels (any level with `VerboseLog`) whose text names
  the plugin - an exception from its code reaches BepInEx through the Unity log with its stack trace in the text
  (`UnityLogSource`). The listener never throws (a listener that threw would break every log call in the game). Its
  one warning - the file cannot be written - is logged while a thread-local guard is set, so it cannot come back into
  the listener and repeat.
- **The verbose lines** (`Diag`, `src/Diag.cs`) go straight into the file (`FileLogListener.WriteVerbose`), never
  through BepInEx: BepInEx's `UnityLogListener` copies every line a plugin logs, Debug included, into `Player.log`
  (decompiled 2026-10-02). Each call site reads `if (Diag.Verbose) Diag.X(...)`: with `VerboseLog` off nothing runs.
  They sit outside the traced decision lines (a separate statement, never an argument), recompute a decision from the
  same inputs with the pure `AlertRules` functions to log it, and read state through read-only views (`Alerts.
  ClipLoaded`, `SourceReady`, `Sounding`, `IsWaiting`, `CooldownLeft`, `StartedAt`, `ClipKind`, `ListenerAlive`) - never
  `CanPlay` or `EnsureSource`, which would make the audio source. The line for an alert you set off is written after
  the decision (the decision makes the audio source the first time, so a line before it would wrongly say "cannot be
  heard").
  Each entry point catches its own errors, its error report included, so a fault in a log line can never stop an
  alert. `Alerts.OnRemote` gets no verbose line (preflight wants it free of log lines, so other players cannot flood
  the log): a received alert is logged in `Sharing.OnAlert`, before the hearing decision - another player's at most
  once a second per kind, since any client can send them, with the count of the rest written with the next line for
  another player's alert of that kind or by `Observe` once the second has passed; your own call coming back (marked by
  the flag set only around your own send, which the network cannot fake) is always logged and does not use the slot,
  and a call from the network that only carries your id is labelled as such and counted like another player's. The
  verbose lines name no player, only distances: logs get shared.
- `Diag.Observe`, first thing in each frame's `Alerts.Tick`, compares with the frame before - entering or leaving a
  world, dying, an alert that stopped playing, and a waiting alert that stopped waiting without starting (dropped; an
  alert started has its start time after the last look and its sound on the source). After a frame it did not see
  (`VerboseLog` was off), it only takes the state in again.

## Decisions (the requester's, unless noted)

- The cooldown counts **per listener, from any source**: after you heard a launch - yours or a friend's - you hear no
  launch for 30 minutes. Each kind has its own timer, so the arm-then-launch chain still plays.
- Other players hear it **within 100 m** by default, and **each player decides** (`ShareMyAlerts`, `HearOthers`,
  `HearingRange`): no host or server enforcement, and no ServerSync - a vanilla server passes the alerts on anyway.
- No test console command (declined for 1.0.0).
- The two sound files are included. The MIT licence covers the code, not them (a choice made while building it).
- Cooldowns live only in memory and start again when the game restarts (a choice made while building it, to keep it
  harmless). Apart from the settings file BepInEx keeps for it, the only file the plugin writes is its own log (1.1.0,
  the requester's request; above); with `ErrorLog` and `VerboseLog` both off it writes none of its own.
- The log settings are two switches, as the requester put it: `ErrorLog` on by default, `VerboseLog` off; verbose
  includes the errors whatever `ErrorLog` says.
- 2D sound, not positional (a choice made while building it: an alert, not a sound in the world).

## Where the rules are checked

- `tests/` (`dotnet run` there): every decision in `src/AlertRules.cs` - the arm and launch decisions, hearing,
  whether an alert can be heard, the scheduler, the cooldowns, the gap, the volume clamp and the message's bytes. The
  arm decision and whether an alert can be heard are tried with every combination of their inputs, and the message's
  bytes with both kinds and a range of ids; the rest with named cases and simulated streams of alerts. And the log
  file in `src/LogFile.cs`: which lines go in (every combination of the two settings, own source or not, ten level
  sets and eight texts), their format (every level combination), the numbers the README states, and the file itself
  in a temp folder (header, appending across sessions, the 1 MiB rename and a held file or archive left alone, the two
  allowances and their notes, a closed file staying closed, up to five copies, a folder it cannot write staying off).
- `tools/preflight.ps1`: every Harmony target and game member the plugin uses; what the game does that the alerts rely
  on (the `EquipItem` callers and the flag each passes, the `ShowHandItems` callers, where the attack trigger runs);
  and that the game-side code feeds the decisions their inputs from the right places and acts on them the right way
  round; that it writes no file through `System.IO` or BepInEx but through `LogFile`, made once in `Awake` on
  `Paths.BepInExRootPath`, whose paths
  are that folder and `NuclearTrollstav[.n][.old].log` (and no `DiskLogListener` or `ConfigFile` of its own); that
  the listener's `ShouldWrite` gets the two settings, the line's source and level and decides the write, and its
  failure warning cannot re-enter; and that the verbose lines only read, go only to the file, and are reached only
  from the eight reviewed calls behind `Diag.Verbose`. It reads exact instruction shapes, so the lines and methods
  marked `preflight:` in `src/` can fail it even when rewritten harmlessly; change the check with them.
- Not checked by either: the verbose lines' own wording and timing - the received-alert throttle and its count, and
  `Diag.Observe`'s transitions - which run only in the game. A change to them needs a careful read and a run in a
  harness outside the game.

## After a Valheim update

1. Build, run the tests, and run `tools/preflight.ps1` against the updated game. Then read again what preflight does
   not check - at least that `Humanoid.StartAttack` still makes a new `Attack` for every cast (the launch patch alerts
   once per `Attack` object and forgets the last one only when the player leaves the world, so a reused one would
   silence every later launch until then), that `AudioMan.SetSFXVolume` still writes `GuiVol` with `SfxVol`, and that
   `ZRoutedRpc` still passes a call for everybody on without knowing its name.
2. A FAIL under "what the game does that the triggers rely on", or the FAIL "Attack.OnAttackTrigger callers changed"
   (just before the assembly references), means the game changed a path the alerts depend on (a new caller of
   `EquipItem`, a changed flag, a moved attack trigger): read that part of the game again before trusting the alerts,
   and update the check with what was found.
3. A FAIL on a Harmony target means the game renamed, removed or changed that method (a new overload, or a parameter
   or field the patch reads): that patch class is off (if only a parameter's or field's type changed, Harmony may
   apply it anyway, with a value of the wrong type), and the others stay applied (each is applied on its own). What
   that class did stops with it: with `PickupPatch` or `ShowHandItemsPatch` off, the arm alert also plays for the equip
   that class marks, and with `GameStartPatch` off, other players are heard only after you set off an alert yourself
   with `ShareMyAlerts` on. A FAIL on another game member (renamed, removed, made private or changed)
   can stop much more: the code that uses it throws when it runs, and a member used by the audibility check or the
   per-frame update (`Alerts.Audible`, `Alerts.Tick`) stops every alert and all sharing. Fix it before playing with
   the plugin.
