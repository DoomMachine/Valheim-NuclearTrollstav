using System;
using System.Collections;
using System.IO;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using HarmonyLib;
using UnityEngine;
using UnityEngine.Networking;

namespace NuclearTrollstav
{
    /// <summary>
    /// Plays a "silo armed" alert when the player draws Trollstav and a "missile launch" alert when they use it, and
    /// lets nearby players who also run the plugin hear them. Client only: a vanilla server passes the alerts on.
    /// </summary>
    [BepInPlugin(GUID, NAME, VERSION)]
    [BepInProcess("valheim.exe")]          // client only; the dedicated server is valheim_server.exe
    public class Plugin : BaseUnityPlugin
    {
        public const string GUID = "DoomMachine.NuclearTrollstav";   // also names the .cfg file
        public const string NAME = "NuclearTrollstav";
        public const string VERSION = "1.0.0";

        internal static ManualLogSource Log;

        internal static ConfigEntry<float> Volume;
        internal static ConfigEntry<string> ArmSoundFile;
        internal static ConfigEntry<string> LaunchSoundFile;
        internal static ConfigEntry<float> CooldownMinutes;
        internal static ConfigEntry<bool> ShareMyAlerts;
        internal static ConfigEntry<bool> HearOthers;
        internal static ConfigEntry<float> HearingRange;

        private Harmony _harmony;

        private void Awake()
        {
            Log = Logger;

            // BepInEx drops a plugin that throws in Awake, so each stage is guarded on its own.
            // preflight: each Bind is stored straight into the field of its key, with its literal default.
            try
            {
                Volume = Config.Bind("Sound", "Volume", AlertRules.DefaultVolume, new ConfigDescription(
                    "How loud the alerts are, from 0 (silent) to 1. They play on the game's own interface-sound channel, so "
                    + "the game's Volume and Effect volume settings scale them as well: at 1 an alert is never louder "
                    + "than those settings allow. Changed in game with a configuration manager, it applies at once; edit "
                    + "this file only with the game closed.",
                    new AcceptableValueRange<float>(0f, 1f)));
                ArmSoundFile = Config.Bind("Sound", "ArmSound", "Nuclear Silo Arm.mp3",
                    "The sound played when Trollstav is drawn: an MP3 file in the plugin's own folder (or a full path). "
                    + "Read when the game starts.");
                LaunchSoundFile = Config.Bind("Sound", "LaunchSound", "Nuclear Missile Launch Sound.mp3",
                    "The sound played when Trollstav is used: an MP3 file in the plugin's own folder (or a full path). "
                    + "Read when the game starts.");
                CooldownMinutes = Config.Bind("Alerts", "CooldownMinutes", AlertRules.DefaultCooldownMinutes, new ConfigDescription(
                    "You hear each alert at most once in this many minutes, whoever set it off - you or another player. The "
                    + "equip alert and the use alert each have their own timer. 0 = no limit. The timers start again when "
                    + "the game restarts.",
                    new AcceptableValueRange<float>(0f, 1440f)));
                ShareMyAlerts = Config.Bind("Multiplayer", "ShareMyAlerts", true,
                    "Let nearby players who also run this plugin hear your alerts. Players without it hear nothing.");
                HearOthers = Config.Bind("Multiplayer", "HearOthers", true,
                    "Hear the alerts of other players who run this plugin, when they are within HearingRange.");
                HearingRange = Config.Bind("Multiplayer", "HearingRange", AlertRules.DefaultHearingRange, new ConfigDescription(
                    "How near, in metres, another player must be for you to hear their alert. Only players your game has "
                    + "loaded around you can be heard, so a large range reaches only as far as the game's draw distance "
                    + "setting loads players.",
                    new AcceptableValueRange<float>(1f, 1000f)));
                Volume.SettingChanged += OnVolumeChanged;
            }
            catch (Exception e)
            {
                Log.LogError("Configuration failed to bind, the plugin is off: " + e);
                enabled = false;
                return;
            }

            try
            {
                string folder = Path.GetDirectoryName(Info.Location);
                StartCoroutine(LoadClip(AlertKind.Arm, folder, ArmSoundFile.Value));
                StartCoroutine(LoadClip(AlertKind.Launch, folder, LaunchSoundFile.Value));
            }
            catch (Exception e)
            {
                Log.LogError("Could not start loading the sounds: " + e);
            }

            _harmony = new Harmony(GUID);
            ApplyPatches();
            Log.LogInfo(NAME + " " + VERSION + " loaded.");
        }

        /// <summary>A volume changed in game (through a configuration manager) applies to the playing alert at once.</summary>
        private static void OnVolumeChanged(object sender, EventArgs e)
        {
            try
            {
                Alerts.ApplyVolume();
            }
            catch (Exception ex)
            {
                LogThrottled(ref _updateErrors, "Applying the volume failed", ex);
            }
        }

        /// <summary>
        /// One PatchAll per patch class, not PatchAll(assembly): PatchAll aborts on the first target it cannot resolve,
        /// so a single method renamed by a game update would disable every patch.
        /// </summary>
        private void ApplyPatches()
        {
            Type[] patchClasses = new Type[]
            {
                typeof(EquipItemPatch),
                typeof(PickupPatch),
                typeof(ShowHandItemsPatch),
                typeof(ProjectileAttackTriggeredPatch),
                typeof(GameStartPatch),
            };
            int applied = 0;
            foreach (Type t in patchClasses)   // preflight: PatchAll(Type) on every element, from the first
            {
                try { _harmony.PatchAll(t); applied++; }
                catch (Exception e) { Log.LogError("Patch " + t.Name + " failed, that part is off: " + e.Message); }
            }
            Log.LogInfo(string.Format("Applied {0} of {1} patches.", applied, patchClasses.Length));
        }

        /// <summary>
        /// Loads one sound with Unity's own decoder. The path is passed as a plain file path, never as a file: URL:
        /// Unity's URL decoding would turn a '+' in a folder name into a space.
        /// </summary>
        private IEnumerator LoadClip(AlertKind kind, string folder, string file)
        {
            string label = kind == AlertKind.Arm ? "Arm sound" : "Launch sound";
            UnityWebRequest request = null;
            string path = null;
            try
            {
                path = Path.GetFullPath(Path.Combine(folder, file ?? ""));
                if (!File.Exists(path))
                {
                    Log.LogWarning(label + ": no file at " + path + " - that alert is off.");
                    yield break;
                }
                request = UnityWebRequestMultimedia.GetAudioClip(path, AudioType.MPEG);
            }
            catch (Exception e)
            {
                Log.LogWarning(label + ": cannot read " + (path ?? file) + " (" + e.GetType().Name + ": " + e.Message + ") - that alert is off.");
                yield break;
            }

            using (request)
            {
                yield return request.SendWebRequest();   // a yield cannot sit in a try with a catch (CS1626)
                AudioClip clip = null;
                try
                {
                    if (request.result != UnityWebRequest.Result.Success)
                    {
                        Log.LogWarning(label + ": could not load " + path + " (" + request.error + ") - that alert is off.");
                        yield break;
                    }
                    clip = DownloadHandlerAudioClip.GetContent(request);
                }
                catch (Exception e)
                {
                    Log.LogWarning(label + ": could not decode " + path + " (" + e.GetType().Name + ": " + e.Message + ") - that alert is off.");
                    yield break;
                }
                while (clip != null && clip.loadState == AudioDataLoadState.Loading) yield return null;
                if (clip == null || clip.loadState != AudioDataLoadState.Loaded || clip.length <= 0f)
                {
                    Log.LogWarning(label + ": " + path + " decoded to no sound ("
                                   + (clip == null ? "no clip" : clip.loadState + ", " + clip.length + " s") + ") - that alert is off.");
                    yield break;
                }
                clip.name = "NuclearTrollstav " + kind;
                clip.hideFlags = HideFlags.DontUnloadUnusedAsset;   // the game unloads unused assets on respawn and world load
                Alerts.SetClip(kind, clip);
                Log.LogInfo(string.Format("{0} loaded: {1} ({2:0.000} s, {3} channel(s), {4} Hz).",
                    label, Path.GetFileName(path), clip.length, clip.channels, clip.frequency));
            }
        }

        private void Update()
        {
            // Runs every frame: nothing may escape, and a repeating error must not flood the log.
            try
            {
                Alerts.Tick();
            }
            catch (Exception e)
            {
                LogThrottled(ref _updateErrors, "Update failed", e);
            }
        }

        private static int _updateErrors;
        internal static void LogThrottled(ref int counter, string context, Exception e)
        {
            counter++;
            if (counter <= 3) Log.LogError(context + ": " + e);
            else if (counter == 4) Log.LogError(context + ": repeating, further occurrences not logged.");
        }

        private void OnDestroy()
        {
            if (_harmony != null) _harmony.UnpatchSelf();
        }
    }
}
