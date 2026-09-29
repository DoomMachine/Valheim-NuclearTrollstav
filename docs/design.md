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

## Decisions (the requester's, unless noted)

- The cooldown counts **per listener, from any source**: after you heard a launch - yours or a friend's - you hear no
  launch for 30 minutes. Each kind has its own timer, so the arm-then-launch chain still plays.
- Other players hear it **within 100 m** by default, and **each player decides** (`ShareMyAlerts`, `HearOthers`,
  `HearingRange`): no host or server enforcement, and no ServerSync - a vanilla server passes the alerts on anyway.
- No test console command (declined for 1.0.0).
- The two sound files are included. The MIT licence covers the code, not them (a choice made while building it).
- Cooldowns live only in memory and start again when the game restarts: the plugin writes no file of its own - BepInEx
  keeps its settings file and its log lines (a choice made while building it, to keep it harmless).
- 2D sound, not positional (a choice made while building it: an alert, not a sound in the world).

## Where the rules are checked

- `tests/` (`dotnet run` there): every decision in `src/AlertRules.cs` - the arm and launch decisions, hearing,
  whether an alert can be heard, the scheduler, the cooldowns, the gap, the volume clamp and the message's bytes. The
  arm decision and whether an alert can be heard are tried with every combination of their inputs, and the message's
  bytes with both kinds and a range of ids; the rest with named cases and simulated streams of alerts.
- `tools/preflight.ps1`: every Harmony target and game member the plugin uses; what the game does that the alerts rely
  on (the `EquipItem` callers and the flag each passes, the `ShowHandItems` callers, where the attack trigger runs);
  and that the game-side code feeds the decisions their inputs from the right places and acts on them the right way
  round. It reads exact instruction shapes, so the lines and methods marked `preflight:` in `src/` can fail it even
  when rewritten harmlessly; change the check with them.

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
