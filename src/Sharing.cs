using System;
using System.Collections.Generic;
using UnityEngine;

namespace NuclearTrollstav
{
    /// <summary>
    /// Tells nearby players about an alert, through one routed call to everybody. The server passes such a call on
    /// whether or not it has this plugin, and a player without the plugin ignores it without a trace, so nothing is
    /// needed on the server and nothing changes for anyone else.
    ///
    /// The message (AlertWire) says which alert and whose character set it off - no position: each listener looks for
    /// that character among the players its own game has loaded and measures the distance itself. A character it has
    /// not loaded is far away, and a made-up one matches nobody.
    /// </summary>
    internal static class Sharing
    {
        public const string RpcName = "DoomMachine.NuclearTrollstav.Alert";

        // A field, so Register's arguments are plain loads (preflight reads the name passed with it).
        private static readonly Action<long, ZPackage> Handler = OnAlert;
        private static ZRoutedRpc _registeredOn;
        private static bool _inLocalSend;
        private static int _receiveErrors;
        private static int _sendErrors;

        /// <summary>
        /// Registers the handler on this session's ZRoutedRpc. ZNet.Awake makes a new one every session and the old one
        /// stays in ZRoutedRpc.instance after logout; registering one name twice on one instance throws.
        /// </summary>
        public static void EnsureRegistered()
        {
            ZRoutedRpc rpc = ZRoutedRpc.instance;
            if (rpc == null || ReferenceEquals(rpc, _registeredOn)) return;
            try
            {
                rpc.Register<ZPackage>(RpcName, Handler);
                Plugin.Log.LogDebug("Alert sharing registered for this session.");
            }
            catch (Exception e)
            {
                Plugin.Log.LogWarning("Could not register alert sharing (" + e.Message + "); other players' alerts will not be heard this session.");
            }
            _registeredOn = rpc;
        }

        public static bool CanSend()
        {
            EnsureRegistered();
            ZNet net = ZNet.instance;
            return net != null && !net.HaveStopped && Player.m_localPlayer != null
                   && ZRoutedRpc.instance != null && ReferenceEquals(ZRoutedRpc.instance, _registeredOn);
        }

        public static void Send(AlertKind kind)
        {
            try
            {
                Player me = Player.m_localPlayer;
                if (me == null) return;
                ZDOID id = me.GetZDOID();
                if (id.IsNone()) return;
                // preflight: the message is exactly these bytes, and _inLocalSend is set here and cleared in the finally.
                ZPackage pkg = new ZPackage(AlertWire.Encode(kind, id.UserID, id.ID));
                _inLocalSend = true;   // target Everybody also runs our own handler, at once, inside this call
                ZRoutedRpc.instance.InvokeRoutedRPC(ZRoutedRpc.Everybody, RpcName, pkg);
            }
            catch (Exception e)
            {
                Plugin.LogThrottled(ref _sendErrors, "Sending an alert failed", e);
            }
            finally
            {
                _inLocalSend = false;
            }
        }

        /// <summary>
        /// Another player's alert. Runs inside the game's network update; on a host it runs before the call is passed
        /// on to the other players, so it must never throw.
        /// </summary>
        private static void OnAlert(long sender, ZPackage pkg)
        {
            try   // preflight: the whole body inside the try
            {
                if (pkg == null) return;
                AlertKind kind;
                long user;
                uint id;
                if (!AlertWire.TryDecode(pkg.GetArray(), out kind, out user, out id)) return;
                // preflight reads these locals and MayHear's arguments from the IL: keep the shapes (a local each, d
                // set only to zero and to source - me, the arguments inline and in this order).
                Player me = Player.m_localPlayer;
                Player source = FindLoadedPlayer(user, id);   // null: not loaded here, so not near
                bool meDead = me != null && me.IsDead();
                Vector3 d = Vector3.zero;
                if (me != null && source != null) d = source.transform.position - me.transform.position;
                if (AlertRules.MayHear(Plugin.HearOthers.Value, _inLocalSend, sender, ZNet.GetUID(), source, me, meDead,
                        d.x, d.y, d.z, Plugin.HearingRange.Value))
                {
                    Alerts.OnRemote(kind, d.magnitude);
                }
            }
            catch (Exception e)
            {
                Plugin.LogThrottled(ref _receiveErrors, "Receiving an alert failed", e);
            }
        }

        /// <summary>
        /// The loaded player whose character has this ZDOID. The two numbers are compared as they are: building a ZDOID
        /// from them would add the user to the game's global user table.
        /// </summary>
        private static Player FindLoadedPlayer(long user, uint id)   // preflight: compares id with id and user with user
        {
            List<Player> players = Player.GetAllPlayers();
            for (int i = 0; i < players.Count; i++)
            {
                Player p = players[i];
                if (p == null) continue;
                ZDOID pid = p.GetZDOID();
                if (!pid.IsNone() && pid.ID == id && pid.UserID == user) return p;
            }
            return null;
        }
    }
}
