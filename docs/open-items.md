# Open items and future work

The one list of what is untested, unverified, open or only an idea - so none of it has to be worked out again. Keep it
current: add an item when it comes up, and when one is done, move it to "Done" with the version or commit that did it.
How the plugin works, and why, is in `design.md`.

Last updated: 2026-09-29, after v1.0.0.

## Not yet tried in play

v1.0.0 was played in single player only (both sounds, the arm-then-launch chain, the cooldown), on Windows.
- **Two or more players with the plugin:** hearing another player's alerts, the 100 m range, a player out of range or
  not loaded, a player with `HearOthers` or `ShareMyAlerts` off, and that your own alert is not played twice.
- **Where the other players are:** a Start Server host, a player who joined a friend's game, a dedicated server, and a
  crossplay game.
- **Logging in while already holding the staff:** should play nothing (the game re-equips it as a non-choice);
  checked against the game's code, not yet seen in play.
- **Your own sound files:** another MP3 in the settings, and a path whose folder names contain `#` or `%` (it is not
  known whether Unity's loader handles those).
- **The game's volume settings:** moving Volume or Effect volume should scale an alert while it plays, and at 0 an
  alert should be skipped (logged as "could not be heard now"); it rests on the game's code and on its audio asset
  read offline, not yet seen in play.

## Not verified

- The staff's attack animation reaches its trigger once, about 1.3 s into the cast (read from the game's data, not
  confirmed in play). The plugin takes one alert per cast either way.
- Which of the two ways of finding the game's GUI mixer group finds it in play (both are in the code; the log says
  only that it was found).
- How loud the two MP3s are compared with the game's own sounds. The plugin guarantees only that they are never above
  the game's volume settings.
- Which draw distance a fresh game install starts with (the README names the game's code default; a first-start
  preset may set another), and so how far away another player is loaded, and heard, by default.

## Watching other mods

- **AzuExtendedPlayerInventory:** in 2.4.14, equipping a loadout always re-equips with `triggerEquipEffects` false,
  so it plays no arm alert. Two paths in it would behave differently, but 2.4.14 never reaches them: its
  `PersonalLoadoutGuiDetails` panel (it equips with true) is never created, and its `UnequipToBags` (which, with a full
  bag, puts the item back with true) is never called. If a later version starts using either, one loadout panel would
  play the arm alert and the other would not, and a full-bag "unequip to bags" could play one nobody chose. Then:
  decide whether equipping a loadout counts as taking the staff in hand; to skip it, mark those calls with a Prefix
  and a Finalizer as `PickupPatch` does and add the mark to `AlertRules.ArmOnEquip`.
- **AzuExtendedPlayerInventory, taking your tombstone:** with its Auto-Equip Items on (the default), 2.4.14 re-equips
  every item in its equipment-slot cells with `triggerEquipEffects` true. Its built-in slots hold only armour, capes,
  utility items and trinkets, so the staff is never among them - unless a custom equipment slot is set up for
  `StaffRedTroll`; then taking your tombstone plays an arm alert nobody chose.

## Small fixes still open

- The launch MP3's tag carries container details from its re-encoding (`major_brand=dash` and the like): harmless;
  removing them would change the file, so only if wanted.
- Two code comments in `src/Sharing.cs` (the class summary, and the `FindLoadedPlayer` call in `OnAlert`) still say
  a character the listener has not loaded is far away, or not near; `design.md` says it is treated as out of range
  (the two lowest draw distances load less than 100 m in some directions). Align them with the next code change.
- The comment above preflight's check of Harmony patch parameters says Harmony refuses a patch whose parameter is not
  typed like the target's; by HarmonyX 2.9's code (read, not run) it matches parameters and fields by name only. Drop
  "(and typed)" there with the next change; the check itself is right to fail on a type change.

## Ideas (not planned)

- Keep the cooldowns across game restarts (it would need a small file of the plugin's own; today it writes none).
- An on/off setting per alert. Today `Volume` 0 silences both, and `ShareMyAlerts` and `HearOthers` cover the sharing.
- Other sound formats (OGG, WAV) chosen by the file's extension.
- A positional option, so other players' alerts come from where they are.
- A local test command that plays both sounds, ignoring the cooldown, for trying the volume (declined for 1.0.0).
- A mutation-test script in this repository that plants a defect for each of preflight's checks and shows the check
  fails. The checks were proven that way while 1.0.0 was built, with a script kept outside the repository.

## Decided - reopen only with a new reason (see design.md)

- The cooldown counts per listener, from any source; each kind has its own timer.
- Each player decides on sharing and hearing; no host or server enforcement, no ServerSync.
- The message carries no position (design.md, "Why no position").
- Drawing the weapons again (the hide/show key, or the weapons given back when the hammer is put away through the
  radial menu) counts as taking the staff in hand.
- The two MP3s are included in the repository and the release zip; the MIT licence does not cover them.

## Done

- After v1.0.0, on `main` (text only, the v1.0.0 zip keeps the old wording): the README names the tools' third way of
  finding the game (the default path, as for the build), says `retired/` is the repository's git-ignored folder, and
  says another player's refused alert gets "the same kind of line" and what a cinematic does to an alert; two code
  comments no longer name an internal review; this file and `design.md` were added, and the README points to both.
