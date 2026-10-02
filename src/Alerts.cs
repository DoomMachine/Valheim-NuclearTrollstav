using System;
using UnityEngine;
using UnityEngine.Audio;

namespace NuclearTrollstav
{
    /// <summary>
    /// The game side of the alerts: the one audio source they play on, the sounds, and the scheduler that decides
    /// (see AlertRules.cs). Everything here runs on Unity's main thread.
    /// tools\preflight.ps1 reads the IL of the calls marked "preflight:" - it checks where each argument comes from, so
    /// keep those arguments written inline and in that order.
    /// </summary>
    internal static class Alerts
    {
        private const double PlayingGraceSeconds = 0.5;      // a clip still sounding this long after its end is stopped
        private const double StartGraceSeconds = 0.25;       // a clip just started counts as playing this long regardless

        private static readonly AlertScheduler Scheduler = new AlertScheduler();
        private static readonly SendThrottle Throttle = new SendThrottle();
        private static readonly SendThrottle RefusalLog = new SendThrottle();
        private static readonly AudioClip[] Clips = new AudioClip[AlertScheduler.KindCount];
        private static readonly string[] Who = new string[AlertScheduler.KindCount];   // who set off the alert accepted last

        private static GameObject _owner;
        private static AudioSource _source;
        private static AudioMixerGroup _gui;
        private static double _nextGuiLookup;
        private static bool _guiMissingLogged;
        private static double _playingUntil = double.NegativeInfinity;   // watchdog: the clip's end plus a margin
        private static double _startedAt = double.NegativeInfinity;
        private static bool _inWorld;

        // preflight: exact shape (real time).
        public static double Now { get { return Time.realtimeSinceStartupAsDouble; } }   // runs through the single-player pause

        private static double CooldownSeconds   // preflight: exact shape
        {
            get { return AlertRules.CooldownSeconds(Plugin.CooldownMinutes.Value); }
        }

        public static void SetClip(AlertKind kind, AudioClip clip)
        {
            Clips[(int)kind] = clip;
        }

        public static string Label(AlertKind kind)
        {
            return kind == AlertKind.Arm ? "Arm alert" : "Launch alert";
        }

        /// <summary>Whether an alert of this kind could be heard now (AlertRules.Audible).</summary>
        public static bool CanPlay(AlertKind kind)   // preflight: exact shape
        {
            return Audible(Clips[(int)kind] != null);
        }

        /// <summary>Whether a waiting alert could start now: its sound was loaded when it was accepted.</summary>
        private static bool CanPlayAny()   // preflight: exact shape
        {
            return Audible(true);
        }

        private static bool Audible(bool clipLoaded)
        {
            // preflight: each argument is read from the IL.
            return AlertRules.Audible(clipLoaded, ZNet.instance != null, ListenerAlive(), EnsureSource() != null,
                AlertRules.ClampVolume(Plugin.Volume.Value), CinematicsManager.IsStartedPlaying(), AudioListener.volume,
                AudioMan.instance != null, AudioMan.GetSFXVolume());
        }

        /// <summary>The local player exists and is not dead (Player.IsDead is set the moment the player dies).</summary>
        internal static bool ListenerAlive()   // preflight: exact shape
        {
            Player me = Player.m_localPlayer;
            if (me == null) return false;
            return !me.IsDead();
        }

        /// <summary>This player set off an alert: play it here (if the cooldown allows) and tell the others.</summary>
        public static void OnLocal(AlertKind kind)
        {
            double now = Now;
            if (CanPlay(kind))   // preflight: decides the Offer
            {
                OfferResult r = Scheduler.Offer(kind, now, CooldownSeconds);
                if (r == OfferResult.Accepted) Who[(int)kind] = "you";
                else Plugin.Log.LogInfo(RefusalText(kind, "you", r, now));
            }
            else
            {
                Plugin.Log.LogInfo(Label(kind) + " (you): not played, it could not be heard now (sound not loaded, muted or volume 0).");
            }
            if (Diag.Verbose) Diag.Local(kind);   // after the decision: what it read (CanPlay makes the audio source the first time)
            // preflight: ShareMyAlerts and the throttle decide the send, with this alert's kind and the clock.
            if (Plugin.ShareMyAlerts.Value && Sharing.CanSend() && Throttle.TryPass(kind, now, AlertRules.SendIntervalSeconds))
            {
                Sharing.Send(kind);
            }
        }

        /// <summary>Another player's alert, already checked by AlertRules.MayHear: play it here if the cooldown allows.</summary>
        public static void OnRemote(AlertKind kind, float distance)
        {
            string who = string.Format("a player {0:0} m away", distance);
            double now = Now;
            if (CanPlay(kind))   // preflight: decides the Offer
            {
                OfferResult r = Scheduler.Offer(kind, now, CooldownSeconds);
                if (r == OfferResult.Accepted) Who[(int)kind] = who;
                else LogRemoteRefusal(kind, now, RefusalText(kind, who, r, now));
            }
            else
            {
                LogRemoteRefusal(kind, now, Label(kind) + " (" + who + "): not played, it could not be heard now.");
            }
        }

        /// <summary>Other players' refused alerts are logged at most once per kind every AlertRules.RefusalLogSeconds.</summary>
        private static void LogRemoteRefusal(AlertKind kind, double now, string text)
        {
            if (RefusalLog.TryPass(kind, now, AlertRules.RefusalLogSeconds))   // preflight: decides the log line
            {
                Plugin.Log.LogInfo(text);
            }
        }

        private static string RefusalText(AlertKind kind, string who, OfferResult r, double now)
        {
            if (r == OfferResult.OnCooldown)
            {
                return string.Format("{0} ({1}): not played, one played less than {2:0.#} min ago ({3:0.#} min left).",
                    Label(kind), who, CooldownSeconds / 60.0, Scheduler.CooldownLeft(kind, now, CooldownSeconds) / 60.0);
            }
            if (r == OfferResult.AlreadyWaiting) return Label(kind) + " (" + who + "): not played, one is already waiting to play.";
            return Label(kind) + " (" + who + "): not played (" + r + ").";
        }

        /// <summary>Called every frame by the plugin.</summary>
        public static void Tick()
        {
            if (Diag.Verbose) Diag.Observe();
            double now = Now;
            if (ZNet.instance == null)
            {
                // Left the world (or not in one yet): nothing plays in the menus.
                if (_inWorld)
                {
                    _inWorld = false;
                    Scheduler.DropWaiting();
                    if (_source != null && _source.isPlaying) _source.Stop();
                    _playingUntil = double.NegativeInfinity;
                    ProjectileAttackTriggeredPatch.Forget();
                }
                return;
            }
            _inWorld = true;
            if (Scheduler.WaitingCount > 0 && !ListenerAlive()) Scheduler.DropWaiting();   // died: nothing waits for the respawn

            bool sounding = _source != null && _source.isPlaying;
            if (sounding && now >= _playingUntil) { _source.Stop(); sounding = false; }   // watchdog: past its end
            // Counted as playing for a moment after Play() even if Unity does not report it yet, so the next alert can
            // never be started over it.
            bool playing = sounding || now < _startedAt + StartGraceSeconds;
            bool canStart = Scheduler.WaitingCount > 0 && CanPlayAny();
            // preflight: the gap and the wait limit are AlertRules', "playing" and canStart are the locals above.
            AlertKind? next = Scheduler.Tick(now, playing, AlertRules.GapSeconds, canStart, AlertRules.MaxWaitSeconds);
            if (next.HasValue) Start(next.Value, now);
        }

        // Read-only views for the VerboseLog lines (Diag): they change nothing, and never make the audio source.
        internal static bool ClipLoaded(AlertKind kind) { return Clips[(int)kind] != null; }
        internal static bool SourceReady { get { return _source != null; } }
        internal static bool Sounding { get { return _source != null && _source.isPlaying; } }
        internal static bool IsWaiting(AlertKind kind) { return Scheduler.IsWaiting(kind); }
        internal static double CooldownLeft(AlertKind kind) { return Scheduler.CooldownLeft(kind, Now, CooldownSeconds); }
        internal static double StartedAt { get { return _startedAt; } }

        /// <summary>The kind whose sound is on the audio source (the one playing, or played last), or null.</summary>
        internal static AlertKind? ClipKind
        {
            get
            {
                if (_source == null || _source.clip == null) return null;
                for (int k = 0; k < Clips.Length; k++)
                {
                    if (ReferenceEquals(Clips[k], _source.clip)) return (AlertKind)k;
                }
                return null;
            }
        }

        private static void Start(AlertKind kind, double now)
        {
            AudioClip clip = Clips[(int)kind];
            AudioSource source = EnsureSource();
            if (clip == null || !Routed(source))   // preflight: only a routed source plays
            {
                Scheduler.Cancel(kind);
                return;
            }
            try
            {
                source.clip = clip;   // one source, one clip: two alerts can never sound at once
                source.volume = AlertRules.ClampVolume(Plugin.Volume.Value);   // preflight: ClampVolume of Volume, inline
                source.Play();
                _startedAt = now;
                _playingUntil = now + clip.length + PlayingGraceSeconds;
            }
            catch (Exception e)
            {
                Scheduler.Cancel(kind);   // nothing sounded
                Plugin.Log.LogWarning(Label(kind) + " could not start: " + e.Message);
                return;
            }
            // preflight: the one "playing now" line, after Play, only when it started.
            Plugin.Log.LogInfo(Label(kind) + " (" + (Who[(int)kind] ?? "?") + "): playing now.");
        }

        /// <summary>A source goes through the game's mixer, or it does not play: outside it, it would ignore both sliders.</summary>
        private static bool Routed(AudioSource source)   // preflight: exact shape
        {
            return source != null && source.outputAudioMixerGroup != null;
        }

        public static void ApplyVolume()   // preflight: exact shape
        {
            if (_source != null) _source.volume = AlertRules.ClampVolume(Plugin.Volume.Value);
        }

        /// <summary>
        /// The one audio source, routed to the game's "GUI" mixer group: that group's level is set by the game from
        /// its Volume and Effect volume settings, so an alert follows them and can never be louder than they allow.
        /// Without the group there is no source, and nothing plays.
        /// </summary>
        private static AudioSource EnsureSource()
        {
            if (_source != null) return _source;
            if (_gui == null)
            {
                double now = Now;
                if (now < _nextGuiLookup) return null;
                _nextGuiLookup = now + 1.0;
                _gui = FindGuiGroup();
                if (_gui == null)
                {
                    if (!_guiMissingLogged && AudioMan.instance != null)
                    {
                        _guiMissingLogged = true;
                        Plugin.Log.LogWarning("The game's interface-sound mixer group was not found, so no alert can play (it would ignore your volume settings).");
                    }
                    return null;
                }
                Plugin.Log.LogInfo("Alerts play on the game's " + _gui.name + " mixer group.");
            }
            if (_owner == null)
            {
                _owner = new GameObject("NuclearTrollstav_Audio");
                UnityEngine.Object.DontDestroyOnLoad(_owner);
            }
            AudioSource s = _owner.GetComponent<AudioSource>();
            if (s == null) s = _owner.AddComponent<AudioSource>();
            s.playOnAwake = false;
            s.loop = false;
            s.spatialBlend = 0f;          // 2D: an alert, not a sound in the world
            s.priority = 0;
            s.bypassReverbZones = true;
            s.dopplerLevel = 0f;
            s.outputAudioMixerGroup = _gui;
            s.volume = AlertRules.ClampVolume(Plugin.Volume.Value);
            _source = s;
            return _source;
        }

        /// <summary>
        /// The master mixer's "GUI" group. AudioMan.m_guiMixer would be the obvious way, but the game ships it empty
        /// (null in the _AudioManager prefab), so the group is found by name in the master mixer.
        /// </summary>
        private static AudioMixerGroup FindGuiGroup()
        {
            AudioMan am = AudioMan.instance;
            if (am == null || am.m_masterMixer == null) return null;
            AudioMixer mixer = am.m_masterMixer;
            try
            {
                foreach (AudioMixerGroup g in mixer.FindMatchingGroups("Master"))
                {
                    if (g != null && g.name == "GUI") return g;   // preflight: names compared only with == "GUI"
                }
            }
            catch (Exception) { }
            foreach (AudioMixerGroup g in Resources.FindObjectsOfTypeAll<AudioMixerGroup>())
            {
                if (g != null && g.name == "GUI" && g.audioMixer == mixer) return g;
            }
            return null;
        }
    }
}
