using System;
using HarmonyLib;

namespace NuclearTrollstav
{
    internal static class Trollstav
    {
        /// <summary>
        /// Trollstav, by prefab name or by its name token (AlertRules.IsTrollstav). m_dropPrefab is set for items loaded
        /// from a save too (ItemDrop.Awake), and m_shared is shared with the prefab, so either identifies it.
        /// </summary>
        public static bool Is(ItemDrop.ItemData item)
        {
            if (item == null) return false;
            string prefab = item.m_dropPrefab != null ? item.m_dropPrefab.name : null;
            string token = item.m_shared != null ? item.m_shared.m_name : null;
            return AlertRules.IsTrollstav(prefab, token);
        }

        private static int _errors;
        public static void Report(string where, Exception e)
        {
            Plugin.LogThrottled(ref _errors, where, e);
        }
    }

    /// <summary>
    /// The arm alert: Trollstav goes from not held to held, by the player's own hand (AlertRules.ArmOnEquip). Every
    /// way a player selects a weapon (hotbar key, inventory click, gamepad, radial menu, the equip queue finishing,
    /// drawing the weapons again with the hide/show key) ends in EquipItem with triggerEquipEffects true. The game passes
    /// false when it puts saved gear back on at login, respawn and world load, and when an item is dragged in the
    /// inventory. Two true-passing calls are not the player's choice and are filtered out: the automatic equip of a
    /// weapon picked up with empty hands (PickupPatch), and the weapon coming back after eating (ShowHandItemsPatch).
    /// </summary>
    [HarmonyPatch(typeof(Humanoid), nameof(Humanoid.EquipItem))]
    internal static class EquipItemPatch
    {
        // EquipItem returns false at once for an item already equipped, and leaves it in the hand: only a change from
        // "not in a hand" to "in a hand" counts.
        private static void Prefix(Humanoid __instance, ItemDrop.ItemData item, out bool __state)
        {
            __state = true;   // if the check below fails, no alert
            try
            {
                // preflight: __state is set exactly twice, to true and then to InHand(item, RightItem, LeftItem).
                __state = AlertRules.InHand(item, __instance.RightItem, __instance.LeftItem);
            }
            catch (Exception e)
            {
                Trollstav.Report("Equip check failed", e);
            }
        }

        private static void Postfix(Humanoid __instance, ItemDrop.ItemData item, bool triggerEquipEffects, bool __state)
        {
            try
            {
                // preflight reads each argument of this call from the IL: keep them inline and in this order.
                if (AlertRules.ArmOnEquip(__state, triggerEquipEffects, __instance, Player.m_localPlayer, item,
                        __instance.RightItem, __instance.LeftItem, Trollstav.Is(item), PickupPatch.Depth, ShowHandItemsPatch.EatRestore))
                {
                    Alerts.OnLocal(AlertKind.Arm);
                }
            }
            catch (Exception e)
            {
                Trollstav.Report("Equip alert failed", e);
            }
        }
    }

    /// <summary>
    /// Marks Humanoid.Pickup, which equips a weapon picked up while the hands are empty. The finalizer runs whether
    /// or not Pickup throws, so the mark can never stick.
    /// </summary>
    [HarmonyPatch(typeof(Humanoid), nameof(Humanoid.Pickup), new Type[] { typeof(UnityEngine.GameObject), typeof(bool), typeof(bool) })]
    internal static class PickupPatch   // preflight: exact shape of Prefix and Finalizer
    {
        public static int Depth;

        private static void Prefix()
        {
            Depth++;
        }

        private static void Finalizer()
        {
            if (Depth > 0) Depth--;
        }
    }

    /// <summary>
    /// Marks Humanoid.ShowHandItems when it restores the weapon after eating (onlyRightHand true, from
    /// UpdateUseVisual). The hide/show weapons key calls it with onlyRightHand false: that is the player drawing the
    /// weapon, which does count.
    /// </summary>
    [HarmonyPatch(typeof(Humanoid), "ShowHandItems")]
    internal static class ShowHandItemsPatch   // preflight: exact shape of Prefix and Finalizer
    {
        public static bool EatRestore;

        private static void Prefix(bool onlyRightHand)
        {
            EatRestore = onlyRightHand;
        }

        private static void Finalizer()
        {
            EatRestore = false;
        }
    }

    /// <summary>
    /// The launch alert: Trollstav's attack fires. Attack.ProjectileAttackTriggered runs when the attack's animation
    /// reaches its trigger, only on the attacker's own client, after the attack's ammo and stagger checks - so it
    /// is the use itself, not the button press. Each attack is a fresh Attack object, and the alert is taken once per
    /// object, whatever the animation does (AlertRules.LaunchOnAttack).
    /// </summary>
    [HarmonyPatch(typeof(Attack), "ProjectileAttackTriggered")]
    internal static class ProjectileAttackTriggeredPatch
    {
        private static Attack _last;

        public static void Forget()
        {
            _last = null;
        }

        private static void Postfix(Attack __instance, Humanoid ___m_character)
        {
            try
            {
                // preflight reads each argument of this call from the IL, and that _last is set to __instance before the
                // alert: keep them inline and in this order.
                if (AlertRules.LaunchOnAttack(__instance, _last, ___m_character, Player.m_localPlayer, Trollstav.Is(__instance.GetWeapon())))
                {
                    _last = __instance;
                    Alerts.OnLocal(AlertKind.Launch);
                }
            }
            catch (Exception e)
            {
                Trollstav.Report("Launch alert failed", e);
            }
        }
    }

    /// <summary>Registers alert sharing for each session, where the game registers its own calls.</summary>
    [HarmonyPatch(typeof(Game), "Start")]
    internal static class GameStartPatch
    {
        private static void Postfix()
        {
            try
            {
                Sharing.EnsureRegistered();
            }
            catch (Exception e)
            {
                Trollstav.Report("Alert sharing setup failed", e);
            }
        }
    }
}
