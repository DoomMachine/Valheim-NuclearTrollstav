using System;
using System.Collections.Generic;

namespace NuclearTrollstav
{
    /// <summary>
    /// Tests of the rules that need no game (src/AlertRules.cs, compiled in from the real source file).
    /// Run with "dotnet run" from this folder; exits 1 on any failure.
    /// </summary>
    public static partial class TestMain
    {
        private static int _failures;
        private static int _passes;

        private const double Cooldown = 30 * 60;   // the default, 30 minutes
        private const double Gap = 1.0;            // the default, 1 second
        private const double ArmLength = 4.6;      // Nuclear Silo Arm.mp3, about 4.6 s
        private const double LaunchLength = 12.6;  // Nuclear Missile Launch Sound.mp3, about 12.6 s
        private const double MaxWait = 30.0;       // the plugin's own limit on waiting

        public static int Main()
        {
            Group("chain", ChainTests);
            Group("overlap", OverlapTests);
            Group("cooldown", CooldownTests);
            Group("play-start cooldown", PlayStartCooldownTests);
            Group("waiting", WaitingTests);
            Group("arm first", ArmFirstTests);
            Group("gate", GateTests);
            Group("max wait", MaxWaitTests);
            Group("cancel", CancelTests);
            Group("drop", DropTests);
            Group("invalid", InvalidTests);
            Group("range", RangeTests);
            Group("volume", VolumeTests);
            Group("throttle", ThrottleTests);
            Group("numbers", NumbersTests);
            Group("identity", IdentityTests);
            Group("arm decision", ArmDecisionTests);
            Group("launch decision", LaunchDecisionTests);
            Group("hearing", HearingTests);
            Group("wire", WireTests);
            Group("audible", AudibleTests);
            Group("no starving", StarveTests);
            Group("owed turn", OwedTests);
            Group("long sounds", LongSoundTests);
            Group("is waiting", IsWaitingTests);
            Group("log filter", LogFilterTests);
            Group("log format", LogFormatTests);
            Group("log file", LogFileTests);
            Console.WriteLine(_failures == 0
                ? "ALL TESTS PASSED (" + _passes + ")"
                : _failures + " TEST(S) FAILED, " + _passes + " passed");
            return _failures == 0 ? 0 : 1;
        }

        /// <summary>Runs one group; an exception fails that group and the others still run.</summary>
        private static void Group(string name, Action tests)
        {
            try
            {
                tests();
            }
            catch (Exception e)
            {
                _failures++;
                Console.WriteLine("FAIL " + name + " threw " + e.GetType().Name + ": " + e.Message);
            }
        }

        /// <summary>
        /// A fake channel: plays one clip at a time, for its length, and records every start. The scheduler is ticked
        /// every 10 ms, as a game running at 100 frames per second would.
        /// </summary>
        private sealed class Channel
        {
            public readonly List<KeyValuePair<AlertKind, double>> Starts = new List<KeyValuePair<AlertKind, double>>();
            private double _endsAt = double.NegativeInfinity;
            public bool Playing(double now) { return now < _endsAt; }
            public void Start(AlertKind kind, double now)
            {
                Starts.Add(new KeyValuePair<AlertKind, double>(kind, now));
                _endsAt = now + (kind == AlertKind.Arm ? ArmLength : LaunchLength);
            }
        }

        private static void Run(AlertScheduler s, Channel c, double from, double to, double gap = Gap)
        {
            for (double t = from; t < to; t += 0.01)
            {
                AlertKind? next = s.Tick(t, c.Playing(t), gap, true, MaxWait);
                if (next.HasValue)
                {
                    Check("overlap: nothing starts while another alert sounds", !c.Playing(t), "started at " + t);
                    c.Start(next.Value, t);
                }
            }
        }

        // The user's example: equip Trollstav and use it at once - the arm alert plays, then 1 s, then the launch.
        private static void ChainTests()
        {
            var s = new AlertScheduler();
            var c = new Channel();
            Check("chain: arm accepted", s.Offer(AlertKind.Arm, 0.0, Cooldown) == OfferResult.Accepted, "");
            Run(s, c, 0.0, 0.2);
            Check("chain: launch accepted while the arm alert plays", s.Offer(AlertKind.Launch, 0.2, Cooldown) == OfferResult.Accepted, "");
            Run(s, c, 0.2, 30.0);
            Check("chain: two alerts played", c.Starts.Count == 2, "played " + c.Starts.Count);
            if (c.Starts.Count == 2)
            {
                Check("chain: the arm alert first, at once", c.Starts[0].Key == AlertKind.Arm && c.Starts[0].Value < 0.02, "first " + c.Starts[0].Key + " at " + c.Starts[0].Value);
                double launchAt = c.Starts[1].Value;
                double armEnd = c.Starts[0].Value + ArmLength;
                Check("chain: the launch alert second", c.Starts[1].Key == AlertKind.Launch, "second " + c.Starts[1].Key);
                Check("chain: the launch starts 1 s after the arm alert ends (within one frame)",
                    launchAt >= armEnd + Gap && launchAt < armEnd + Gap + 0.03, "arm ends " + armEnd + ", launch at " + launchAt);
            }

            // The order of arrival is kept: launch first (fired without the arm alert), then an arm alert.
            s = new AlertScheduler();
            c = new Channel();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            Run(s, c, 0.0, 1.0);
            s.Offer(AlertKind.Arm, 1.0, Cooldown);
            Run(s, c, 1.0, 40.0);
            Check("chain: launch then arm, in arrival order", c.Starts.Count == 2 && c.Starts[0].Key == AlertKind.Launch && c.Starts[1].Key == AlertKind.Arm, "");
            if (c.Starts.Count == 2)
            {
                Check("chain: the arm alert waits for the launch to end plus the gap",
                    c.Starts[1].Value >= LaunchLength + Gap, "arm at " + c.Starts[1].Value);
            }

            // The gap is a pause after an alert, not a delay before the first one.
            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 100.0, Cooldown);
            AlertKind? first = s.Tick(100.0, false, Gap, true, MaxWait);
            Check("chain: the first alert starts on the first tick", first == AlertKind.Launch, "");

            // A clip that never starts (the channel stays silent) still counts as a finished alert: the next one waits
            // the gap from then and plays.
            s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            Check("chain: arm handed out", s.Tick(0.0, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            Check("chain: silent channel, launch waits the gap", s.Tick(0.5, false, Gap, true, MaxWait) == null, "");
            Check("chain: then the launch plays", s.Tick(1.6, false, Gap, true, MaxWait) == AlertKind.Launch, "");

            // A gap of zero, a negative gap and NaN all mean no gap; the next alert starts on the first silent tick.
            foreach (double g in new[] { 0.0, -5.0, double.NaN })
            {
                s = new AlertScheduler();
                s.Offer(AlertKind.Arm, 0.0, Cooldown);
                s.Offer(AlertKind.Launch, 0.0, Cooldown);
                s.Tick(0.0, false, g, true, MaxWait);
                s.Tick(0.1, true, g, true, MaxWait);
                Check("chain: gap " + g + " means none", s.Tick(4.7, false, g, true, MaxWait) == AlertKind.Launch, "");
            }
        }

        // Whatever arrives and whenever, two alerts never sound at once.
        private static void OverlapTests()
        {
            var s = new AlertScheduler();
            var c = new Channel();
            double t = 0;
            // Offers of both kinds every 0.37 s for five minutes, cooldown off: the channel is never shared.
            for (int i = 0; i < 800; i++)
            {
                s.Offer(i % 2 == 0 ? AlertKind.Arm : AlertKind.Launch, t, 0);
                Run(s, c, t, t + 0.37);
                t += 0.37;
            }
            Check("overlap: many alerts played one after another", c.Starts.Count > 10, "played " + c.Starts.Count);
            bool spaced = true;
            for (int i = 1; i < c.Starts.Count; i++)
            {
                double prevEnd = c.Starts[i - 1].Value + (c.Starts[i - 1].Key == AlertKind.Arm ? ArmLength : LaunchLength);
                if (c.Starts[i].Value < prevEnd + Gap) spaced = false;
            }
            Check("overlap: every alert starts at least the gap after the previous one ends", spaced, "");
            Check("overlap: never more than one of each kind waiting", s.WaitingCount <= 2, "waiting " + s.WaitingCount);
        }

        // Each kind has its own cooldown; any source counts (the scheduler cannot tell sources apart, by design).
        private static void CooldownTests()
        {
            var s = new AlertScheduler();
            Check("cooldown: first arm accepted", s.Offer(AlertKind.Arm, 0.0, Cooldown) == OfferResult.Accepted, "");
            s.Tick(0.0, false, Gap, true, MaxWait);
            Check("cooldown: the launch has its own timer", s.Offer(AlertKind.Launch, 1.0, Cooldown) == OfferResult.Accepted, "");
            s.Tick(1.0, true, Gap, true, MaxWait);    // the arm alert sounds
            s.Tick(4.6, false, Gap, true, MaxWait);   // and ends
            Check("cooldown: the launch plays after it", s.Tick(5.7, false, Gap, true, MaxWait) == AlertKind.Launch, "");
            Check("cooldown: a second arm 10 s later is refused", s.Offer(AlertKind.Arm, 10.0, Cooldown) == OfferResult.OnCooldown, "");
            Check("cooldown: an arm at 29:59.9 is refused", s.Offer(AlertKind.Arm, Cooldown - 0.1, Cooldown) == OfferResult.OnCooldown, "");
            Check("cooldown: an arm at 30:00 is accepted", s.Offer(AlertKind.Arm, Cooldown, Cooldown) == OfferResult.Accepted, "");
            // The launch was accepted at 1.0 but started playing at 5.7: its 30 minutes run from 5.7.
            Check("cooldown: the launch timer runs from when it started playing", s.Offer(AlertKind.Launch, Cooldown + 5.6, Cooldown) == OfferResult.OnCooldown, "");
            Check("cooldown: and ends 30 min after it", s.Offer(AlertKind.Launch, Cooldown + 5.7, Cooldown) == OfferResult.Accepted, "");

            // A refused alert does not restart the timer.
            s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            s.Tick(0.0, false, Gap, true, MaxWait);
            s.Offer(AlertKind.Arm, 1000.0, Cooldown);
            Check("cooldown: a refused alert does not restart the timer", s.Offer(AlertKind.Arm, Cooldown, Cooldown) == OfferResult.Accepted, "");

            // A cooldown of zero, negative or NaN means none.
            foreach (double cd in new[] { 0.0, -1.0, double.NaN })
            {
                s = new AlertScheduler();
                s.Offer(AlertKind.Arm, 0.0, cd);
                s.Tick(0.0, false, Gap, true, MaxWait);
                Check("cooldown: " + cd + " means none", s.Offer(AlertKind.Arm, 0.5, cd) == OfferResult.Accepted, "");
            }

            // A shorter setting applies at once to the time already passed.
            s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            s.Tick(0.0, false, Gap, true, MaxWait);
            Check("cooldown: lowered to 5 min, an arm at 6 min is accepted", s.Offer(AlertKind.Arm, 360.0, 300.0) == OfferResult.Accepted, "");
        }

        private static void WaitingTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, 0);
            Check("waiting: a second launch while one waits is refused", s.Offer(AlertKind.Launch, 0.1, 0) == OfferResult.AlreadyWaiting, "");
            Check("waiting: one waits", s.WaitingCount == 1, "");
            s.Tick(0.2, false, Gap, true, MaxWait);
            Check("waiting: handed out, none waits", s.WaitingCount == 0, "");
            Check("waiting: with no cooldown, a launch while one plays is accepted", s.Offer(AlertKind.Launch, 0.3, 0) == OfferResult.Accepted, "");
            Check("waiting: it does not start while the first plays", s.Tick(0.4, true, Gap, true, MaxWait) == null, "");
        }

        // Both waiting: the arm alert goes first, whatever order they arrived in (a launch from one player and an arm
        // alert from another, or messages delivered out of order).
        private static void ArmFirstTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            s.Offer(AlertKind.Arm, 0.1, Cooldown);
            Check("arm first: the arm alert starts first", s.Tick(0.1, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            s.Tick(0.2, true, Gap, true, MaxWait);
            s.Tick(4.7, false, Gap, true, MaxWait);
            Check("arm first: then the launch, after the gap", s.Tick(5.8, false, Gap, true, MaxWait) == AlertKind.Launch, "");

            // A launch already sounding is not interrupted by an arm alert: it waits.
            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            s.Tick(0.0, false, Gap, true, MaxWait);
            s.Offer(AlertKind.Arm, 1.0, Cooldown);
            Check("arm first: never interrupts a launch that sounds", s.Tick(1.0, true, Gap, true, MaxWait) == null, "");
        }

        // While nothing could be heard (sound not loaded, a cinematic, volume 0), alerts wait instead of playing.
        private static void GateTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            Check("gate: nothing starts while it cannot be heard", s.Tick(0.0, false, Gap, false, MaxWait) == null, "");
            Check("gate: still waiting", s.WaitingCount == 1, "");
            Check("gate: starts once it can", s.Tick(5.0, false, Gap, true, MaxWait) == AlertKind.Arm, "");
        }

        // An alert that waits too long is dropped and gets its cooldown back.
        private static void MaxWaitTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            s.Tick(10.0, false, Gap, false, MaxWait);
            Check("max wait: still waiting at 10 s", s.WaitingCount == 1, "");
            s.Tick(30.5, false, Gap, false, MaxWait);
            Check("max wait: dropped after 30 s", s.WaitingCount == 0, "");
            Check("max wait: never plays", s.Tick(31.0, false, Gap, true, MaxWait) == null, "");
            Check("max wait: its cooldown is given back", s.Offer(AlertKind.Launch, 31.0, Cooldown) == OfferResult.Accepted, "");

            // The longest real wait - an arm alert behind a whole launch plus the gap - is well inside the limit.
            s = new AlertScheduler();
            var c = new Channel();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            Run(s, c, 0.0, 0.5);
            s.Offer(AlertKind.Arm, 0.5, Cooldown);
            Run(s, c, 0.5, 40.0);
            Check("max wait: an arm alert behind a launch still plays", c.Starts.Count == 2 && c.Starts[1].Key == AlertKind.Arm, "played " + c.Starts.Count);
        }

        private static void CancelTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            AlertKind? k = s.Tick(0.0, false, Gap, true, MaxWait);
            s.Cancel(k.Value);
            Check("cancel: an alert that could not start gets its cooldown back", s.Offer(AlertKind.Arm, 1.0, Cooldown) == OfferResult.Accepted, "");
            Check("cancel: CooldownLeft after acceptance at 1 s, asked at 61 s", Math.Abs(s.CooldownLeft(AlertKind.Arm, 61.0, Cooldown) - (Cooldown - 60.0)) < 1e-9, "");
            Check("cancel: CooldownLeft of the other kind is 0", s.CooldownLeft(AlertKind.Launch, 61.0, Cooldown) == 0, "");
            Check("cancel: CooldownLeft with no cooldown is 0", s.CooldownLeft(AlertKind.Arm, 61.0, 0) == 0, "");
        }

        // Leaving a world drops what waits and gives back its cooldown; what already played keeps its own.
        private static void DropTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            s.Tick(0.0, false, Gap, true, MaxWait);                 // the arm alert plays
            s.Offer(AlertKind.Launch, 0.5, Cooldown);  // the launch waits for it
            s.Tick(1.0, true, Gap, true, MaxWait);
            s.DropWaiting();
            Check("drop: nothing waits", s.WaitingCount == 0, "");
            Check("drop: nothing starts afterwards", s.Tick(10.0, false, Gap, true, MaxWait) == null, "");
            Check("drop: the dropped launch did not use its cooldown", s.Offer(AlertKind.Launch, 11.0, Cooldown) == OfferResult.Accepted, "");
            Check("drop: the arm alert that played keeps its cooldown", s.Offer(AlertKind.Arm, 11.0, Cooldown) == OfferResult.OnCooldown, "");

            // The refund goes back to the earlier play, not to "never".
            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, 100.0);
            s.Tick(0.0, false, Gap, true, MaxWait);
            s.Offer(AlertKind.Launch, 150.0, 100.0);
            s.DropWaiting();
            Check("drop: the refund restores the earlier start (150 s after 0 is past 100 s)", s.Offer(AlertKind.Launch, 150.0, 100.0) == OfferResult.Accepted, "");
            s.DropWaiting();
            Check("drop: and within 100 s of it a launch is still refused", s.Offer(AlertKind.Launch, 50.0, 100.0) == OfferResult.OnCooldown, "");
        }

        private static void InvalidTests()
        {
            var s = new AlertScheduler();
            Check("invalid: kind 2", s.Offer((AlertKind)2, 0.0, Cooldown) == OfferResult.Invalid, "");
            Check("invalid: kind -1", s.Offer((AlertKind)(-1), 0.0, Cooldown) == OfferResult.Invalid, "");
            Check("invalid: time NaN", s.Offer(AlertKind.Arm, double.NaN, Cooldown) == OfferResult.Invalid, "");
            Check("invalid: time infinite", s.Offer(AlertKind.Arm, double.PositiveInfinity, Cooldown) == OfferResult.Invalid, "");
            Check("invalid: nothing waits after invalid offers", s.WaitingCount == 0, "");
            Check("invalid: kinds 0 and 1 valid, 2 not", AlertScheduler.IsValidKind(0) && AlertScheduler.IsValidKind(1) && !AlertScheduler.IsValidKind(2) && !AlertScheduler.IsValidKind(-1), "");
        }

        private static void RangeTests()
        {
            Check("range: 100 m exactly is in range", AlertRules.WithinRange(60f, 0f, 80f, 100f), "");
            Check("range: 100.1 m is not", !AlertRules.WithinRange(100.1f, 0f, 0f, 100f), "");
            Check("range: the same spot is", AlertRules.WithinRange(0f, 0f, 0f, 100f), "");
            Check("range: height counts (a dungeon 5000 m up is not near)", !AlertRules.WithinRange(0f, 5000f, 0f, 100f), "");
            Check("range: 0 means nobody", !AlertRules.WithinRange(0f, 0f, 0f, 0f), "");
            Check("range: negative means nobody", !AlertRules.WithinRange(0f, 0f, 0f, -10f), "");
            Check("range: NaN offset is never in range", !AlertRules.WithinRange(float.NaN, 0f, 0f, 100f), "");
            Check("range: infinite offset is never in range", !AlertRules.WithinRange(float.PositiveInfinity, 0f, 0f, 100f), "");
            Check("range: NaN range is never in range", !AlertRules.WithinRange(0f, 0f, 0f, float.NaN), "");
            Check("range: huge offsets do not overflow into range", !AlertRules.WithinRange(3e38f, 3e38f, 3e38f, 100f), "");
            Check("range: huge range covers huge offsets", AlertRules.WithinRange(3e38f, 0f, 0f, float.MaxValue), "");
            Check("range: an infinite range is never in range", !AlertRules.WithinRange(0f, 0f, 0f, float.PositiveInfinity), "");
            Check("range: an infinite offset in y or z is never in range",
                !AlertRules.WithinRange(0f, float.NegativeInfinity, 0f, float.MaxValue) && !AlertRules.WithinRange(0f, 0f, float.PositiveInfinity, float.MaxValue), "");
        }

        private static void VolumeTests()
        {
            Check("volume: 0.5 stays", AlertRules.ClampVolume(0.5f) == 0.5f, "");
            Check("volume: above 1 becomes 1", AlertRules.ClampVolume(2f) == 1f, "");
            Check("volume: 1 stays", AlertRules.ClampVolume(1f) == 1f, "");
            Check("volume: negative becomes 0", AlertRules.ClampVolume(-1f) == 0f, "");
            Check("volume: NaN becomes 0", AlertRules.ClampVolume(float.NaN) == 0f, "");
            Check("volume: +infinity becomes 1", AlertRules.ClampVolume(float.PositiveInfinity) == 1f, "");
        }

        private static void ThrottleTests()
        {
            var t = new SendThrottle();
            Check("throttle: first send passes", t.TryPass(AlertKind.Arm, 0.0, 5.0), "");
            Check("throttle: again within 5 s is held back", !t.TryPass(AlertKind.Arm, 4.9, 5.0), "");
            Check("throttle: the other kind has its own", t.TryPass(AlertKind.Launch, 1.0, 5.0), "");
            Check("throttle: after 5 s it passes", t.TryPass(AlertKind.Arm, 5.0, 5.0), "");
            Check("throttle: an invalid kind never passes", !t.TryPass((AlertKind)7, 100.0, 5.0), "");
        }

        // The cooldown runs from when an alert starts playing, not from when it was accepted: an arm alert that waited
        // behind a launch still leaves 30 minutes before the next one starts.
        private static void PlayStartCooldownTests()
        {
            var s = new AlertScheduler();
            var c = new Channel();
            s.Offer(AlertKind.Launch, 10.0, Cooldown);          // B's launch, heard at 0:10
            Run(s, c, 10.0, 10.5);
            s.Offer(AlertKind.Arm, 10.5, Cooldown);             // A's arm, waits behind it
            Run(s, c, 10.5, 40.0);
            double armStart = c.Starts.Count == 2 ? c.Starts[1].Value : double.NaN;
            Check("play-start: the arm alert started after the launch", c.Starts.Count == 2 && c.Starts[1].Key == AlertKind.Arm && armStart > 23.0, "");
            Check("play-start: 30 min after its acceptance, but before 30 min after it started, an arm is refused",
                s.Offer(AlertKind.Arm, 10.5 + Cooldown, Cooldown) == OfferResult.OnCooldown, "");
            Check("play-start: 30 min after it started, an arm is accepted",
                s.Offer(AlertKind.Arm, armStart + Cooldown, Cooldown) == OfferResult.Accepted, "");

            // Two plays of one kind never start less than the cooldown apart, even with waits and a blocked channel.
            s = new AlertScheduler();
            c = new Channel();
            double lastArm = double.NegativeInfinity, minGap = double.PositiveInfinity;
            int arms = 0;
            for (double t = 0; t < 4 * Cooldown; t += 0.5)
            {
                if (((int)(t * 2)) % 7 == 0) s.Offer(AlertKind.Launch, t, Cooldown);
                if (((int)(t * 2)) % 5 == 0) s.Offer(AlertKind.Arm, t, Cooldown);
                bool blocked = ((int)(t / 40)) % 3 == 1;   // a stretch in which nothing can be heard
                AlertKind? next = s.Tick(t, c.Playing(t), Gap, !blocked, MaxWait);
                if (next.HasValue)
                {
                    c.Start(next.Value, t);
                    if (next.Value == AlertKind.Arm)
                    {
                        if (arms > 0) minGap = Math.Min(minGap, t - lastArm);
                        lastArm = t;
                        arms++;
                    }
                }
            }
            Check("play-start: arm alerts played several times over two hours", arms >= 3, "played " + arms);
            Check("play-start: never two arm alerts less than 30 min apart", minGap >= Cooldown, "closest " + minGap + " s");
        }

        // The user's numbers, where the plugin takes them from.
        private static void NumbersTests()
        {
            Check("numbers: the gap between alerts is 1 s", AlertRules.GapSeconds == 1.0, "");
            Check("numbers: the default cooldown is 30 min", AlertRules.DefaultCooldownMinutes == 30f, "");
            Check("numbers: 30 min is 1800 s", AlertRules.CooldownSeconds(AlertRules.DefaultCooldownMinutes) == 1800.0, "");
            Check("numbers: half a minute is 30 s", AlertRules.CooldownSeconds(0.5f) == 30.0, "");
            Check("numbers: a cooldown of 0, negative or NaN minutes is none",
                AlertRules.CooldownSeconds(0f) == 0.0 && AlertRules.CooldownSeconds(-5f) == 0.0 && AlertRules.CooldownSeconds(float.NaN) == 0.0, "");
            Check("numbers: the default hearing range is 100 m", AlertRules.DefaultHearingRange == 100f, "");
            Check("numbers: the default volume is 0.5, within 0..1", AlertRules.DefaultVolume == 0.5f && AlertRules.ClampVolume(AlertRules.DefaultVolume) == AlertRules.DefaultVolume, "");
            Check("numbers: an alert waits at most 30 s", AlertRules.MaxWaitSeconds == 30.0, "");
            Check("numbers: an alert is shared at most every 5 s", AlertRules.SendIntervalSeconds == 5.0, "");
            Check("numbers: the longest real wait (a launch plus the gap) is within the maximum wait", LaunchLength + AlertRules.GapSeconds < AlertRules.MaxWaitSeconds, "");
        }

        private static void IdentityTests()
        {
            Check("identity: the prefab name is StaffRedTroll", AlertRules.TrollstavPrefab == "StaffRedTroll", "");
            Check("identity: the name token is $item_staffredtroll", AlertRules.TrollstavToken == "$item_staffredtroll", "");
            Check("identity: by prefab name alone", AlertRules.IsTrollstav("StaffRedTroll", null), "");
            Check("identity: by name token alone", AlertRules.IsTrollstav(null, "$item_staffredtroll"), "");
            Check("identity: both", AlertRules.IsTrollstav("StaffRedTroll", "$item_staffredtroll"), "");
            Check("identity: another staff is not", !AlertRules.IsTrollstav("StaffFireball", "$item_stafffireball"), "");
            Check("identity: nothing is not", !AlertRules.IsTrollstav(null, null), "");
            Check("identity: names are exact (case and suffix)", !AlertRules.IsTrollstav("staffredtroll", "$ITEM_STAFFREDTROLL") && !AlertRules.IsTrollstav("StaffRedTroll(Clone)", "$item_staffredtroll2"), "");
            object item = new object(), other = new object();
            Check("identity: in the right hand", AlertRules.InHand(item, item, null), "");
            Check("identity: in the left hand", AlertRules.InHand(item, other, item), "");
            Check("identity: in neither hand", !AlertRules.InHand(item, other, null), "");
            Check("identity: no item is never in hand", !AlertRules.InHand(null, null, null), "");
        }

        // The arm alert against the user's words: "select it as a usable item/weapon", not "put it in inventory or a
        // usable slot". Every input is varied; the expected answer is written out independently of the code.
        private static void ArmDecisionTests()
        {
            object me = new object(), friend = new object(), staff = new object(), sword = new object();
            // Named cases.
            Check("arm: selecting the staff (hotbar, inventory, gamepad, hide/show draw)",
                AlertRules.ArmOnEquip(false, true, me, me, staff, staff, null, true, 0, false), "");
            Check("arm: the game putting saved gear back on (login, respawn, world load) passes false - no alert",
                !AlertRules.ArmOnEquip(false, false, me, me, staff, staff, null, true, 0, false), "");
            Check("arm: the staff already in hand - no alert",
                !AlertRules.ArmOnEquip(true, true, me, me, staff, staff, null, true, 0, false), "");
            Check("arm: picked up with empty hands and equipped automatically - no alert",
                !AlertRules.ArmOnEquip(false, true, me, me, staff, staff, null, true, 1, false), "");
            Check("arm: the staff coming back after eating - no alert",
                !AlertRules.ArmOnEquip(false, true, me, me, staff, staff, null, true, 0, true), "");
            Check("arm: another character equipping it - no alert",
                !AlertRules.ArmOnEquip(false, true, friend, me, staff, staff, null, true, 0, false), "");
            Check("arm: no local player - no alert",
                !AlertRules.ArmOnEquip(false, true, me, null, staff, staff, null, true, 0, false), "");
            Check("arm: another weapon - no alert",
                !AlertRules.ArmOnEquip(false, true, me, me, sword, sword, null, false, 0, false), "");
            Check("arm: the equip did not happen (not in hand afterwards) - no alert",
                !AlertRules.ArmOnEquip(false, true, me, me, staff, sword, null, true, 0, false), "");

            // Every combination.
            int wrong = 0, yes = 0;
            foreach (bool before in new[] { false, true })
            foreach (bool trigger in new[] { false, true })
            foreach (object equipper in new[] { me, friend, null })
            foreach (object local in new[] { me, null })
            foreach (object after in new[] { staff, sword, null })
            foreach (bool isStaff in new[] { false, true })
            foreach (int depth in new[] { -1, 0, 1, 2 })
            foreach (bool eat in new[] { false, true })
            {
                bool expected = !before && trigger && local != null && equipper == local && after == staff && isStaff && depth <= 0 && !eat;
                bool got = AlertRules.ArmOnEquip(before, trigger, equipper, local, staff, after, null, isStaff, depth, eat)
                           && AlertRules.ArmOnEquip(before, trigger, equipper, local, staff, null, after, isStaff, depth, eat);
                if (got != expected) wrong++;
                if (got) yes++;
            }
            Check("arm: every combination of inputs decides as expected", wrong == 0, wrong + " wrong");
            Check("arm: some combinations alert", yes > 0, "");
        }

        private static void LaunchDecisionTests()
        {
            object me = new object(), friend = new object(), a1 = new object(), a2 = new object();
            Check("launch: my new attack with the staff", AlertRules.LaunchOnAttack(a1, null, me, me, true), "");
            Check("launch: the next attack after it", AlertRules.LaunchOnAttack(a2, a1, me, me, true), "");
            Check("launch: the same attack twice - once only", !AlertRules.LaunchOnAttack(a1, a1, me, me, true), "");
            Check("launch: another character's attack", !AlertRules.LaunchOnAttack(a1, null, friend, me, true), "");
            Check("launch: no local player", !AlertRules.LaunchOnAttack(a1, null, me, null, true), "");
            Check("launch: another weapon", !AlertRules.LaunchOnAttack(a1, null, me, me, false), "");
            Check("launch: no attack", !AlertRules.LaunchOnAttack(null, null, me, me, true), "");
        }

        // "Only players nearby (by default 100m, configurable range)", "each player decides", any source.
        private static void HearingTests()
        {
            object me = new object(), friend = new object();
            const long mine = 111, theirs = 222;
            Check("hear: a friend 50 m away", AlertRules.MayHear(true, false, theirs, mine, friend, me, false, 30f, 0f, 40f, 100f), "");
            Check("hear: exactly 100 m", AlertRules.MayHear(true, false, theirs, mine, friend, me, false, 60f, 0f, 80f, 100f), "");
            Check("hear: 100.1 m is too far", !AlertRules.MayHear(true, false, theirs, mine, friend, me, false, 100.1f, 0f, 0f, 100f), "");
            Check("hear: in a dungeon above - too far", !AlertRules.MayHear(true, false, theirs, mine, friend, me, false, 0f, 5000f, 0f, 100f), "");
            Check("hear: a larger range of the listener's own choice", AlertRules.MayHear(true, false, theirs, mine, friend, me, false, 250f, 0f, 0f, 300f), "");
            Check("hear: hearing turned off", !AlertRules.MayHear(false, false, theirs, mine, friend, me, false, 1f, 0f, 1f, 100f), "");
            Check("hear: our own send coming back", !AlertRules.MayHear(true, true, theirs, mine, friend, me, false, 1f, 0f, 1f, 100f), "");
            Check("hear: our own id as sender", !AlertRules.MayHear(true, false, mine, mine, friend, me, false, 1f, 0f, 1f, 100f), "");
            Check("hear: our own character", !AlertRules.MayHear(true, false, theirs, mine, me, me, false, 0f, 0f, 0f, 100f), "");
            Check("hear: a character not loaded here", !AlertRules.MayHear(true, false, theirs, mine, null, me, false, 0f, 0f, 0f, 100f), "");
            Check("hear: no local player", !AlertRules.MayHear(true, false, theirs, mine, friend, null, false, 0f, 0f, 0f, 100f), "");
            Check("hear: the listener is dead", !AlertRules.MayHear(true, false, theirs, mine, friend, me, true, 1f, 0f, 1f, 100f), "");
            Check("hear: a distance that is not a number", !AlertRules.MayHear(true, false, theirs, mine, friend, me, false, float.NaN, 0f, 0f, 100f), "");
        }

        private static void WireTests()
        {
            foreach (AlertKind kind in new[] { AlertKind.Arm, AlertKind.Launch })
            foreach (long user in new[] { 0L, 1L, -1L, 123456789012345L, long.MaxValue, long.MinValue })
            foreach (uint id in new[] { 0u, 1u, 70000u, uint.MaxValue })
            {
                byte[] b = AlertWire.Encode(kind, user, id);
                AlertKind k; long u; uint i;
                bool ok = AlertWire.TryDecode(b, out k, out u, out i);
                if (!(ok && k == kind && u == user && i == id && b.Length == AlertWire.Length))
                {
                    Check("wire: round trip " + kind + " " + user + " " + id, false, "");
                }
            }
            Check("wire: round trips of both kinds and extreme ids", true, "");

            // The layout: version, kind, then the ZDOID as ZPackage.Write(long) and Write(uint) write it (little-endian).
            byte[] w = AlertWire.Encode(AlertKind.Launch, 0x0102030405060708L, 0x0A0B0C0Du);
            byte[] expected = { 1, 1, 8, 7, 6, 5, 4, 3, 2, 1, 0x0D, 0x0C, 0x0B, 0x0A };
            bool same = w.Length == expected.Length;
            for (int j = 0; same && j < w.Length; j++) same = w[j] == expected[j];
            Check("wire: version 1, kind, user and id little-endian, 14 bytes", same, BitConverter.ToString(w));
            Check("wire: no position - 14 bytes carry nothing but version, kind and the character's id", AlertWire.Length == 1 + 1 + 8 + 4, "");

            AlertKind k2; long u2; uint i2;
            Check("wire: null is refused", !AlertWire.TryDecode(null, out k2, out u2, out i2), "");
            Check("wire: 13 bytes are refused", !AlertWire.TryDecode(new byte[13] { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, out k2, out u2, out i2), "");
            byte[] v2 = AlertWire.Encode(AlertKind.Arm, 5, 6); v2[0] = 2;
            Check("wire: another version is refused", !AlertWire.TryDecode(v2, out k2, out u2, out i2), "");
            byte[] v0 = AlertWire.Encode(AlertKind.Arm, 5, 6); v0[0] = 0;
            Check("wire: version 0 is refused", !AlertWire.TryDecode(v0, out k2, out u2, out i2), "");
            byte[] bk = AlertWire.Encode(AlertKind.Arm, 5, 6); bk[1] = 2;
            Check("wire: kind 2 is refused", !AlertWire.TryDecode(bk, out k2, out u2, out i2), "");
            bk[1] = 255;
            Check("wire: kind 255 is refused", !AlertWire.TryDecode(bk, out k2, out u2, out i2), "");
            byte[] longer = new byte[20];
            Array.Copy(AlertWire.Encode(AlertKind.Launch, 42, 7), longer, AlertWire.Length);
            Check("wire: bytes appended by a later version are ignored",
                AlertWire.TryDecode(longer, out k2, out u2, out i2) && k2 == AlertKind.Launch && u2 == 42 && i2 == 7, "");
        }

        // "Can it be heard now": every input, and the named cases the README lists.
        private static void AudibleTests()
        {
            Check("audible: all well", AlertRules.Audible(true, true, true, true, 0.5f, false, 1f, true, 0.8f), "");
            Check("audible: sound not loaded", !AlertRules.Audible(false, true, true, true, 0.5f, false, 1f, true, 0.8f), "");
            Check("audible: not in a world", !AlertRules.Audible(true, false, true, true, 0.5f, false, 1f, true, 0.8f), "");
            Check("audible: dead or no player", !AlertRules.Audible(true, true, false, true, 0.5f, false, 1f, true, 0.8f), "");
            Check("audible: no routed source", !AlertRules.Audible(true, true, true, false, 0.5f, false, 1f, true, 0.8f), "");
            Check("audible: plugin volume 0", !AlertRules.Audible(true, true, true, true, 0f, false, 1f, true, 0.8f), "");
            Check("audible: a cinematic plays", !AlertRules.Audible(true, true, true, true, 0.5f, true, 1f, true, 0.8f), "");
            Check("audible: the listener is muted", !AlertRules.Audible(true, true, true, true, 0.5f, false, 0f, true, 0.8f), "");
            Check("audible: no AudioMan", !AlertRules.Audible(true, true, true, true, 0.5f, false, 1f, false, 0.8f), "");
            Check("audible: the game's volume or effect volume at 0", !AlertRules.Audible(true, true, true, true, 0.5f, false, 1f, true, 0f), "");
            Check("audible: NaN volumes are silence", !AlertRules.Audible(true, true, true, true, float.NaN, false, 1f, true, 0.8f)
                && !AlertRules.Audible(true, true, true, true, 0.5f, false, float.NaN, true, 0.8f) && !AlertRules.Audible(true, true, true, true, 0.5f, false, 1f, true, float.NaN), "");
            int wrong = 0;
            foreach (bool clip in new[] { false, true })
            foreach (bool world in new[] { false, true })
            foreach (bool alive in new[] { false, true })
            foreach (bool source in new[] { false, true })
            foreach (float vol in new[] { -1f, 0f, 0.3f, 1f })
            foreach (bool cine in new[] { false, true })
            foreach (float lvol in new[] { 0f, 1f })
            foreach (bool am in new[] { false, true })
            foreach (float sfx in new[] { 0f, 0.001f, 1f })
            {
                bool expected = clip && world && alive && source && vol > 0f && !cine && lvol > 0f && am && sfx > 0f;
                if (AlertRules.Audible(clip, world, alive, source, vol, cine, lvol, am, sfx) != expected) wrong++;
            }
            Check("audible: every combination decides as expected", wrong == 0, wrong + " wrong");
        }

        // With no cooldown (the setting at 0), a stream of arm alerts must not hold a launch back until it is dropped:
        // a launch that waited through one arm alert goes next.
        private static void StarveTests()
        {
            var s = new AlertScheduler();
            var c = new Channel();
            int launches = 0, arms = 0;
            for (double t = 0; t < 125.0; t += 0.01)
            {
                double r = Math.Round(t, 2);
                if (Math.Abs(r % 5.0) < 0.005) s.Offer(AlertKind.Arm, t, 0);                       // friend A draws every 5 s
                if (Math.Abs(r - 2.0) < 0.005 || Math.Abs(r - 40.0) < 0.005 || Math.Abs(r - 80.0) < 0.005) s.Offer(AlertKind.Launch, t, 0);   // friend B fires
                AlertKind? next = s.Tick(t, c.Playing(t), Gap, true, MaxWait);
                if (next.HasValue)
                {
                    c.Start(next.Value, t);
                    if (next.Value == AlertKind.Launch) launches++; else arms++;
                }
            }
            Check("no starving: all three launches play among a stream of arm alerts", launches == 3, launches + " launches, " + arms + " arms");
            Check("no starving: arm alerts still play", arms > 10, arms + " arms");

            // The user's chain is unchanged: an arm heard after a launch still goes first once.
            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, Cooldown);
            s.Offer(AlertKind.Arm, 0.1, Cooldown);
            Check("no starving: an arm arriving just after a launch still goes first", s.Tick(0.1, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            s.Tick(0.2, true, Gap, true, MaxWait);
            s.Tick(4.7, false, Gap, true, MaxWait);
            Check("no starving: then the launch", s.Tick(5.8, false, Gap, true, MaxWait) == AlertKind.Launch, "");

            // A launch owed its turn is forgotten when it is dropped, so a later arm goes first again.
            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, 0);
            s.Offer(AlertKind.Arm, 0.0, 0);
            s.Tick(0.0, false, Gap, true, MaxWait);          // the arm, over the waiting launch: the launch is owed
            s.DropWaiting();                                  // leaving the world drops the launch
            s.Offer(AlertKind.Launch, 10.0, 0);
            s.Offer(AlertKind.Arm, 10.0, 0);
            s.Tick(10.0, false, Gap, true, MaxWait);         // the channel is found silent: the gap starts
            Check("no starving: after a drop, the arm goes first again", s.Tick(11.1, false, Gap, true, MaxWait) == AlertKind.Arm, "");
        }

        // The owed turn belongs only to a launch that waited through an arm alert that sounded: it is forgotten when that
        // launch is dropped after the wait limit, an arm alert that went with no launch waiting owes nothing, and an arm
        // alert that could not start owes nothing either.
        private static void OwedTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 0.0, 0);
            s.Offer(AlertKind.Arm, 0.0, 0);
            Check("owed: the arm alert goes over the waiting launch", s.Tick(0.0, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            s.Tick(0.1, true, Gap, true, MaxWait);             // it sounds
            s.Tick(5.0, false, Gap, false, MaxWait);           // it ended; now nothing can be heard (a cinematic)
            s.Tick(36.5, false, Gap, false, MaxWait);          // the launch's turn came at 6.0; 30.5 s later: dropped
            Check("owed: the launch is dropped 30 s after its turn came", s.WaitingCount == 0, "waiting " + s.WaitingCount);
            s.Offer(AlertKind.Launch, 40.0, 0);
            s.Offer(AlertKind.Arm, 40.0, 0);
            Check("owed: forgotten with the dropped launch - a new pair plays the arm alert first", s.Tick(40.0, false, Gap, true, MaxWait) == AlertKind.Arm, "");

            s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, 0);
            s.Tick(0.0, false, Gap, true, MaxWait);            // an arm alert, no launch waiting
            s.Tick(0.1, true, Gap, true, MaxWait);
            s.Tick(5.0, false, Gap, true, MaxWait);            // it ended
            s.Offer(AlertKind.Launch, 10.0, 0);
            s.Offer(AlertKind.Arm, 10.0, 0);
            Check("owed: an arm alert with no launch waiting owes nothing - the next pair plays the arm alert first", s.Tick(10.0, false, Gap, true, MaxWait) == AlertKind.Arm, "");

            s = new AlertScheduler();
            s.Offer(AlertKind.Launch, 1.2, Cooldown);          // a friend's launch
            s.Offer(AlertKind.Arm, 1.2, Cooldown);             // and your own draw, in one frame
            Check("owed: the arm alert is handed out first", s.Tick(1.2, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            s.Cancel(AlertKind.Arm);                            // it could not start
            Check("owed: the cancelled arm alert gets its cooldown back", s.Offer(AlertKind.Arm, 1.5, Cooldown) == OfferResult.Accepted, "");
            s.Tick(1.5, false, Gap, true, MaxWait);            // nothing sounded: the gap starts
            Check("owed: a cancelled arm alert owes nothing - the new arm alert still goes first", s.Tick(2.6, false, Gap, true, MaxWait) == AlertKind.Arm, "");
        }

        // A custom sound can be long: waiting for it to finish never counts toward the 30 s limit.
        private static void LongSoundTests()
        {
            var s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.2, Cooldown);
            Check("long: a 35 s arm sound starts", s.Tick(0.2, false, Gap, true, MaxWait) == AlertKind.Arm, "");
            s.Offer(AlertKind.Launch, 1.5, Cooldown);
            AlertKind? got = null;
            double at = 0;
            for (double t = 0.3; t < 60.0 && !got.HasValue; t += 0.01)
            {
                got = s.Tick(t, t < 35.2, Gap, true, MaxWait);
                at = t;
            }
            Check("long: the launch waiting behind it plays after it, 1 s after its end", got == AlertKind.Launch && at >= 36.2 && at < 36.25, got + " at " + at);

            // After the long sound, the 30 s start from the launch's turn (the end plus the gap).
            s = new AlertScheduler();
            s.Offer(AlertKind.Arm, 0.0, Cooldown);
            s.Tick(0.0, false, Gap, true, MaxWait);
            s.Offer(AlertKind.Launch, 1.0, Cooldown);
            for (double t = 0.1; t < 40.0; t += 0.1) s.Tick(t, true, Gap, false, MaxWait);   // a 40 s arm sound
            s.Tick(40.0, false, Gap, false, MaxWait);          // it ended; the launch's turn comes at 41.0, but it cannot be heard
            s.Tick(70.5, false, Gap, false, MaxWait);
            Check("long: 29.5 s after its turn the launch still waits", s.WaitingCount == 1, "waiting " + s.WaitingCount);
            s.Tick(71.5, false, Gap, false, MaxWait);
            Check("long: 30.5 s after its turn it is dropped", s.WaitingCount == 0, "waiting " + s.WaitingCount);
            Check("long: and gets its cooldown back", s.Offer(AlertKind.Launch, 72.0, Cooldown) == OfferResult.Accepted, "");
        }

        private static void Check(string name, bool ok, string detail)
        {
            if (ok) { _passes++; return; }
            _failures++;
            Console.WriteLine("FAIL " + name + (string.IsNullOrEmpty(detail) ? "" : " - " + detail));
        }
    }
}
