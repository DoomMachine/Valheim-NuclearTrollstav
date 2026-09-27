using System;
using System.Collections.Generic;

namespace NuclearTrollstav
{
    /// <summary>The two alerts. The numbers travel in the network message, so they never change.</summary>
    public enum AlertKind
    {
        Arm = 0,      // Trollstav equipped
        Launch = 1,   // Trollstav used
    }

    /// <summary>What happened to an alert offered to the scheduler.</summary>
    public enum OfferResult
    {
        Accepted,
        OnCooldown,
        AlreadyWaiting,
        Invalid,
    }

    /// <summary>
    /// Decides, for this player alone, which alert plays and when - with no Unity in it, so the tests can drive it.
    /// Every alert heard here (this player's own and every other player's) goes through one scheduler:
    /// - each kind plays at most once per cooldown, whoever triggered it, counted between the moments two alerts of
    ///   that kind start playing. An accepted alert holds its kind from the moment it is accepted, so a second one
    ///   arriving while the first still waits is refused too; an accepted alert that never plays (it waited too long,
    ///   the world was left, or it could not start) gets the cooldown back as it was;
    /// - one alert plays at a time, and the next starts only after the previous one has finished plus the gap;
    /// - at most one alert of each kind waits; when both wait, the arm alert goes first, so a launch heard from one
    ///   player never plays before an arm alert heard from another - but a launch that waited through one arm alert
    ///   goes before the next, so arm alerts can never hold it back for good.
    /// Times are seconds on one monotonic clock chosen by the caller.
    /// </summary>
    public sealed class AlertScheduler
    {
        public const int KindCount = 2;

        private readonly double[] _lastAccepted = new double[KindCount];
        private readonly double[] _acceptedBefore = new double[KindCount];   // to undo an acceptance that never played
        private readonly List<AlertKind> _waiting = new List<AlertKind>(KindCount);
        private bool _launchOwed;                             // an arm alert went before a waiting launch: the launch is next
        private bool _busy;                                   // an alert was handed out and has not finished yet
        private double _idleSince = double.NegativeInfinity;  // when the last alert finished

        public AlertScheduler()
        {
            for (int i = 0; i < KindCount; i++) _lastAccepted[i] = _acceptedBefore[i] = double.NegativeInfinity;
        }

        public static bool IsValidKind(int kind)
        {
            return kind >= 0 && kind < KindCount;
        }

        /// <summary>Number of alerts accepted and not yet handed out.</summary>
        public int WaitingCount { get { return _waiting.Count; } }

        /// <summary>Seconds until an alert of this kind would be accepted again (0 when it would be now).</summary>
        public double CooldownLeft(AlertKind kind, double now, double cooldownSeconds)
        {
            int k = (int)kind;
            if (!IsValidKind(k) || !(cooldownSeconds > 0)) return 0;
            double left = _lastAccepted[k] + cooldownSeconds - now;
            return left > 0 ? left : 0;
        }

        /// <summary>
        /// Offers an alert at time <paramref name="now"/>. Accepted means it will play unless it cannot start in time;
        /// the other results mean it never will. A cooldown of zero or less (or NaN) means no cooldown.
        /// </summary>
        public OfferResult Offer(AlertKind kind, double now, double cooldownSeconds)
        {
            int k = (int)kind;
            if (!IsValidKind(k) || double.IsNaN(now) || double.IsInfinity(now)) return OfferResult.Invalid;
            if (_waiting.Contains(kind)) return OfferResult.AlreadyWaiting;
            if (cooldownSeconds > 0 && now - _lastAccepted[k] < cooldownSeconds) return OfferResult.OnCooldown;
            _acceptedBefore[k] = _lastAccepted[k];
            _lastAccepted[k] = now;
            _waiting.Add(kind);
            return OfferResult.Accepted;
        }

        /// <summary>
        /// Called every frame.
        /// <paramref name="channelPlaying"/>: whether the alert handed out last is still sounding.
        /// <paramref name="canStart"/>: whether an alert could be heard now (sound loaded, not muted by a cinematic...);
        /// while it is false, alerts wait.
        /// <paramref name="maxWaitSeconds"/>: an alert that still cannot start this long after its turn came (after it was
        /// accepted, and after the alert before it and the gap) is dropped and gets its cooldown back. Time spent waiting
        /// for another alert to finish never counts, however long that alert's sound is.
        /// Returns the alert to start now, or null. After a non-null return the caller must start it, or call
        /// <see cref="Cancel"/> - the scheduler counts the channel busy until a tick reports it silent.
        /// </summary>
        public AlertKind? Tick(double now, bool channelPlaying, double gapSeconds, bool canStart, double maxWaitSeconds)
        {
            double gap = gapSeconds > 0 ? gapSeconds : 0;   // NaN and negatives mean no gap
            if (channelPlaying)
            {
                _busy = true;
                return null;
            }
            if (_busy)
            {
                _busy = false;
                _idleSince = now;
            }
            for (int i = _waiting.Count - 1; i >= 0; i--)
            {
                int k = (int)_waiting[i];
                double turn = Math.Max(_lastAccepted[k], _idleSince + gap);   // when it could first have started
                if (now - turn > maxWaitSeconds)
                {
                    _lastAccepted[k] = _acceptedBefore[k];
                    _waiting.RemoveAt(i);
                    if (k == (int)AlertKind.Launch) _launchOwed = false;
                }
            }
            if (_waiting.Count == 0 || !canStart) return null;
            if (now < _idleSince + gap) return null;
            // The arm alert first - but a launch that already waited through one arm alert goes before the next one,
            // so a stream of arm alerts (with no cooldown) can never hold a launch back until it is dropped.
            int armAt = _waiting.IndexOf(AlertKind.Arm);
            int launchAt = _waiting.IndexOf(AlertKind.Launch);
            int at = _launchOwed && launchAt >= 0 ? launchAt : (armAt >= 0 ? armAt : 0);
            AlertKind next = _waiting[at];
            _waiting.RemoveAt(at);
            _launchOwed = next == AlertKind.Arm && launchAt >= 0;
            _lastAccepted[(int)next] = now;   // the cooldown runs from when it starts playing
            _busy = true;
            return next;
        }

        /// <summary>
        /// The alert just handed out could not be started: it gets its cooldown back, and an arm alert that never sounded
        /// leaves no launch owed a turn.
        /// </summary>
        public void Cancel(AlertKind kind)
        {
            int k = (int)kind;
            if (!IsValidKind(k)) return;
            _lastAccepted[k] = _acceptedBefore[k];
            if (kind == AlertKind.Arm) _launchOwed = false;
        }

        /// <summary>
        /// Drops the alerts still waiting (leaving a world). A dropped alert never played, so its cooldown goes back to
        /// what it was before it was accepted.
        /// </summary>
        public void DropWaiting()
        {
            foreach (AlertKind kind in _waiting)
            {
                _lastAccepted[(int)kind] = _acceptedBefore[(int)kind];
            }
            _waiting.Clear();
            _launchOwed = false;
        }
    }

    /// <summary>The sender's own limit on how often it tells the others: never more than once per interval per kind.</summary>
    public sealed class SendThrottle
    {
        private readonly double[] _lastSent = new double[AlertScheduler.KindCount];

        public SendThrottle()
        {
            for (int i = 0; i < _lastSent.Length; i++) _lastSent[i] = double.NegativeInfinity;
        }

        public bool TryPass(AlertKind kind, double now, double intervalSeconds)
        {
            int k = (int)kind;
            if (!AlertScheduler.IsValidKind(k)) return false;
            if (now - _lastSent[k] < intervalSeconds) return false;
            _lastSent[k] = now;
            return true;
        }
    }

    /// <summary>
    /// The plugin's numbers and decisions, with no Unity in them, so the tests can hold them to the user's words.
    /// The game-side code only gathers the inputs and calls these.
    /// </summary>
    public static class AlertRules
    {
        public const double GapSeconds = 1.0;           // the pause between one alert's end and the next one's start
        public const double MaxWaitSeconds = 30.0;      // an alert that could not start within this long is dropped
        public const double SendIntervalSeconds = 5.0;  // never tell the others about one kind more often than this
        public const double RefusalLogSeconds = 10.0;   // another player's refused alert is logged at most this often per kind
        public const float DefaultVolume = 0.5f;
        public const float DefaultCooldownMinutes = 30f;
        public const float DefaultHearingRange = 100f;
        public const string TrollstavPrefab = "StaffRedTroll";
        public const string TrollstavToken = "$item_staffredtroll";

        /// <summary>The cooldown setting in seconds; zero, negative or NaN minutes mean no cooldown.</summary>
        public static double CooldownSeconds(float minutes)
        {
            return minutes > 0f ? minutes * 60.0 : 0.0;
        }

        /// <summary>Trollstav, by its prefab's name or by its name token (either may be null).</summary>
        public static bool IsTrollstav(string prefabName, string nameToken)
        {
            return prefabName == TrollstavPrefab || nameToken == TrollstavToken;
        }

        /// <summary>True when the item is one of the two hand items (compared as references).</summary>
        public static bool InHand(object item, object rightItem, object leftItem)
        {
            return item != null && (ReferenceEquals(item, rightItem) || ReferenceEquals(item, leftItem));
        }

        /// <summary>
        /// The arm alert, decided after Humanoid.EquipItem: the staff went from not held to held, the game said the
        /// equip is the player's own (triggerEquipEffects - false when it puts saved gear back on at login, respawn and
        /// world load, and for inventory drags), on the local player, and not by the automatic equip of a pickup nor the
        /// restore after eating.
        /// </summary>
        public static bool ArmOnEquip(bool inHandBefore, bool triggerEquipEffects, object equipper, object localPlayer,
            object item, object rightAfter, object leftAfter, bool isTrollstav, int pickupDepth, bool eatRestore)
        {
            return !inHandBefore && triggerEquipEffects && localPlayer != null && ReferenceEquals(equipper, localPlayer)
                   && InHand(item, rightAfter, leftAfter) && isTrollstav && pickupDepth <= 0 && !eatRestore;
        }

        /// <summary>The launch alert: a new attack (never the same one twice) by the local player, with Trollstav.</summary>
        public static bool LaunchOnAttack(object attack, object lastLaunched, object attacker, object localPlayer, bool isTrollstav)
        {
            return attack != null && !ReferenceEquals(attack, lastLaunched) && localPlayer != null
                   && ReferenceEquals(attacker, localPlayer) && isTrollstav;
        }

        /// <summary>
        /// Whether an alert could be heard right now: its sound is loaded, the player is in a world and alive, the audio
        /// source exists (it only exists routed to the game's mixer), the plugin's volume is above 0, no cinematic has
        /// muted the game, and the game's own listener and effect volumes are above 0. While it cannot, an alert is not
        /// accepted (so no cooldown is spent on a sound nobody hears) and a waiting one does not start.
        /// </summary>
        public static bool Audible(bool clipLoaded, bool inWorld, bool listenerAlive, bool sourceReady, float volume,
            bool cinematicPlaying, float listenerVolume, bool audioManPresent, float gameEffectVolume)
        {
            return clipLoaded && inWorld && listenerAlive && sourceReady && volume > 0f && !cinematicPlaying
                   && listenerVolume > 0f && audioManPresent && gameEffectVolume > 0f;
        }

        /// <summary>
        /// Whether this player hears another player's alert: hearing is on, it is not this player's own call coming back
        /// (the send in progress, or the sender id is ours, or the character is ours), both characters are there and this
        /// one is alive, and the distance (dx, dy, dz from the listener) is within the range.
        /// </summary>
        public static bool MayHear(bool hearOthers, bool inLocalSend, long sender, long ownUid, object source, object listener,
            bool listenerDead, float dx, float dy, float dz, float range)
        {
            return hearOthers && !inLocalSend && sender != ownUid && source != null && listener != null && !listenerDead
                   && !ReferenceEquals(source, listener) && WithinRange(dx, dy, dz, range);
        }

        /// <summary>
        /// True when a point at offset (dx, dy, dz) from the listener is within <paramref name="range"/> metres,
        /// measured in 3D (so a player inside a dungeon, 5000 m up, is not near one standing below it). A range of zero
        /// or less, or any value that is not a finite number, means nobody is in range.
        /// </summary>
        public static bool WithinRange(float dx, float dy, float dz, float range)
        {
            if (!IsFinite(dx) || !IsFinite(dy) || !IsFinite(dz) || !IsFinite(range) || range <= 0f) return false;
            double d2 = (double)dx * dx + (double)dy * dy + (double)dz * dz;
            return d2 <= (double)range * range;
        }

        public static bool IsFinite(float f)
        {
            return !float.IsNaN(f) && !float.IsInfinity(f);
        }

        /// <summary>Clamps a volume setting to 0..1: never louder than the game's own sliders allow.</summary>
        public static float ClampVolume(float v)
        {
            if (float.IsNaN(v) || v <= 0f) return 0f;
            return v >= 1f ? 1f : v;
        }
    }

    /// <summary>
    /// The shared message, version 1, forever under its call name (a different layout gets a new name): 14 bytes,
    /// little-endian - byte version = 1, byte kind (AlertKind), long character ZDOID user, uint character ZDOID id.
    /// No position. Later versions may append fields; version 1 ignores anything after its own 14 bytes.
    /// </summary>
    public static class AlertWire
    {
        public const byte Version = 1;
        public const int Length = 14;

        public static byte[] Encode(AlertKind kind, long user, uint id)
        {
            byte[] b = new byte[Length];
            b[0] = Version;
            b[1] = (byte)kind;
            ulong u = (ulong)user;
            for (int i = 0; i < 8; i++) b[2 + i] = (byte)(u >> (8 * i));
            for (int i = 0; i < 4; i++) b[10 + i] = (byte)(id >> (8 * i));
            return b;
        }

        /// <summary>False for anything that is not a version 1 message of a known kind.</summary>
        public static bool TryDecode(byte[] b, out AlertKind kind, out long user, out uint id)
        {
            kind = AlertKind.Arm;
            user = 0;
            id = 0;
            if (b == null || b.Length < Length || b[0] != Version || !AlertScheduler.IsValidKind(b[1])) return false;
            kind = (AlertKind)b[1];
            ulong u = 0;
            for (int i = 7; i >= 0; i--) u = (u << 8) | b[2 + i];
            user = (long)u;
            uint v = 0;
            for (int i = 3; i >= 0; i--) v = (v << 8) | b[10 + i];
            id = v;
            return true;
        }
    }
}
