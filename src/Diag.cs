using System;
using BepInEx.Configuration;
using UnityEngine;

namespace NuclearTrollstav
{
    /// <summary>
    /// The VerboseLog lines: what the plugin sees and decides, for watching one event closely. Each call site reads
    /// "if (Diag.Verbose) Diag.X(...)", so with VerboseLog off none of this runs. Every method here only reads - it
    /// never changes what the plugin does (preflight checks that it calls nothing in the plugin but a list of readers)
    /// - and each entry point catches its own errors, its error report included, so a fault in a log line can never
    /// stop an alert. The lines go straight into the plugin's own file (FileLogListener.WriteVerbose), never through
    /// BepInEx, which would copy them into the game's Player.log too. No player names: logs get shared.
    /// </summary>
    internal static class Diag
    {
        private const double ReceiveLogSeconds = 1.0;   // a received alert of one kind is logged at most this often

        private static int _errors;

        // Observe's view of the frame before.
        private static bool _seen;
        private static int _lastFrame;
        private static double _lastNow;
        private static bool _wasInWorld;
        private static bool _wasAlive;
        private static bool _wasSounding;
        private static readonly bool[] WasWaiting = new bool[AlertScheduler.KindCount];
        private static readonly bool[] Waiting = new bool[AlertScheduler.KindCount];

        // Receive's throttle: when each kind was last logged, and how many arrived since without a line.
        private static readonly double[] ReceiveLoggedAt = { double.NegativeInfinity, double.NegativeInfinity };
        private static readonly int[] ReceiveSkipped = new int[AlertScheduler.KindCount];

        public static bool Verbose
        {
            get { return Plugin.VerboseLog != null && Plugin.VerboseLog.Value; }
        }

        private static void Line(string text)
        {
            FileLogListener file = Plugin.FileLog;
            if (file != null) file.WriteVerbose(text);
        }

        private static void Report(Exception e)
        {
            try
            {
                Plugin.LogThrottled(ref _errors, "A verbose log line failed", e);
            }
            catch (Exception)
            {
                // The report itself goes through BepInEx; if that throws, the line is lost, not the alert.
            }
        }

        /// <summary>Every setting, when the game starts with VerboseLog on.</summary>
        public static void Settings()
        {
            try
            {
                Line(string.Format("Settings: Volume {0}, ArmSound {1}, LaunchSound {2}, CooldownMinutes {3}, ShareMyAlerts {4}, "
                                   + "HearOthers {5}, HearingRange {6} m, ErrorLog {7}, VerboseLog {8}.",
                    Plugin.Volume.Value, Plugin.ArmSoundFile.Value, Plugin.LaunchSoundFile.Value, Plugin.CooldownMinutes.Value,
                    Plugin.ShareMyAlerts.Value, Plugin.HearOthers.Value, Plugin.HearingRange.Value, Plugin.ErrorLog.Value,
                    Plugin.VerboseLog.Value));
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>A setting changed while the game runs (a configuration manager).</summary>
        public static void SettingChanged(SettingChangedEventArgs args)
        {
            try
            {
                ConfigEntryBase entry = args != null ? args.ChangedSetting : null;
                if (entry == null) return;
                Line("Setting changed: " + entry.Definition.Section + "." + entry.Definition.Key + " = " + entry.BoxedValue + ".");
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>The local player's Humanoid.EquipItem, with every input of the arm decision and its outcome.</summary>
        public static void Equip(Humanoid equipper, ItemDrop.ItemData item, bool triggerEquipEffects, bool inHandBefore)
        {
            try
            {
                Player me = Player.m_localPlayer;
                if (me == null || !ReferenceEquals(equipper, me)) return;   // the local player's equips only
                bool isTrollstav = Trollstav.Is(item);
                bool inHandAfter = AlertRules.InHand(item, equipper.RightItem, equipper.LeftItem);
                bool arm = AlertRules.ArmOnEquip(inHandBefore, triggerEquipEffects, equipper, me, item, equipper.RightItem,
                    equipper.LeftItem, isTrollstav, PickupPatch.Depth, ShowHandItemsPatch.EatRestore);
                Line(string.Format("Equip: {0} - Trollstav {1}, chosen by the player (triggerEquipEffects) {2}, in hand before {3}, "
                                   + "after {4}, picked up {5}, back after eating {6} -> {7}.",
                    ItemName(item), isTrollstav, triggerEquipEffects, inHandBefore, inHandAfter, PickupPatch.Depth > 0,
                    ShowHandItemsPatch.EatRestore, arm ? "arm alert" : "no alert"));
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>The local player's projectile attack firing, with the launch decision's inputs.</summary>
        public static void Attack(Attack attack, Humanoid attacker, Attack lastLaunched)
        {
            try
            {
                Player me = Player.m_localPlayer;
                if (me == null || !ReferenceEquals(attacker, me)) return;   // the local player's attacks only
                ItemDrop.ItemData weapon = attack != null ? attack.GetWeapon() : null;
                bool isTrollstav = Trollstav.Is(weapon);
                bool launch = AlertRules.LaunchOnAttack(attack, lastLaunched, attacker, me, isTrollstav);
                Line(string.Format("Projectile attack fired: {0} - Trollstav {1}, this cast already alerted {2} -> {3}.",
                    ItemName(weapon), isTrollstav, attack != null && ReferenceEquals(attack, lastLaunched),
                    launch ? "launch alert" : "no alert"));
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>
        /// An alert this player set off, after the plugin took it or refused it: whether it can be heard (each input,
        /// as the decision just read them), whether it now waits to play, its cooldown, and sharing.
        /// </summary>
        public static void Local(AlertKind kind)
        {
            try
            {
                Line(string.Format("{0} set off by you. {1} Waiting to play now {2}, next one possible in {3:0.#} min (and not while one is waiting), ShareMyAlerts {4}.",
                    Alerts.Label(kind), Audibility(kind), Alerts.IsWaiting(kind), Alerts.CooldownLeft(kind) / 60.0,
                    Plugin.ShareMyAlerts.Value));
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>Sending an alert to the other players.</summary>
        public static void Sending(AlertKind kind)
        {
            try
            {
                Line(Alerts.Label(kind) + ": telling the other players (one call to everybody; only those with the plugin "
                     + "and within their own range hear it).");
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>
        /// An alert arrived through the network: who (by distance, never a name) and the hearing decision's inputs.
        /// Other players' alerts get at most one line per kind a second (any client can send these); the ones not
        /// logged are counted, and the count is written with the next line or by Observe once the second has passed.
        /// Your own call coming back (it runs at once, inside your send) is always logged and never uses the slot.
        /// </summary>
        public static void Receive(AlertKind kind, long sender, bool inLocalSend, Player source, Player me, bool meDead, Vector3 d)
        {
            try
            {
                int k = (int)kind;
                if (!AlertScheduler.IsValidKind(k)) return;
                int skipped = 0;
                if (!inLocalSend)   // set only around our own send: the network cannot fake it
                {
                    double now = Alerts.Now;
                    if (now - ReceiveLoggedAt[k] < ReceiveLogSeconds)
                    {
                        ReceiveSkipped[k]++;
                        return;
                    }
                    ReceiveLoggedAt[k] = now;
                    skipped = ReceiveSkipped[k];
                    ReceiveSkipped[k] = 0;
                }
                bool hear = AlertRules.MayHear(Plugin.HearOthers.Value, inLocalSend, sender, ZNet.GetUID(), source, me, meDead,
                    d.x, d.y, d.z, Plugin.HearingRange.Value);
                string from;
                if (inLocalSend) from = "your own call coming back";
                else if (sender == ZNet.GetUID()) from = "a call from the network carrying your own id (ignored)";
                else if (me == null) from = "a player (you have no character now - dead or loading - so no distance)";
                else if (source == null) from = "a player this game has not loaded (treated as out of range)";
                else from = string.Format("a player {0:0.0} m away", d.magnitude);
                string you = me == null ? "you: no character" : "you dead " + meDead;
                Line(string.Format("Received: {0} from {1} - HearOthers {2}, HearingRange {3:0} m, {4} -> {5}.{6}",
                    Alerts.Label(kind), from, Plugin.HearOthers.Value, Plugin.HearingRange.Value, you,
                    hear ? "offered to you" : "not heard",
                    skipped > 0 ? " (" + skipped + " more from other players arrived since the last line for another player's alert of this kind, not logged)" : ""));
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>
        /// Called first in every frame's Alerts.Tick: logs what changed since the frame before - entering or leaving a
        /// world, dying, an alert that stopped playing, a waiting alert dropped. After a gap (VerboseLog was off), it only
        /// takes in the state again.
        /// </summary>
        public static void Observe()
        {
            try
            {
                int frame = Time.frameCount;
                double now = Alerts.Now;
                bool inWorld = ZNet.instance != null;
                bool alive = Alerts.ListenerAlive();
                bool sounding = Alerts.Sounding;
                bool[] waiting = Waiting;   // reused: this runs every frame while VerboseLog is on
                for (int k = 0; k < waiting.Length; k++) waiting[k] = Alerts.IsWaiting((AlertKind)k);
                if (_seen && frame == _lastFrame + 1)
                {
                    if (inWorld && !_wasInWorld) Line("In a world.");
                    if (!inWorld && _wasInWorld) Line("Left the world: alerts still waiting are dropped, a playing one stops.");
                    if (inWorld && _wasInWorld && _wasAlive && !alive) Line("You died (or your character is gone): alerts still waiting are dropped.");
                    if (inWorld && !_wasAlive && alive) Line("Your character is alive in the world.");
                    if (_wasSounding && !sounding) Line("The alert stopped playing.");
                    for (int k = 0; k < ReceiveSkipped.Length; k++)
                    {
                        if (ReceiveSkipped[k] > 0 && now - ReceiveLoggedAt[k] >= ReceiveLogSeconds)
                        {
                            Line(Alerts.Label((AlertKind)k) + ": " + ReceiveSkipped[k] + " more from other players received within a "
                                 + "second of the last one logged, not logged.");
                            ReceiveSkipped[k] = 0;
                        }
                    }
                    // An alert started in the frame before has its start time after the last look, and its sound on the source.
                    AlertKind? started = Alerts.StartedAt >= _lastNow ? Alerts.ClipKind : null;
                    for (int k = 0; k < waiting.Length; k++)
                    {
                        if (WasWaiting[k] && !waiting[k] && started != (AlertKind)k)
                        {
                            Line(Alerts.Label((AlertKind)k) + " is no longer waiting and did not start: dropped (it could not start "
                                 + "within " + AlertRules.MaxWaitSeconds + " s of its turn, you left the world or died, or it "
                                 + "could not be started).");
                        }
                    }
                }
                _seen = true;
                _lastFrame = frame;
                _lastNow = now;
                _wasInWorld = inWorld;
                _wasAlive = alive;
                _wasSounding = sounding;
                for (int k = 0; k < waiting.Length; k++) WasWaiting[k] = waiting[k];
            }
            catch (Exception e) { Report(e); }
        }

        /// <summary>Each input of AlertRules.Audible, read without changing anything (the audio source is not made here).</summary>
        private static string Audibility(AlertKind kind)
        {
            bool clip = Alerts.ClipLoaded(kind);
            bool inWorld = ZNet.instance != null;
            bool alive = Alerts.ListenerAlive();
            bool source = Alerts.SourceReady;
            float volume = AlertRules.ClampVolume(Plugin.Volume.Value);
            bool cinematic = CinematicsManager.IsStartedPlaying();
            float listener = AudioListener.volume;
            bool audioMan = AudioMan.instance != null;
            float effects = AudioMan.GetSFXVolume();   // what the decision reads; the game returns 1 without an AudioMan
            bool audible = AlertRules.Audible(clip, inWorld, alive, source, volume, cinematic, listener, audioMan, effects);
            return string.Format("Can be heard: {0} (sound loaded {1}, in a world {2}, alive {3}, audio source on the game's "
                                 + "mixer {4}, Volume {5:0.##}, cinematic playing {6}, game listener volume {7:0.##}, game audio "
                                 + "{8}, game effect volume {9:0.##}).",
                audible, clip, inWorld, alive, source, volume, cinematic, listener, audioMan, effects);
        }

        private static string ItemName(ItemDrop.ItemData item)
        {
            if (item == null) return "nothing";
            if (item.m_dropPrefab != null) return item.m_dropPrefab.name;
            return item.m_shared != null ? item.m_shared.m_name : "?";
        }
    }
}
