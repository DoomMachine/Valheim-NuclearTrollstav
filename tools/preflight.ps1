<#
.SYNOPSIS
  Checks a compiled NuclearTrollstav.dll against the shipped game, without launching it.

.DESCRIPTION
  1. identity: BepInPlugin GUID DoomMachine.NuclearTrollstav, name NuclearTrollstav, the expected version, the
     client only (valheim.exe), the "loaded" log line; each setting's default and allowed range (the README's table,
     and CooldownMinutes 0..1440), and each setting's key bound to the field of its own name
  2. Harmony: every [HarmonyPatch] target type and method still exists in the game, every patch parameter is a
     target parameter, a field injection of the target type or a Harmony injection, no patch priority sits on a class
     (Harmony would ignore it there), and every patch class is applied: once the settings are bound (Awake returns
     early only when binding them fails), Awake sets up Harmony and then, with no other condition, calls ApplyPatches,
     which calls Harmony.PatchAll(Type) - the only PatchAll in the plugin - on each class of a list naming them all,
     from the first
  3. every type and member the plugin uses in the game, Unity, BepInEx and Harmony resolves with its exact
     signature (a deliberately wrong member fails to resolve, so the check cannot pass vacuously); it calls or reads
     no non-public game member directly; the game members it references are exactly a reviewed list, game fields are
     only read, and nothing is reached by name (reflection, Traverse, AccessTools, SendMessage, Delegate.CreateDelegate,
     MonoBehaviour's Invoke/StartCoroutine by name) - so a new use of the game (a save field, a chat message, another
     network call) fails until it is reviewed
  4. the game still does what the triggers rely on: saved gear put back at login, respawn and world load, inventory
     drags and NPC gear pass triggerEquipEffects false to Humanoid.EquipItem, and no caller of EquipItem is new; the
     weapon comes back after eating through ShowHandItems(onlyRightHand: true) and the hide/show key through
     ShowHandItems(false); Humanoid.Pickup equips a picked-up weapon itself; an attack's projectile trigger runs through
     Attack.ProjectileAttackTriggered, called only from Attack.OnAttackTrigger, whose callers are Humanoid.OnAttackTrigger
     and Attack.StartWithoutAnimation; and Humanoid.OnAttackTrigger returns unless ZNetView.IsOwner before it calls
     Attack.OnAttackTrigger (the branch is followed)
  5. the plugin's decisions, read from its IL - each is a call into AlertRules (tested in tests\), and preflight checks
     where each input comes from and that the call's result decides, the right way round (false skips the action):
     - arm alert: AlertRules.ArmOnEquip(the before-state, triggerEquipEffects, the equipper, the local player, the
       item, the hands after, Trollstav.Is(the item), the pickup mark, the after-eating mark) decides
       Alerts.OnLocal(Arm); the before-state is set to true and then to AlertRules.InHand(item, the hands before), and
       nothing else; the pickup mark counts up in a Prefix and down in a Finalizer (exactly "if (Depth > 0) Depth--"),
       the after-eating mark is ShowHandItems' onlyRightHand and is cleared in a Finalizer; Trollstav.Is returns
       AlertRules.IsTrollstav(the item's prefab name, its name token)
     - launch alert: AlertRules.LaunchOnAttack(the attack, the last one, the attacker, the local player,
       Trollstav.Is(the attack's weapon)) decides Alerts.OnLocal(Launch), and the attack itself is recorded before it
       (the Postfix's only store to the latch)
     - hearing: AlertRules.MayHear(HearOthers, the send in progress, the sender, ZNet.GetUID(), the sender's loaded
       character, the local player, the local player's IsDead(), x, y and z of the sender's position minus the local
       player's - set only there or to zero - and HearingRange) decides Alerts.OnRemote, with the kind
       AlertWire.TryDecode read from the package's bytes; the character is the loaded player whose ZDOID matches both
       numbers sent
     - sharing: ShareMyAlerts and a throttle (this alert's kind, the clock, 5 s) decide Sharing.Send(this kind); the
       message is exactly new ZPackage(AlertWire.Encode(kind, the character's ZDOID user and id)) - the only Encode,
       and nothing is ever written into a ZPackage, so no position - sent by one InvokeRoutedRPC(Everybody, the
       registered name) whose parameters are exactly { that ZPackage }, with the send-in-progress flag set before the
       call, inside the try whose finally clears it; the send has its own throttle; the handler registered is OnAlert,
       and Game.Start registers it
     - can it be heard now: AlertRules.Audible(its sound loaded, ZNet.instance, the local player alive, the routed
       audio source, the Volume setting clamped, a cinematic, the listener's volume, AudioMan, the game's effect volume)
       decides every Offer (local and remote, of that alert's kind; CanPlay tests Clips[kind] != null) and, as
       canStart = WaitingCount > 0 && CanPlayAny(), whether a waiting alert may start; waiting alerts are dropped when
       ZNet.instance is gone after being in a world, and when ListenerAlive() is false
     - scheduling: the scheduler's gap is AlertRules' 1 s and its wait limit 30 s, "playing" comes from the audio
       source, every Offer gets (the alert's kind, now) and Tick gets now, where now = Alerts.Now, which is real time,
       and every cooldown given to it is AlertRules.CooldownSeconds of CooldownMinutes
  6. the plugin's other rules: every volume it sets is AlertRules.ClampVolume of the Volume setting, and a volume
     changed in game is applied through Volume.SettingChanged; its one audio source is routed to the mixer group whose
     name == "GUI", and Alerts.Start plays only a routed source and returns after refusing one; it never plays a sound
     another way, changes a listener or mixer setting, or reads AudioMan.m_guiMixer; it writes no file, preference or
     setting and instantiates or destroys no object (its own audio object is made with new GameObject); every patch
     method that makes a call, the network handler, the send, Update and the volume handler catch every exception
     without rethrowing it; another player's refused alerts are logged only through a 10 s throttle, given the
     alert's kind and now, and OnRemote writes no log line itself; the one "playing now" line is written in
     Alerts.Start after Play, only when the start did not throw, and names who set off that alert's kind
  7. every assembly the plugin references is in the game folder
  Many checks read exact instruction shapes - of the lines and methods marked "preflight:" in src\, and of the
  handlers that must have their whole body in a try (no code before it) - so harmless-looking rewrites there can
  fail them: keep those shapes, or change the check with them. Run it after every Valheim update. Exits 1 on any
  failure.

.EXAMPLE
  .\tools\preflight.ps1                                  # the installed BepInEx\plugins\NuclearTrollstav\NuclearTrollstav.dll
  .\tools\preflight.ps1 -Plugin build\NuclearTrollstav.dll
#>
[CmdletBinding(PositionalBinding = $false)]   # every argument named: a stray one is an error
param(
    [string]$Plugin = "",
    [string]$ExpectedVersion = "1.0.0",
    [string]$ValheimDir = ""
)
$ErrorActionPreference = "Stop"
# Defaults are set here, not in param(): powershell.exe -File leaves $PSScriptRoot empty in an advanced script's
# parameter defaults. Drop a trailing \, and the " that powershell.exe -File leaves when a quoted path ending in \ is
# the last argument (anywhere earlier it swallows the arguments after it: leave the \ off).
if ($ValheimDir -eq "") { $ValheimDir = if ($env:VALHEIM) { $env:VALHEIM } else { "E:\SteamLibrary\steamapps\common\Valheim" } }
$ValheimDir = $ValheimDir.TrimEnd('\', '"')
$managed = Join-Path $ValheimDir "valheim_Data\Managed"
$core = Join-Path $ValheimDir "BepInEx\core"
if ($Plugin -eq "") { $Plugin = Join-Path $ValheimDir "BepInEx\plugins\NuclearTrollstav\NuclearTrollstav.dll" }
if (-not (Test-Path -LiteralPath $Plugin)) { Write-Output "FAIL  plugin not found: $Plugin"; exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $managed "assembly_valheim.dll"))) { Write-Output "FAIL  no Valheim at $ValheimDir"; exit 1 }
Add-Type -LiteralPath (Join-Path $core "Mono.Cecil.dll")

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managed)
$resolver.AddSearchDirectory($core)
$rp = New-Object Mono.Cecil.ReaderParameters
$rp.AssemblyResolver = $resolver
$rp.InMemory = $true
$plug = [Mono.Cecil.ModuleDefinition]::ReadModule((Resolve-Path -LiteralPath $Plugin).ProviderPath, $rp)
$checks = 0
$failedChecks = @{}   # check number -> $true: one failed check is counted once, however many lines it prints
function Ok($m) { Write-Output "  ok    $m" }
function Fail($m) { Write-Output "  FAIL  $m"; $script:failedChecks[$script:checks] = $true }
Write-Output ("Checking {0}" -f $Plugin)

# ---------------------------------------------------------------------------------------------------------------
# IL helpers
# ---------------------------------------------------------------------------------------------------------------
function Get-AllTypes($module) {
    # Every type including nested ones (iterator and lambda classes are nested): ModuleDefinition.Types lists only
    # the top-level types.
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    foreach ($t in $module.Types) { $queue.Enqueue($t) }
    while ($queue.Count -gt 0) { $t = $queue.Dequeue(); [void]$out.Add($t); foreach ($n in $t.NestedTypes) { $queue.Enqueue($n) } }
    return ,$out
}
function Get-PluginMethod($typeName, $methodName) {
    foreach ($t in (Get-AllTypes $plug)) {
        if ($t.Name -ne $typeName) { continue }
        foreach ($m in $t.Methods) { if ($m.Name -eq $methodName -and $m.HasBody) { return $m } }
    }
    return $null
}
function Get-Owner($m) { return "{0}::{1}" -f $m.DeclaringType.FullName, $m.Name }
function Get-ArgumentSources($m, [int]$callAt) {
    # Replays the evaluation stack over the method's code before instruction $callAt and returns, for each value that
    # instruction consumes (the instance first), the index of the instruction that pushed it; $null if it does not add
    # up. The stack is carried along each branch to its target (a ?. or ?? earlier in the method keeps its value on
    # the stack across its branch), and after an unconditional jump the replay continues with the stack recorded for
    # the next instruction, if any. A catch or filter handler starts with the exception object on an empty stack.
    $ins = @($m.Body.Instructions)
    $index = @{}; for ($k = 0; $k -lt $ins.Count; $k++) { $index[$ins[$k].Offset] = $k }
    $saved = @{}
    $stack = New-Object System.Collections.ArrayList
    $dead = $false
    for ($k = 0; $k -lt $callAt; $k++) {
        $i = $ins[$k]
        if ($saved.ContainsKey($k)) { if ($dead) { $stack = New-Object System.Collections.ArrayList (, $saved[$k]) } }
        elseif ($dead) { $stack = New-Object System.Collections.ArrayList }
        $dead = $false
        foreach ($h in $m.Body.ExceptionHandlers) {
            $ht = "$($h.HandlerType)"
            if ((($ht -eq "Catch" -or $ht -eq "Filter") -and $h.HandlerStart -eq $i) -or ($ht -eq "Filter" -and $h.FilterStart -eq $i)) { $stack = New-Object System.Collections.ArrayList; [void]$stack.Add($k) }
            elseif (($ht -eq "Finally" -or $ht -eq "Fault") -and $h.HandlerStart -eq $i) { $stack = New-Object System.Collections.ArrayList }
        }
        $pop = "$($i.OpCode.StackBehaviourPop)"; $push = "$($i.OpCode.StackBehaviourPush)"; $flow = "$($i.OpCode.FlowControl)"
        $nPop = 0
        if ($pop -eq "Varpop") {
            if ($flow -eq "Return") { $nPop = if ($m.ReturnType.FullName -eq "System.Void") { 0 } else { 1 } }
            else { $nPop = $i.Operand.Parameters.Count; if ($i.Operand.HasThis -and $i.OpCode.Name -ne "newobj") { $nPop++ } }
        }
        elseif ($pop -ne "Pop0" -and $pop -ne "PopAll") { $nPop = @($pop -split "_").Count }
        if ($i.OpCode.Name -eq "leave" -or $i.OpCode.Name -eq "leave.s") { $nPop = 0; $stack.Clear() }
        if ($nPop -gt $stack.Count) { return $null }
        $src = $k
        if ($i.OpCode.Name -like "conv.*" -and $stack.Count -ge 1) { $src = $stack[$stack.Count - 1] }   # a converted value keeps its source
        if ($nPop -gt 0) { $stack.RemoveRange($stack.Count - $nPop, $nPop) }
        if ($flow -eq "Cond_Branch" -or $flow -eq "Branch") {
            $targets = @($i.Operand)
            foreach ($tg in $targets) { $ti = $index[$tg.Offset]; if (-not $saved.ContainsKey($ti)) { $saved[$ti] = @($stack.ToArray()) } }
            if ($flow -eq "Branch") { $dead = $true }
            continue
        }
        if ($flow -eq "Return" -or $flow -eq "Throw") { $dead = $true; continue }
        $nPush = 1
        if ($push -eq "Push0") { $nPush = 0 }
        elseif ($push -eq "Push1_push1") { $nPush = 2 }
        elseif ($push -eq "Varpush" -and $i.Operand.ReturnType.FullName -eq "System.Void") { $nPush = 0 }
        for ($j = 0; $j -lt $nPush; $j++) { [void]$stack.Add($src) }
    }
    if ($dead -and $saved.ContainsKey($callAt)) { $stack = New-Object System.Collections.ArrayList (, $saved[$callAt]) }
    elseif ($dead) { $stack = New-Object System.Collections.ArrayList }
    $c = $ins[$callAt]; $n = 0
    if ($c.Operand -is [Mono.Cecil.MethodReference]) { $n = $c.Operand.Parameters.Count; if ($c.Operand.HasThis -and $c.OpCode.Name -ne "newobj") { $n++ } }
    elseif ($c.OpCode.Name -eq "stsfld" -or $c.OpCode.Name -eq "starg" -or $c.OpCode.Name -eq "starg.s" -or $c.OpCode.Name -like "stloc*") { $n = 1 }
    elseif ($c.OpCode.Name -like "stind.*" -or $c.OpCode.Name -eq "stfld") { $n = 2 }
    if ($stack.Count -lt $n) { return $null }
    return ,@($stack.GetRange($stack.Count - $n, $n))
}
function Get-Literal($ins, [int]$at) {
    # The number an instruction pushes when it is a literal (int, long, float or double), else $null.
    if ($at -lt 0) { return $null }
    $n = $ins[$at].OpCode.Name
    if ($n -match '^ldc\.i4\.([0-8])$') { return [double]$Matches[1] }
    if ($n -eq "ldc.i4.m1") { return [double]-1 }
    if ($n -eq "ldc.i4.s" -or $n -eq "ldc.i4" -or $n -eq "ldc.i8" -or $n -eq "ldc.r4" -or $n -eq "ldc.r8") { return [double]"$($ins[$at].Operand)" }
    return $null
}
function Get-ArgName($m, $i) {
    # The parameter an ldarg loads (these methods are all static), else $null.
    $n = $i.OpCode.Name
    if ($n -match '^ldarg\.([0-3])$') { $x = [int]$Matches[1]; if ($x -lt $m.Parameters.Count) { return $m.Parameters[$x].Name }; return $null }
    if ($n -eq "ldarg" -or $n -eq "ldarg.s") { return $i.Operand.Name }
    return $null
}
function Get-LocalIndex($i) {
    $n = $i.OpCode.Name
    if ($n -match '^(ldloc|stloc)\.([0-3])$') { return [int]$Matches[2] }
    if ($n -match '^(ldloc|ldloca|stloc)(\.s)?$') { return $i.Operand.Index }
    return $null
}
function Test-Is($i, [string]$kind, [string]$typeName, [string]$memberName) {
    # Does instruction $i (a call/field access, by opcode family $kind: call, ldsfld, stsfld, newobj) touch Type::Member?
    if ($null -eq $i -or -not ($i.Operand -is [Mono.Cecil.MemberReference])) { return $false }
    $ok = switch ($kind) { "call" { $i.OpCode.Name -eq "call" -or $i.OpCode.Name -eq "callvirt" } default { $i.OpCode.Name -eq $kind } }
    return $ok -and $i.Operand.Name -eq $memberName -and $i.Operand.DeclaringType -and $i.Operand.DeclaringType.Name -eq $typeName
}
function Find-Calls($m, [string]$typeName, [string]$memberName) {
    # The indexes of the calls, written out one by one: callers collect them with @(...). (Returning ,$array instead
    # would make @(...) an array holding one array - the trap that made an earlier check unable to fail.)
    $ins = @($m.Body.Instructions)
    for ($k = 0; $k -lt $ins.Count; $k++) { if (Test-Is $ins[$k] "call" $typeName $memberName) { $k } }
}
function Test-Decides($m, [int]$guardAt, [int]$actionAt) {
    # The bool pushed by instruction $guardAt decides the action at $actionAt, the right way round. Either the next
    # instruction is brfalse jumping past the action ("if (X) action;"), or it is brtrue jumping to or before the action
    # over an exit - leave or ret - that false falls into ("if (!X) return; ... action;").
    $ins = @($m.Body.Instructions)
    if ($guardAt -lt 0 -or $actionAt -le $guardAt + 1) { return $false }
    $br = $ins[$guardAt + 1]
    $target = [array]::IndexOf($ins, $br.Operand)
    if ($br.OpCode.Name -eq "brfalse" -or $br.OpCode.Name -eq "brfalse.s") { return $target -gt $actionAt }
    if ($br.OpCode.Name -eq "brtrue" -or $br.OpCode.Name -eq "brtrue.s") {
        return $target -le $actionAt -and $target -gt $guardAt + 1 -and $ins[$guardAt + 2].OpCode.Name -match '^(leave|leave\.s|ret)$'
    }
    return $false
}
function Test-SettingValue($m, [int]$at, [string]$setting) {
    # Instruction $at is Plugin.<setting>.Value: callvirt ConfigEntry`1::get_Value right after ldsfld Plugin::<setting>.
    $ins = @($m.Body.Instructions)
    if ($at -lt 1) { return $false }
    return (Test-Is $ins[$at] "call" "ConfigEntry``1" "get_Value") -and (Test-Is $ins[$at - 1] "ldsfld" "Plugin" $setting)
}
function Test-CatchAll($m) {
    # The method's work sits in one try whose catch (System.Exception) does not rethrow, and nothing but a short
    # prologue of plain stores comes before the try (EquipItemPatch.Prefix sets __state first).
    if (-not $m) { return "method not found" }
    $ins = @($m.Body.Instructions)
    $h = @($m.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Catch" -and $_.CatchType -and $_.CatchType.FullName -eq "System.Exception" })
    if ($h.Count -lt 1) { return "no catch (Exception)" }
    $outer = $h | Sort-Object { [array]::IndexOf($ins, $_.TryStart) } | Select-Object -First 1
    $tryStart = [array]::IndexOf($ins, $outer.TryStart)
    for ($k = 0; $k -lt $tryStart; $k++) { if ($ins[$k].OpCode.Name -notmatch '^(nop|ldarg.*|ldc\..*|ldnull|stind\..*|stloc.*)$') { return "code before the try: $($ins[$k].OpCode.Name)" } }
    $hStart = [array]::IndexOf($ins, $outer.HandlerStart)
    $hEnd = if ($outer.HandlerEnd) { [array]::IndexOf($ins, $outer.HandlerEnd) } else { $ins.Count }
    for ($k = $hStart; $k -lt $hEnd; $k++) { if ($ins[$k].OpCode.Name -eq "throw" -or $ins[$k].OpCode.Name -eq "rethrow") { return "the catch rethrows" } }
    for ($k = $hEnd; $k -lt $ins.Count; $k++) {
        $inOther = @($m.Body.ExceptionHandlers | Where-Object { $_ -ne $outer -and [array]::IndexOf($ins, $_.TryStart) -le $k -and ($null -eq $_.HandlerEnd -or [array]::IndexOf($ins, $_.HandlerEnd) -gt $k) }).Count -gt 0
        if (-not $inOther -and $ins[$k].OpCode.Name -notmatch '^(nop|ret|ldloc.*|ldarg.*)$') { return "code after the catch: $($ins[$k].OpCode.Name)" }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== identity =="
$checks++
$bep = $null; $procs = @()
foreach ($t in $plug.Types) {
    foreach ($ca in $t.CustomAttributes) {
        if ($ca.AttributeType.Name -eq "BepInPlugin") { $bep = @($ca.ConstructorArguments | ForEach-Object { "$($_.Value)" }) }
        if ($ca.AttributeType.Name -eq "BepInProcess") { $procs += "$($ca.ConstructorArguments[0].Value)" }
    }
}
if ($bep -and $bep[0] -ceq "DoomMachine.NuclearTrollstav" -and $bep[1] -ceq "NuclearTrollstav" -and $bep[2] -ceq $ExpectedVersion) { Ok ("BepInPlugin {0} / {1} / {2}" -f $bep[0], $bep[1], $bep[2]) }
else { Fail ("BepInPlugin is '{0}', expected 'DoomMachine.NuclearTrollstav / NuclearTrollstav / {1}'" -f ($bep -join " / "), $ExpectedVersion) }
$checks++
if ($procs.Count -eq 1 -and $procs[0] -ceq "valheim.exe") { Ok "BepInProcess valheim.exe only - the client; a dedicated server does not load it" }
else { Fail ("BepInProcess is '{0}', expected valheim.exe alone" -f ($procs -join ", ")) }
$checks++
$asmVersion = "$($plug.Assembly.Name.Version)"
$fileVersion = ""
foreach ($ca in $plug.Assembly.CustomAttributes) { if ($ca.AttributeType.Name -eq "AssemblyFileVersionAttribute") { $fileVersion = "$($ca.ConstructorArguments[0].Value)" } }
if ($asmVersion -eq "$ExpectedVersion.0" -and $fileVersion -eq "$ExpectedVersion.0") { Ok "assembly and file version $asmVersion (NuclearTrollstav.csproj)" }
else { Fail ("assembly version {0}, file version {1}, expected {2}.0 - NuclearTrollstav.csproj's <Version> is out of step" -f $asmVersion, $fileVersion, $ExpectedVersion) }
$checks++
$loadedLine = "NuclearTrollstav $ExpectedVersion loaded."
$awake = Get-PluginMethod "Plugin" "Awake"
$hasLine = $awake -and @($awake.Body.Instructions | Where-Object { $_.OpCode.Name -eq "ldstr" -and "$($_.Operand)" -ceq $loadedLine }).Count -gt 0
if ($hasLine) { Ok "Awake logs '$loadedLine'" } else { Fail "Plugin.Awake does not log '$loadedLine'" }
# The settings as the README's table states them: section, key, default, allowed range.
$checks++
$wantSettings = [ordered]@{
    "Sound.Volume" = @("0.5", "0..1")
    "Sound.ArmSound" = @("Nuclear Silo Arm.mp3", "")
    "Sound.LaunchSound" = @("Nuclear Missile Launch Sound.mp3", "")
    "Alerts.CooldownMinutes" = @("30", "0..1440")
    "Multiplayer.ShareMyAlerts" = @("1", "")
    "Multiplayer.HearOthers" = @("1", "")
    "Multiplayer.HearingRange" = @("100", "1..1000")
}
$gotSettings = [ordered]@{}
if ($awake) {
    $ains = @($awake.Body.Instructions)
    $range = ""
    for ($k = 0; $k -lt $ains.Count; $k++) {
        $op = $ains[$k].Operand
        if ($ains[$k].OpCode.Name -eq "newobj" -and $op.DeclaringType.Name -eq "AcceptableValueRange``1") {
            $src = Get-ArgumentSources $awake $k
            $range = if ($src) { "{0}..{1}" -f (Get-Literal $ains $src[0]), (Get-Literal $ains $src[1]) } else { "?" }
        }
        if (($ains[$k].OpCode.Name -eq "callvirt" -or $ains[$k].OpCode.Name -eq "call") -and $op.Name -eq "Bind" -and $op.DeclaringType.Name -eq "ConfigFile") {
            $src = Get-ArgumentSources $awake $k
            if (-not $src) { $gotSettings["?$k"] = @("?", "?"); continue }
            $section = "$($ains[$src[1]].Operand)"; $key = "$($ains[$src[2]].Operand)"
            $d = $ains[$src[3]]
            $default = if ($d.OpCode.Name -eq "ldstr") { "$($d.Operand)" } else { "$(Get-Literal $ains $src[3])" }
            $hasDescription = $op.Parameters.Count -eq 4 -and $op.Parameters[3].ParameterType.Name -eq "ConfigDescription"
            $gotSettings["$section.$key"] = @($default, $(if ($hasDescription) { $range } else { "" }))
            $range = ""
        }
    }
}
$settingDiffs = @()
foreach ($key in $wantSettings.Keys) {
    if (-not $gotSettings.Contains($key)) { $settingDiffs += "$key missing"; continue }
    if ($gotSettings[$key][0] -ne $wantSettings[$key][0] -or $gotSettings[$key][1] -ne $wantSettings[$key][1]) { $settingDiffs += ("{0} = {1} [{2}], expected {3} [{4}]" -f $key, $gotSettings[$key][0], $gotSettings[$key][1], $wantSettings[$key][0], $wantSettings[$key][1]) }
}
foreach ($key in $gotSettings.Keys) { if (-not $wantSettings.Contains($key)) { $settingDiffs += "$key is not in the README's table" } }
if ($settingDiffs.Count -eq 0) { Ok "the 7 settings have the README's defaults and ranges (Volume 0..1, CooldownMinutes 30, HearingRange 100)" }
else { Fail ("settings differ from the README: {0}" -f ($settingDiffs -join "; ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== Harmony patch targets =="
$gameModules = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $managed -Filter *.dll) + @(Get-ChildItem -LiteralPath $core -Filter *.dll)) {
    try { $gameModules[$f.Name] = [Mono.Cecil.ModuleDefinition]::ReadModule($f.FullName, $rp) } catch { }
}
$valheim = $gameModules["assembly_valheim.dll"]
# Names Harmony fills in itself; any other patch parameter must be named (and typed) like a parameter of the target,
# or be a field injection (three underscores and a field of the target's type), or Harmony refuses the patch when the
# game starts - after every build check has passed.
$injected = @("__instance", "__result", "__state", "__runOriginal", "__originalMethod", "__args", "__exception")
$patchClasses = @()
$expectedPatches = 5
foreach ($t in $plug.GetTypes()) {
    foreach ($ca in $t.CustomAttributes) {
        if ($ca.AttributeType.Name -ne "HarmonyPatch" -or $ca.ConstructorArguments.Count -lt 2) { continue }
        $patchClasses += $t; $checks++
        $typeName = "$($ca.ConstructorArguments[0].Value)"; $method = "$($ca.ConstructorArguments[1].Value)"
        $want = $null   # the argument types, when the attribute names an overload
        if ($ca.ConstructorArguments.Count -ge 3) { $want = @($ca.ConstructorArguments[2].Value | ForEach-Object { $_.Value.FullName }) }
        $target = $null; $targetType = $null; $ambiguous = $false
        foreach ($mod in $gameModules.Values) {
            $gt = $mod.GetType($typeName)
            if (-not $gt) { continue }
            $matching = @($gt.Methods | Where-Object { $_.Name -eq $method })
            if ($null -ne $want) { $matching = @($matching | Where-Object { (@($_.Parameters | ForEach-Object { $_.ParameterType.FullName }) -join ",") -eq ($want -join ",") }) }
            if ($matching.Count -gt 1) { $ambiguous = $true; break }
            if ($matching.Count -eq 1) { $target = $matching[0]; $targetType = $gt; break }
        }
        $shown = "{0}.{1}" -f $typeName, $method
        if ($null -ne $want) { $shown += "(" + ($want -join ", ") + ")" }
        if ($ambiguous) { Fail ("{0}: {1} is overloaded - name the overload in the attribute" -f $t.Name, $shown); continue }
        if (-not $target) { Fail ("{0}: {1} not found in the game" -f $t.Name, $shown); continue }
        $badParams = @()
        foreach ($pm in $t.Methods | Where-Object { @("Prefix", "Postfix", "Finalizer") -contains $_.Name }) {
            foreach ($p in $pm.Parameters) {
                $pType = $p.ParameterType.FullName.TrimEnd('&')
                if ($injected -contains $p.Name) { continue }
                if ($p.Name.StartsWith("___")) {
                    $field = $targetType.Fields | Where-Object { $_.Name -eq $p.Name.Substring(3) } | Select-Object -First 1
                    if (-not $field -or $field.FieldType.FullName -ne $pType) { $badParams += ("{0}({1} {2}): no such field on {3}" -f $pm.Name, $pType, $p.Name, $typeName) }
                    continue
                }
                $tp = $target.Parameters | Where-Object { $_.Name -eq $p.Name } | Select-Object -First 1
                if (-not $tp -or $tp.ParameterType.FullName -ne $pType) { $badParams += ("{0}({1} {2})" -f $pm.Name, $pType, $p.Name) }
            }
        }
        if ($badParams.Count -eq 0) { Ok ("{0} -> {1}, its parameters match" -f $t.Name, $shown) }
        else { Fail ("{0} -> {1}: no such target parameter, field or injection: {2}" -f $t.Name, $shown, ($badParams -join ", ")) }
    }
}
$checks++
if ($patchClasses.Count -eq $expectedPatches) { Ok "$($patchClasses.Count) Harmony patch classes found" } else { Fail "expected $expectedPatches [HarmonyPatch] classes, found $($patchClasses.Count)" }
$checks++
$classLevel = @($patchClasses | Where-Object { @($_.CustomAttributes | Where-Object { $_.AttributeType.Name -eq "HarmonyPriority" }).Count -gt 0 } | ForEach-Object { $_.Name })
if ($classLevel.Count -eq 0) { Ok "no [HarmonyPriority] on a patch class, where Harmony would ignore it" }
else { Fail ("[HarmonyPriority] on the class, which PatchAll(Type) ignores - put it on the patch method: {0}" -f ($classLevel -join ", ")) }
# Every class applied: its ldtoken is in ApplyPatches' list, PatchAll(Type) - the plugin's only PatchAll - runs in
# ApplyPatches on an element of that list, and Awake calls ApplyPatches.
$checks++
$apply = Get-PluginMethod "Plugin" "ApplyPatches"
$listed = @{}
if ($apply) { foreach ($i in $apply.Body.Instructions) { if ($i.OpCode.Name -eq "ldtoken" -and $i.Operand -is [Mono.Cecil.TypeReference]) { $listed[$i.Operand.FullName] = $true } } }
$unlisted = @($patchClasses | Where-Object { -not $listed.ContainsKey($_.FullName) } | ForEach-Object { $_.Name })
$patchAlls = @()
foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; $ins = @($m.Body.Instructions); for ($k = 0; $k -lt $ins.Count; $k++) { if (Test-Is $ins[$k] "call" "Harmony" "PatchAll") { $patchAlls += ,@($m, $k) } } } }
$why = @()
if ($unlisted.Count) { $why += "not in ApplyPatches' list: " + ($unlisted -join ", ") }
if ($patchAlls.Count -ne 1) { $why += "$($patchAlls.Count) PatchAll calls, expected 1" }
else {
    $pm = $patchAlls[0][0]; $pk = $patchAlls[0][1]; $pop = @($pm.Body.Instructions)[$pk].Operand
    if ((Get-Owner $pm) -ne "NuclearTrollstav.Plugin::ApplyPatches") { $why += "PatchAll is in $(Get-Owner $pm)" }
    if ($pop.Parameters.Count -ne 1 -or $pop.Parameters[0].ParameterType.FullName -ne "System.Type") { $why += "PatchAll is not the (Type) overload" }
    $src = Get-ArgumentSources $pm $pk
    $pins = @($pm.Body.Instructions)
    if (-not $src -or $src.Count -lt 2 -or (Get-LocalIndex $pins[$src[1]]) -eq $null) { $why += "PatchAll's type is not the loop's element" }   # PatchAll() has no argument to trace
    else {
        # The loop element: a local stored from ldelem.ref of the ldtoken list.
        $li = Get-LocalIndex $pins[$src[1]]
        $fromList = $false
        for ($k = 1; $k -lt $pins.Count; $k++) { if ($pins[$k].OpCode.Name -like "stloc*" -and (Get-LocalIndex $pins[$k]) -eq $li -and $pins[$k - 1].OpCode.Name -eq "ldelem.ref") { $fromList = $true } }
        if (-not $fromList) { $why += "PatchAll's type is not taken from the list" }
    }
}
if (-not ($awake -and @(Find-Calls $awake "Plugin" "ApplyPatches").Count -eq 1)) { $why += "Awake does not call ApplyPatches" }
if ($why.Count -eq 0) { Ok "every patch class is applied: Awake calls ApplyPatches, which runs PatchAll(Type) - the only PatchAll - on each class of its list" }
else { Fail ("patch classes may not be applied: {0}" -f ($why -join "; ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== game types and members the plugin uses =="
$scopes = @("assembly_valheim", "assembly_utils", "BepInEx", "0Harmony")
$resolved = 0; $bad = @(); $nonPublic = @(); $gameMembers = @{}
$refs = @()
foreach ($tr in $plug.GetTypeReferences()) { $refs += ,@($tr, $tr) }
foreach ($mr in $plug.GetMemberReferences()) { $refs += ,@($mr, $mr.DeclaringType) }
foreach ($pair in $refs) {
    $dt = $pair[1]
    while ($dt.IsNested) { $dt = $dt.DeclaringType }
    $scope = $dt.Scope.Name
    if (-not ($scopes -contains $scope -or $scope -like "UnityEngine*")) { continue }
    $r = $null
    try { $r = $pair[0].Resolve() } catch { }
    if ($null -eq $r) { $bad += ("{0} ({1})" -f $pair[0].FullName, $scope); continue }
    $resolved++
    if ($scope -eq "assembly_valheim" -or $scope -eq "assembly_utils") {
        if ($pair[0] -is [Mono.Cecil.MemberReference] -and -not ($pair[0] -is [Mono.Cecil.TypeReference])) { $gameMembers[("{0}::{1}" -f $pair[1].Name, $pair[0].Name)] = $true }
        $isPublic = $true
        if ($r -is [Mono.Cecil.TypeDefinition]) { $isPublic = $r.IsPublic -or $r.IsNestedPublic }
        elseif ($r -is [Mono.Cecil.MethodDefinition] -or $r -is [Mono.Cecil.FieldDefinition]) { $isPublic = $r.IsPublic -and ($r.DeclaringType.IsPublic -or $r.DeclaringType.IsNestedPublic) }
        if (-not $isPublic) { $nonPublic += $pair[0].FullName }
    }
}
$checks++
if ($bad.Count -eq 0) { Ok "all $resolved type and member references into the game, Unity, BepInEx and Harmony resolve" }
else { foreach ($b in $bad) { Fail "does not resolve: $b" } }
$checks++
if ($nonPublic.Count -eq 0) { Ok "every game member it calls or reads is public (private ones are reached only as patch targets and field injections)" }
else { foreach ($n in @($nonPublic | Sort-Object -Unique)) { Fail "calls or reads a non-public game member directly (it would fail at run time): $n" } }
$checks++
$probe = $plug.GetMemberReferences() | Where-Object { $_.DeclaringType.Scope.Name -eq "assembly_valheim" -and $_ -is [Mono.Cecil.MethodReference] } | Select-Object -First 1
$fake = $null
if ($probe) {
    $fake = New-Object Mono.Cecil.MethodReference(($probe.Name + "_DoesNotExist"), $probe.ReturnType, $probe.DeclaringType)
    $fake.HasThis = $probe.HasThis
    foreach ($p in $probe.Parameters) { $fake.Parameters.Add((New-Object Mono.Cecil.ParameterDefinition($p.ParameterType))) }
}
$fr = $null
if ($fake) { try { $fr = $fake.Resolve() } catch { } }
if ($fake -and $null -eq $fr) { Ok "a deliberately wrong member ($($fake.Name)) fails to resolve - the check is not vacuous" }
else { Fail "the negative control did not fail to resolve (or no game method was found to build it from)" }
# The game members it may touch, reviewed one by one: reading the local player, the hands, the item's name, the
# attack's weapon, the loaded players and their ids, ZNet's and ZRoutedRpc's session calls, the audio mixer, the
# cinematic test - and nothing that writes the world, a save, a map or another player's game.
$checks++
$allowedGame = @(
    "Attack::GetWeapon", "AudioMan::get_instance", "AudioMan::GetSFXVolume", "AudioMan::m_masterMixer",
    "Character::GetZDOID", "Character::IsDead", "CinematicsManager::IsStartedPlaying", "Humanoid::get_LeftItem", "Humanoid::get_RightItem",
    "ItemData::m_dropPrefab", "ItemData::m_shared", "Player::GetAllPlayers", "Player::m_localPlayer",
    "SharedData::m_name", "ZDOID::get_ID", "ZDOID::get_UserID", "ZDOID::IsNone", "ZNet::get_HaveStopped",
    "ZNet::get_instance", "ZNet::GetUID", "ZPackage::.ctor", "ZPackage::GetArray", "ZRoutedRpc::get_instance",
    "ZRoutedRpc::InvokeRoutedRPC", "ZRoutedRpc::Register"
)
$extra = @($gameMembers.Keys | Where-Object { $allowedGame -notcontains $_ } | Sort-Object)
$unused = @($allowedGame | Where-Object { -not $gameMembers.ContainsKey($_) })
if ($extra.Count -eq 0 -and $unused.Count -eq 0) { Ok ("the {0} game members it touches are exactly the reviewed list" -f $gameMembers.Count) }
elseif ($extra.Count -gt 0) { Fail ("touches game members not on the reviewed list - review each, then add it: {0}" -f ($extra -join ", ")) }
else { Fail ("listed game members it no longer touches - take them off the reviewed list: {0}" -f ($unused -join ", ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== what the game does that the triggers rely on =="
function Get-GameCallSites([string]$declaringType, [string]$name) {
    $sites = @()
    foreach ($t in (Get-AllTypes $valheim)) {
        foreach ($m in $t.Methods) {
            if (-not $m.HasBody) { continue }
            $ins = @($m.Body.Instructions)
            for ($k = 0; $k -lt $ins.Count; $k++) {
                $op = $ins[$k].Operand
                if ($op -is [Mono.Cecil.MethodReference] -and $op.Name -eq $name -and $op.DeclaringType.FullName -eq $declaringType) { $sites += ,@($m, $k) }
            }
        }
    }
    return ,$sites
}
# Every caller of Humanoid.EquipItem and the triggerEquipEffects it passes (1.0.16). A caller that is not on this
# list is new: decide whether it is a player selecting a weapon before trusting the arm alert again.
$knownEquipCallers = @{
    "Player::EquipInventoryItems" = "0"            # saved gear back on at login, respawn, world load
    "InventoryGui::OnSelectedItem" = "0"           # a drag or move in the inventory
    "Humanoid::GiveDefaultItem" = "0"              # NPC gear
    "Humanoid::ToggleEquipped" = "1"
    "Player::ToggleEquipped" = "1"                 # hotbar, inventory right click, gamepad, radial menu
    "Player::UpdateActionQueue" = "1"              # a queued equip completes
    "Humanoid::ShowHandItems" = "1"                # hide/show key, and after eating (filtered)
    "Humanoid::Pickup" = "1"                       # auto-equip of a picked-up weapon (filtered)
    "Humanoid::EquipBestWeapon" = "1"              # monster AI
    "Attack::EquipAmmoItem" = "*"
}
$mustBeFalse = @("Player::EquipInventoryItems", "InventoryGui::OnSelectedItem", "Humanoid::GiveDefaultItem")
$equipSites = Get-GameCallSites "Humanoid" "EquipItem"
$seen = @{}; $unknown = @(); $wrong = @()
foreach ($s in $equipSites) {
    $m = $s[0]; $k = $s[1]; $ins = @($m.Body.Instructions)
    $owner = "{0}::{1}" -f $m.DeclaringType.Name, $m.Name
    $src = Get-ArgumentSources $m $k
    $arg = if ($null -eq $src) { "?" } else { $v = Get-Literal $ins $src[2]; if ($null -eq $v) { "?" } else { "$v" } }
    if ($m.DeclaringType.FullName -like "Valheim.UI.HammerItemElement*") { $owner = "Valheim.UI.HammerItemElement (lambda)" }
    $seen[$owner] = $true
    if ($owner -eq "Valheim.UI.HammerItemElement (lambda)") { if ($arg -ne "1") { $wrong += "$owner passes $arg" }; continue }
    if (-not $knownEquipCallers.ContainsKey($owner)) { $unknown += "$owner (triggerEquipEffects $arg)"; continue }
    $want = $knownEquipCallers[$owner]
    if ($want -ne "*" -and $arg -ne $want) { $wrong += "$owner passes $arg, expected $want" }
}
$checks++
if ($equipSites.Count -ge 10 -and $unknown.Count -eq 0) { Ok ("all {0} calls of Humanoid.EquipItem come from the {1} known callers" -f $equipSites.Count, $seen.Count) }
else { Fail ("Humanoid.EquipItem has callers not reviewed for the arm alert: {0}" -f ($(if ($unknown.Count) { $unknown -join "; " } else { "only $($equipSites.Count) call sites found" }))) }
$checks++
$missingFalse = @($mustBeFalse | Where-Object { -not $seen.ContainsKey($_) })
if ($wrong.Count -eq 0 -and $missingFalse.Count -eq 0) { Ok "login/respawn/world-load re-equip, inventory drags and NPC gear pass triggerEquipEffects false; player selections pass true" }
else { Fail ("EquipItem's triggerEquipEffects is not what the arm alert relies on: {0}" -f (@($wrong) + @($missingFalse | ForEach-Object { "$_ no longer calls it" }) -join "; ")) }
$checks++
$showSites = Get-GameCallSites "Humanoid" "ShowHandItems"
$showArgs = @{}
foreach ($s in $showSites) {
    $m = $s[0]; $k = $s[1]; $ins = @($m.Body.Instructions)
    $src = Get-ArgumentSources $m $k
    $arg = if ($null -eq $src) { "?" } else { $v = Get-Literal $ins $src[1]; if ($null -eq $v) { "?" } else { "$v" } }
    $showArgs["{0}::{1}" -f $m.DeclaringType.Name, $m.Name] = $arg
}
if ($showSites.Count -eq 2 -and $showArgs["Humanoid::UpdateUseVisual"] -eq "1" -and $showArgs["Player::Update"] -eq "0") {
    Ok "ShowHandItems: after eating (UpdateUseVisual) onlyRightHand true, the hide/show key (Player.Update) false - no other caller"
} else { Fail ("ShowHandItems callers changed: {0}" -f (($showArgs.GetEnumerator() | ForEach-Object { "$($_.Key) onlyRightHand=$($_.Value)" }) -join "; ")) }
$checks++
$pickupEquips = @($equipSites | Where-Object { ("{0}::{1}" -f $_[0].DeclaringType.Name, $_[0].Name) -eq "Humanoid::Pickup" })
if ($pickupEquips.Count -ge 1) { Ok "Humanoid.Pickup equips the picked-up weapon itself (the pickup mark covers it)" }
else { Fail "Humanoid.Pickup no longer calls EquipItem - check where a picked-up weapon is equipped now" }
$checks++
$patSites = Get-GameCallSites "Attack" "ProjectileAttackTriggered"
$patOwners = @($patSites | ForEach-Object { "{0}::{1}" -f $_[0].DeclaringType.Name, $_[0].Name } | Sort-Object -Unique)
if ($patSites.Count -eq 1 -and $patOwners[0] -eq "Attack::OnAttackTrigger") { Ok "Attack.ProjectileAttackTriggered is called once, from Attack.OnAttackTrigger" }
else { Fail ("Attack.ProjectileAttackTriggered callers changed: {0} site(s) in {1}" -f $patSites.Count, ($patOwners -join ", ")) }
# Only the owner fires: follow the branch after IsOwner. True must reach the Attack.OnAttackTrigger call, false must
# return: brtrue over a ret, or brfalse to a ret.
$checks++
$hat = $null
$hType = $valheim.GetType("Humanoid")
if ($hType) { $hat = $hType.Methods | Where-Object { $_.Name -eq "OnAttackTrigger" -and $_.HasBody } | Select-Object -First 1 }
$ownerOk = $false
if ($hat) {
    $hins = @($hat.Body.Instructions)
    $io = @(Find-Calls $hat "ZNetView" "IsOwner"); $ao = @(Find-Calls $hat "Attack" "OnAttackTrigger")
    if ($io.Count -eq 1 -and $ao.Count -eq 1 -and $io[0] -lt $ao[0]) {
        $br = $hins[$io[0] + 1]
        if ($br.OpCode.Name -like "brtrue*") { $ownerOk = $hins[$io[0] + 2].OpCode.Name -eq "ret" -and [array]::IndexOf($hins, $br.Operand) -le $ao[0] }
        elseif ($br.OpCode.Name -like "brfalse*") { $ownerOk = $br.Operand.OpCode.Name -eq "ret" }
    }
}
if ($ownerOk) { Ok "Humanoid.OnAttackTrigger returns unless ZNetView.IsOwner, before it calls Attack.OnAttackTrigger" }
else { Fail "Humanoid.OnAttackTrigger no longer returns when not the owner before triggering the attack" }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== the plugin's decisions =="
# Arm alert.
$checks++
$ep = Get-PluginMethod "EquipItemPatch" "Postfix"
$why = @()
if (-not $ep) { $why += "no EquipItemPatch.Postfix" }
else {
    $eins = @($ep.Body.Instructions)
    $g = @(Find-Calls $ep "AlertRules" "ArmOnEquip"); $a = @(Find-Calls $ep "Alerts" "OnLocal")
    if ($g.Count -ne 1 -or $a.Count -ne 1) { $why += "expected one ArmOnEquip and one OnLocal" }
    else {
        if (-not (Test-Decides $ep $g[0] $a[0])) { $why += "ArmOnEquip's result does not decide OnLocal (false must branch past it)" }
        $oa = Get-ArgumentSources $ep $a[0]
        if (-not $oa -or (Get-Literal $eins $oa[0]) -ne 0) { $why += "OnLocal is not given Arm (0)" }
        $s = Get-ArgumentSources $ep $g[0]
        if (-not $s) { $why += "ArmOnEquip's arguments cannot be traced" }
        else {
            if ((Get-ArgName $ep $eins[$s[0]]) -ne "__state") { $why += "arg 1 is not __state" }
            if ((Get-ArgName $ep $eins[$s[1]]) -ne "triggerEquipEffects") { $why += "arg 2 is not triggerEquipEffects" }
            if ((Get-ArgName $ep $eins[$s[2]]) -ne "__instance") { $why += "arg 3 is not __instance" }
            if (-not (Test-Is $eins[$s[3]] "ldsfld" "Player" "m_localPlayer")) { $why += "arg 4 is not Player.m_localPlayer" }
            if ((Get-ArgName $ep $eins[$s[4]]) -ne "item") { $why += "arg 5 is not item" }
            if (-not (Test-Is $eins[$s[5]] "call" "Humanoid" "get_RightItem")) { $why += "arg 6 is not RightItem" }
            if (-not (Test-Is $eins[$s[6]] "call" "Humanoid" "get_LeftItem")) { $why += "arg 7 is not LeftItem" }
            if (-not (Test-Is $eins[$s[7]] "call" "Trollstav" "Is")) { $why += "arg 8 is not Trollstav.Is" }
            if (-not (Test-Is $eins[$s[8]] "ldsfld" "PickupPatch" "Depth")) { $why += "arg 9 is not PickupPatch.Depth" }
            if (-not (Test-Is $eins[$s[9]] "ldsfld" "ShowHandItemsPatch" "EatRestore")) { $why += "arg 10 is not ShowHandItemsPatch.EatRestore" }
        }
    }
}
if ($why.Count -eq 0) { Ok "EquipItemPatch.Postfix: ArmOnEquip(__state, triggerEquipEffects, __instance, m_localPlayer, item, RightItem, LeftItem, Trollstav.Is, Depth, EatRestore) decides OnLocal(Arm)" }
else { Fail ("the arm alert is not decided as described: {0}" -f ($why -join "; ")) }
$checks++
$epre = Get-PluginMethod "EquipItemPatch" "Prefix"
$why = @()
if (-not $epre) { $why += "no EquipItemPatch.Prefix" }
else {
    $pins = @($epre.Body.Instructions)
    $ih = @(Find-Calls $epre "AlertRules" "InHand")
    if ($ih.Count -ne 1) { $why += "expected one AlertRules.InHand" }
    else {
        $s = Get-ArgumentSources $epre $ih[0]
        if (-not $s -or (Get-ArgName $epre $pins[$s[0]]) -ne "item" -or -not (Test-Is $pins[$s[1]] "call" "Humanoid" "get_RightItem") -or -not (Test-Is $pins[$s[2]] "call" "Humanoid" "get_LeftItem")) { $why += "InHand is not given (item, RightItem, LeftItem)" }
        if ($pins[$ih[0] + 1].OpCode.Name -ne "stind.i1") { $why += "InHand's result is not stored into __state" }
    }
}
if ($why.Count -eq 0) { Ok "EquipItemPatch.Prefix: __state = InHand(item, RightItem, LeftItem) - the hands before the call" }
else { Fail ("the before-state is not recorded as described: {0}" -f ($why -join "; ")) }
$checks++
$why = @()
$pp = Get-PluginMethod "PickupPatch" "Prefix"; $pf = Get-PluginMethod "PickupPatch" "Finalizer"
$sp = Get-PluginMethod "ShowHandItemsPatch" "Prefix"; $sf = Get-PluginMethod "ShowHandItemsPatch" "Finalizer"
function Get-Ops($m) { return (@($m.Body.Instructions | Where-Object { $_.OpCode.Name -ne "nop" } | ForEach-Object { $x = $_.OpCode.Name; if ($_.Operand -is [Mono.Cecil.FieldReference]) { $x += " " + $_.Operand.DeclaringType.Name + "::" + $_.Operand.Name }; $x }) -join "; ") }
if (-not $pp -or (Get-Ops $pp) -ne "ldsfld PickupPatch::Depth; ldc.i4.1; add; stsfld PickupPatch::Depth; ret") { $why += "PickupPatch.Prefix is not Depth++" }
if (-not $pf -or (Get-Ops $pf) -notmatch 'ldsfld PickupPatch::Depth; ldc\.i4\.1; sub; stsfld PickupPatch::Depth') { $why += "PickupPatch.Finalizer does not count Depth down" }
if (-not $sp -or (Get-Ops $sp) -ne "ldarg.0; stsfld ShowHandItemsPatch::EatRestore; ret" -or $sp.Parameters[0].Name -ne "onlyRightHand") { $why += "ShowHandItemsPatch.Prefix does not set EatRestore = onlyRightHand" }
if (-not $sf -or (Get-Ops $sf) -ne "ldc.i4.0; stsfld ShowHandItemsPatch::EatRestore; ret") { $why += "ShowHandItemsPatch.Finalizer does not clear EatRestore" }
if ($why.Count -eq 0) { Ok "the pickup mark counts up in a Prefix and down in a Finalizer; the after-eating mark is onlyRightHand, cleared in a Finalizer" }
else { Fail ("the marks are not as described: {0}" -f ($why -join "; ")) }
$checks++
$ti = Get-PluginMethod "Trollstav" "Is"
$why = @()
if (-not $ti) { $why += "no Trollstav.Is" }
else {
    $tins = @($ti.Body.Instructions)
    $c = @(Find-Calls $ti "AlertRules" "IsTrollstav")
    if ($c.Count -ne 1 -or $tins[$c[0] + 1].OpCode.Name -ne "ret") { $why += "it does not return AlertRules.IsTrollstav's result" }
    foreach ($need in @(@("ldfld", "ItemData", "m_dropPrefab"), @("ldfld", "ItemData", "m_shared"), @("ldfld", "SharedData", "m_name"))) {
        if (@($tins | Where-Object { Test-Is $_ $need[0] $need[1] $need[2] }).Count -lt 1) { $why += "it does not read $($need[1]).$($need[2])" }
    }
    if (@(Find-Calls $ti "Object" "get_name").Count -lt 1) { $why += "it does not read the prefab's name" }
}
if ($why.Count -eq 0) { Ok "Trollstav.Is returns AlertRules.IsTrollstav of the item's prefab name and name token" }
else { Fail ("Trollstav.Is is not as described: {0}" -f ($why -join "; ")) }
# Launch alert.
$checks++
$ap = Get-PluginMethod "ProjectileAttackTriggeredPatch" "Postfix"
$why = @()
if (-not $ap) { $why += "no ProjectileAttackTriggeredPatch.Postfix" }
else {
    $lins = @($ap.Body.Instructions)
    $g = @(Find-Calls $ap "AlertRules" "LaunchOnAttack"); $a = @(Find-Calls $ap "Alerts" "OnLocal")
    if ($g.Count -ne 1 -or $a.Count -ne 1) { $why += "expected one LaunchOnAttack and one OnLocal" }
    else {
        if (-not (Test-Decides $ap $g[0] $a[0])) { $why += "LaunchOnAttack's result does not decide OnLocal" }
        $oa = Get-ArgumentSources $ap $a[0]
        if (-not $oa -or (Get-Literal $lins $oa[0]) -ne 1) { $why += "OnLocal is not given Launch (1)" }
        $s = Get-ArgumentSources $ap $g[0]
        if (-not $s) { $why += "LaunchOnAttack's arguments cannot be traced" }
        else {
            if ((Get-ArgName $ap $lins[$s[0]]) -ne "__instance") { $why += "arg 1 is not __instance" }
            if (-not (Test-Is $lins[$s[1]] "ldsfld" "ProjectileAttackTriggeredPatch" "_last")) { $why += "arg 2 is not _last" }
            if ((Get-ArgName $ap $lins[$s[2]]) -ne "___m_character") { $why += "arg 3 is not ___m_character" }
            if (-not (Test-Is $lins[$s[3]] "ldsfld" "Player" "m_localPlayer")) { $why += "arg 4 is not Player.m_localPlayer" }
            if (-not (Test-Is $lins[$s[4]] "call" "Trollstav" "Is")) { $why += "arg 5 is not Trollstav.Is" }
            else { $w = Get-ArgumentSources $ap $s[4]; if (-not $w -or -not (Test-Is $lins[$w[0]] "call" "Attack" "GetWeapon")) { $why += "Trollstav.Is is not given the attack's weapon" } }
        }
        $rec = @(for ($k = $g[0]; $k -lt $a[0]; $k++) { if (Test-Is $lins[$k] "stsfld" "ProjectileAttackTriggeredPatch" "_last") { $k } })
        if ($rec.Count -ne 1) { $why += "the attack is not recorded in _last before the alert" }
    }
}
if ($why.Count -eq 0) { Ok "ProjectileAttackTriggeredPatch.Postfix: LaunchOnAttack(__instance, _last, ___m_character, m_localPlayer, Trollstav.Is(GetWeapon())) decides OnLocal(Launch) and records the attack" }
else { Fail ("the launch alert is not decided as described: {0}" -f ($why -join "; ")) }
# Hearing.
$checks++
$oh = Get-PluginMethod "Sharing" "OnAlert"
$why = @()
if (-not $oh) { $why += "no Sharing.OnAlert" }
else {
    $hins = @($oh.Body.Instructions)
    $g = @(Find-Calls $oh "AlertRules" "MayHear"); $a = @(Find-Calls $oh "Alerts" "OnRemote"); $d = @(Find-Calls $oh "AlertWire" "TryDecode")
    if ($g.Count -ne 1 -or $a.Count -ne 1 -or $d.Count -ne 1) { $why += "expected one TryDecode, one MayHear and one OnRemote" }
    else {
        if (-not (Test-Decides $oh $g[0] $a[0])) { $why += "MayHear's result does not decide OnRemote" }
        if (-not (Test-Decides $oh $d[0] $g[0])) { $why += "TryDecode's result does not decide the rest" }
        $s = Get-ArgumentSources $oh $g[0]
        if (-not $s) { $why += "MayHear's arguments cannot be traced" }
        else {
            if (-not (Test-SettingValue $oh $s[0] "HearOthers")) { $why += "arg 1 is not HearOthers" }
            if (-not (Test-Is $hins[$s[1]] "ldsfld" "Sharing" "_inLocalSend")) { $why += "arg 2 is not _inLocalSend" }
            if ((Get-ArgName $oh $hins[$s[2]]) -ne "sender") { $why += "arg 3 is not sender" }
            if (-not (Test-Is $hins[$s[3]] "call" "ZNet" "GetUID")) { $why += "arg 4 is not ZNet.GetUID()" }
            if (-not (Test-SettingValue $oh $s[10] "HearingRange")) { $why += "arg 11 is not HearingRange" }
            # The distance: args 8-10 are x, y and z of one Vector3 local d, and d = source's position - the local
            # player's position; args 5 and 6 are those two players.
            $srcLocal = $null; $meLocal = $null
            for ($k = 1; $k -lt $hins.Count; $k++) {
                if ($hins[$k].OpCode.Name -like "stloc*" -and (Test-Is $hins[$k - 1] "call" "Sharing" "FindLoadedPlayer")) { $srcLocal = Get-LocalIndex $hins[$k] }
                if ($hins[$k].OpCode.Name -like "stloc*" -and (Test-Is $hins[$k - 1] "ldsfld" "Player" "m_localPlayer")) { $meLocal = Get-LocalIndex $hins[$k] }
            }
            if ($null -eq $srcLocal -or $null -eq $meLocal) { $why += "the source and local players are not locals from FindLoadedPlayer and m_localPlayer" }
            else {
                if ((Get-LocalIndex $hins[$s[4]]) -ne $srcLocal -or $hins[$s[4]].OpCode.Name -notlike "ldloc*") { $why += "arg 5 is not the source player" }
                if ((Get-LocalIndex $hins[$s[5]]) -ne $meLocal -or $hins[$s[5]].OpCode.Name -notlike "ldloc*") { $why += "arg 6 is not the local player" }
            }
            $dLocal = $null; $axes = @("x", "y", "z")
            for ($j = 0; $j -lt 3; $j++) {
                $f = $hins[$s[7 + $j]]
                if (-not (Test-Is $f "ldfld" "Vector3" $axes[$j]) -or $hins[$s[7 + $j] - 1].OpCode.Name -notmatch '^ldloca?(\.s|\.[0-3])?$') { $why += "arg $(8 + $j) is not d.$($axes[$j])"; continue }
                $li = Get-LocalIndex $hins[$s[7 + $j] - 1]
                if ($null -eq $dLocal) { $dLocal = $li } elseif ($li -ne $dLocal) { $why += "the distance's axes come from different vectors" }
            }
            $subs = @(Find-Calls $oh "Vector3" "op_Subtraction")
            $subOk = $false
            if ($subs.Count -eq 1 -and $null -ne $dLocal -and $hins[$subs[0] + 1].OpCode.Name -like "stloc*" -and (Get-LocalIndex $hins[$subs[0] + 1]) -eq $dLocal) {
                $ss = Get-ArgumentSources $oh $subs[0]
                if ($ss -and (Test-Is $hins[$ss[0]] "call" "Transform" "get_position") -and (Test-Is $hins[$ss[1]] "call" "Transform" "get_position")) {
                    $owners = @()
                    foreach ($p in $ss) { $t1 = Get-ArgumentSources $oh $p; $t2 = if ($t1 -and (Test-Is $hins[$t1[0]] "call" "Component" "get_transform")) { Get-ArgumentSources $oh $t1[0] } else { $null }; $owners += $(if ($t2) { Get-LocalIndex $hins[$t2[0]] } else { -1 }) }
                    $subOk = $owners[0] -eq $srcLocal -and $owners[1] -eq $meLocal
                }
            }
            if (-not $subOk) { $why += "d is not source.transform.position - me.transform.position" }
        }
        $ds = Get-ArgumentSources $oh $d[0]
        if (-not $ds -or -not (Test-Is $hins[$ds[0]] "call" "ZPackage" "GetArray")) { $why += "TryDecode is not given the package's bytes" }
        $ra = Get-ArgumentSources $oh $a[0]
        $kindLocal = if ($ds) { Get-LocalIndex $hins[$ds[1]] } else { $null }
        if (-not $ra -or $null -eq $kindLocal -or $hins[$ds[1]].OpCode.Name -notlike "ldloca*" -or (Get-LocalIndex $hins[$ra[0]]) -ne $kindLocal) { $why += "OnRemote is not given the kind TryDecode read" }
    }
}
if ($why.Count -eq 0) { Ok "Sharing.OnAlert: TryDecode(the package's bytes) then MayHear(HearOthers, _inLocalSend, sender, GetUID(), ..., HearingRange) decides OnRemote(decoded kind)" }
else { Fail ("hearing is not decided as described: {0}" -f ($why -join "; ")) }
# Sharing.
$checks++
$ol = Get-PluginMethod "Alerts" "OnLocal"
$why = @()
if (-not $ol) { $why += "no Alerts.OnLocal" }
else {
    $oins = @($ol.Body.Instructions)
    $send = @(Find-Calls $ol "Sharing" "Send")
    $share = @(for ($k = 1; $k -lt $oins.Count; $k++) { if (Test-SettingValue $ol $k "ShareMyAlerts") { $k } })
    $tp = @(Find-Calls $ol "SendThrottle" "TryPass")
    if ($send.Count -ne 1 -or $share.Count -ne 1 -or $tp.Count -ne 1) { $why += "expected one ShareMyAlerts, one TryPass and one Send" }
    else {
        if (-not (Test-Decides $ol $share[0] $send[0])) { $why += "ShareMyAlerts does not decide Send" }
        if (-not (Test-Decides $ol $tp[0] $send[0])) { $why += "the throttle does not decide Send" }
        $s = Get-ArgumentSources $ol $tp[0]
        if (-not $s -or (Get-Literal $oins $s[3]) -ne 5) { $why += "the throttle's interval is not 5 s" }
    }
    $allSends = @(); foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if ($m.HasBody) { foreach ($x in (Find-Calls $m "Sharing" "Send")) { $allSends += (Get-Owner $m) } } } }
    if ($allSends.Count -ne 1) { $why += "Sharing.Send is called from $($allSends.Count) places" }
}
$gs = Get-PluginMethod "GameStartPatch" "Postfix"
if (-not $gs -or @(Find-Calls $gs "Sharing" "EnsureRegistered").Count -ne 1) { $why += "Game.Start does not register sharing" }
if ($why.Count -eq 0) { Ok "Alerts.OnLocal: ShareMyAlerts and a 5 s throttle decide Sharing.Send (its only caller); Game.Start registers sharing" }
else { Fail ("sharing is not decided as described: {0}" -f ($why -join "; ")) }
# The message: exactly the encoder's bytes, sent once to Everybody under the registered name; no ZPackage write.
$rpcName = "DoomMachine.NuclearTrollstav.Alert"
$checks++
$why = @()
$ss = Get-PluginMethod "Sharing" "Send"
$zpNew = @(); $zpWrite = @()
foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; $ins = @($m.Body.Instructions); for ($k = 0; $k -lt $ins.Count; $k++) {
    if ($ins[$k].OpCode.Name -eq "newobj" -and $ins[$k].Operand.DeclaringType.Name -eq "ZPackage") { $zpNew += ,@($m, $k) }
    if ((Test-Is $ins[$k] "call" "ZPackage" "Write") -or (Test-Is $ins[$k] "call" "ZPackage" "WriteSmallRotation")) { $zpWrite += (Get-Owner $m) } } } }
if ($zpWrite.Count -gt 0) { $why += "ZPackage.Write is called in " + (($zpWrite | Sort-Object -Unique) -join ", ") }
if ($zpNew.Count -ne 1 -or (Get-Owner $zpNew[0][0]) -ne "NuclearTrollstav.Sharing::Send") { $why += "expected exactly one new ZPackage, in Sharing.Send" }
elseif ($zpNew[0][0].Body.Instructions[$zpNew[0][1]].Operand.Parameters.Count -ne 1 -or $zpNew[0][0].Body.Instructions[$zpNew[0][1]].Operand.Parameters[0].ParameterType.FullName -ne "System.Byte[]") { $why += "the ZPackage is not made from a byte array" }
else {
    $sins = @($ss.Body.Instructions)
    $s = Get-ArgumentSources $ss $zpNew[0][1]
    if (-not $s -or -not (Test-Is $sins[$s[0]] "call" "AlertWire" "Encode")) { $why += "the ZPackage's bytes are not AlertWire.Encode's" }
    else {
        $e = Get-ArgumentSources $ss $s[0]
        if (-not $e -or (Get-ArgName $ss $sins[$e[0]]) -ne "kind" -or -not (Test-Is $sins[$e[1]] "call" "ZDOID" "get_UserID") -or -not (Test-Is $sins[$e[2]] "call" "ZDOID" "get_ID")) { $why += "Encode is not given (kind, the ZDOID's UserID, its ID)" }
        elseif (@(Find-Calls $ss "Character" "GetZDOID").Count -ne 1) { $why += "the ZDOID is not the character's (GetZDOID)" }
    }
}
$regs = @(); $invokes = @()
foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; foreach ($k in (Find-Calls $m "ZRoutedRpc" "Register")) { $regs += ,@($m, $k) }; foreach ($k in (Find-Calls $m "ZRoutedRpc" "InvokeRoutedRPC")) { $invokes += ,@($m, $k) } } }
if ($regs.Count -ne 1) { $why += "$($regs.Count) ZRoutedRpc.Register calls, expected 1" }
else {
    $rop = @($regs[0][0].Body.Instructions)[$regs[0][1]].Operand
    $rs = Get-ArgumentSources $regs[0][0] $regs[0][1]
    $rins = @($regs[0][0].Body.Instructions)
    if (-not ($rop -is [Mono.Cecil.GenericInstanceMethod]) -or $rop.GenericArguments.Count -ne 1 -or $rop.GenericArguments[0].FullName -ne "ZPackage") { $why += "Register is not Register<ZPackage>" }
    if (-not $rs -or $rins[$rs[1]].OpCode.Name -ne "ldstr" -or "$($rins[$rs[1]].Operand)" -cne $rpcName) { $why += "Register's name is not '$rpcName'" }
}
if ($invokes.Count -ne 1 -or (Get-Owner $invokes[0][0]) -ne "NuclearTrollstav.Sharing::Send") { $why += "expected one InvokeRoutedRPC, in Sharing.Send" }
else {
    $iop = @($invokes[0][0].Body.Instructions)[$invokes[0][1]].Operand
    $sig = @($iop.Parameters | ForEach-Object { $_.ParameterType.FullName }) -join ","
    $is = Get-ArgumentSources $invokes[0][0] $invokes[0][1]
    $iins = @($invokes[0][0].Body.Instructions)
    if ($sig -ne "System.Int64,System.String,System.Object[]") { $why += "InvokeRoutedRPC is not the (target, name, parameters) overload" }
    elseif (-not $is -or (Get-Literal $iins $is[1]) -ne 0 -or $iins[$is[2]].OpCode.Name -ne "ldstr" -or "$($iins[$is[2]].Operand)" -cne $rpcName) { $why += "InvokeRoutedRPC is not to Everybody (0) under '$rpcName'" }
}
if ($why.Count -eq 0) { Ok "the message is new ZPackage(AlertWire.Encode(kind, the character's ZDOID user and id)) - no ZPackage.Write, so no position - sent once to Everybody under the one registered name" }
else { Fail ("the shared message is not as described: {0}" -f ($why -join "; ")) }
# Scheduling.
$checks++
$why = @()
$at = Get-PluginMethod "Alerts" "Tick"
if (-not $at) { $why += "no Alerts.Tick" }
else {
    $tins = @($at.Body.Instructions)
    $st = @(Find-Calls $at "AlertScheduler" "Tick")
    if ($st.Count -ne 1) { $why += "expected one AlertScheduler.Tick" }
    else {
        $s = Get-ArgumentSources $at $st[0]
        if (-not $s) { $why += "AlertScheduler.Tick's arguments cannot be traced" }
        else {
            if ($null -eq (Get-LocalIndex $tins[$s[2]])) { $why += "'playing' is not a computed value" }
            if ((Get-Literal $tins $s[3]) -ne 1) { $why += "the gap is not 1 s" }
            if ((Get-Literal $tins $s[5]) -ne 30) { $why += "the wait limit is not 30 s" }
        }
    }
    if (@(Find-Calls $at "AudioSource" "get_isPlaying").Count -lt 1) { $why += "'playing' does not come from the audio source" }
}
$offers = @(); foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if ($m.HasBody) { foreach ($k in (Find-Calls $m "AlertScheduler" "Offer")) { $offers += ,@($m, $k) } } } }
if ($offers.Count -lt 2) { $why += "expected the local and the remote Offer" }
foreach ($o in $offers) {
    $s = Get-ArgumentSources $o[0] $o[1]
    if (-not $s -or -not (Test-Is @($o[0].Body.Instructions)[$s[3]] "call" "Alerts" "get_CooldownSeconds")) { $why += "an Offer in $(Get-Owner $o[0]) is not given Alerts.CooldownSeconds" }
}
$cs = Get-PluginMethod "Alerts" "get_CooldownSeconds"
if (-not $cs) { $why += "no Alerts.CooldownSeconds" }
else {
    $cins = @($cs.Body.Instructions); $c = @(Find-Calls $cs "AlertRules" "CooldownSeconds")
    $s = if ($c.Count -eq 1) { Get-ArgumentSources $cs $c[0] } else { $null }
    if (-not $s -or -not (Test-SettingValue $cs $s[0] "CooldownMinutes") -or $cins[$c[0] + 1].OpCode.Name -ne "ret") { $why += "Alerts.CooldownSeconds is not AlertRules.CooldownSeconds(CooldownMinutes)" }
}
if ($why.Count -eq 0) { Ok "the scheduler gets AlertRules' 1 s gap and 30 s wait, 'playing' from the audio source, and AlertRules.CooldownSeconds(CooldownMinutes) in every Offer" }
else { Fail ("scheduling is not wired as described: {0}" -f ($why -join "; ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== the plugin's other rules =="
$allRefs = @()   # @(method, index, operand) for every member an instruction touches
foreach ($t in (Get-AllTypes $plug)) {
    foreach ($m in $t.Methods) {
        if (-not $m.HasBody) { continue }
        $ins = @($m.Body.Instructions)
        for ($k = 0; $k -lt $ins.Count; $k++) { if ($ins[$k].Operand -is [Mono.Cecil.MemberReference]) { $allRefs += ,@($m, $k, $ins[$k].Operand) } }
    }
}
function Find-Refs([string]$typeFullName, [string]$memberPattern) {
    $r = @($allRefs | Where-Object { $_[2].DeclaringType -and $_[2].DeclaringType.FullName -eq $typeFullName -and $_[2].Name -cmatch $memberPattern })
    return ,$r
}
# Volume: every value given to AudioSource.volume is ClampVolume's, and every ClampVolume is of the Volume setting.
$checks++
$why = @()
$volSets = Find-Refs "UnityEngine.AudioSource" '^set_volume$'
foreach ($v in $volSets) {
    $s = Get-ArgumentSources $v[0] $v[1]
    if (-not $s -or -not (Test-Is @($v[0].Body.Instructions)[$s[1]] "call" "AlertRules" "ClampVolume")) { $why += "AudioSource.volume set without ClampVolume in $(Get-Owner $v[0])" }
}
$clamps = Find-Refs "NuclearTrollstav.AlertRules" '^ClampVolume$'
foreach ($c in $clamps) {
    $s = Get-ArgumentSources $c[0] $c[1]
    if (-not $s -or -not (Test-SettingValue $c[0] $s[0] "Volume")) { $why += "ClampVolume of something other than the Volume setting in $(Get-Owner $c[0])" }
}
if ($volSets.Count -lt 1) { $why += "no volume is set" }
if ($why.Count -eq 0) { Ok ("all {0} volumes set are ClampVolume (0..1) of the Volume setting ({1} ClampVolume calls)" -f $volSets.Count, $clamps.Count) }
else { Fail ($why -join "; ") }
# Routing.
$checks++
$why = @()
$route = Find-Refs "UnityEngine.AudioSource" '^set_outputAudioMixerGroup$'
if ($route.Count -ne 1 -or (Get-Owner $route[0][0]) -ne "NuclearTrollstav.Alerts::EnsureSource") { $why += "the mixer group is not assigned once, in Alerts.EnsureSource" }
else { $s = Get-ArgumentSources $route[0][0] $route[0][1]; if (-not $s -or -not (Test-Is @($route[0][0].Body.Instructions)[$s[1]] "ldsfld" "Alerts" "_gui")) { $why += "the group assigned is not Alerts._gui" } }
$fg = Get-PluginMethod "Alerts" "FindGuiGroup"
if (-not $fg) { $why += "no Alerts.FindGuiGroup" }
else {
    $eqs = @(Find-Calls $fg "String" "op_Equality")
    $fins = @($fg.Body.Instructions)
    $gui = @($eqs | Where-Object { $s = Get-ArgumentSources $fg $_; $s -and $fins[$s[1]].OpCode.Name -eq "ldstr" -and "$($fins[$s[1]].Operand)" -ceq "GUI" })
    if ($eqs.Count -lt 1 -or $gui.Count -ne $eqs.Count) { $why += "FindGuiGroup does not look the group up by the name GUI alone" }
    if ((Find-Refs "AudioMan" '^m_guiMixer$').Count -gt 0) { $why += "AudioMan.m_guiMixer is read (null in the game)" }
}
$as = Get-PluginMethod "Alerts" "Start"
$ro = Get-PluginMethod "Alerts" "Routed"
if (-not $as -or -not $ro) { $why += "no Alerts.Start or Alerts.Routed" }
else {
    $r = @(Find-Calls $as "Alerts" "Routed"); $p = @(Find-Calls $as "AudioSource" "Play")
    $sins = @($as.Body.Instructions)
    # "if (clip == null || !Routed(source)) { Cancel; return; }": Routed's true continues to Play, false to the cancel.
    $decides = $false
    if ($r.Count -eq 1 -and $p.Count -eq 1 -and $r[0] -lt $p[0]) {
        $br = $sins[$r[0] + 1]
        if ($br.OpCode.Name -like "brtrue*") { $decides = [array]::IndexOf($sins, $br.Operand) -le $p[0] -and @(for ($k = $r[0] + 2; $k -lt [array]::IndexOf($sins, $br.Operand); $k++) { if (Test-Is $sins[$k] "call" "AlertScheduler" "Cancel") { $k } }).Count -eq 1 }
        elseif ($br.OpCode.Name -like "brfalse*") { $decides = [array]::IndexOf($sins, $br.Operand) -gt $p[0] }
    }
    if (-not $decides) { $why += "Alerts.Start does not play only a routed source" }
    if (@(Find-Calls $ro "AudioSource" "get_outputAudioMixerGroup").Count -ne 1) { $why += "Alerts.Routed does not read the source's mixer group" }
}
$plays = Find-Refs "UnityEngine.AudioSource" '^Play$'
if ($plays.Count -ne 1) { $why += "AudioSource.Play is called $($plays.Count) times" }
if ($why.Count -eq 0) { Ok "the one audio source is routed to the group found by the name GUI (Alerts.EnsureSource), and Alerts.Start - the only Play - plays only a routed source" }
else { Fail ($why -join "; ") }
$checks++
$forbiddenAudio = @()
$forbiddenAudio += Find-Refs "UnityEngine.AudioSource" '^(PlayOneShot|PlayClipAtPoint|PlayDelayed|PlayScheduled|set_ignoreListenerVolume|set_ignoreListenerPause|set_mute)$'
$forbiddenAudio += Find-Refs "UnityEngine.AudioListener" '^set_'
$forbiddenAudio += Find-Refs "UnityEngine.Audio.AudioMixer" '^(SetFloat|ClearFloat|TransitionToSnapshots|set_)'
$forbiddenAudio += Find-Refs "UnityEngine.Audio.AudioMixerSnapshot" '.'
$forbiddenAudio += Find-Refs "AudioMan" '^(SetSFXVolume|m_guiMixer)$'
if ($forbiddenAudio.Count -eq 0) { Ok "no other way of playing, no listener, mixer or game volume change" }
else { Fail ("forbidden audio calls: {0}" -f (($forbiddenAudio | ForEach-Object { "{0} in {1}" -f $_[2].Name, (Get-Owner $_[0]) }) -join "; ")) }
# Writes nothing outside the game too: files, preferences, spawned objects, its own settings. (Game members: the
# reviewed list above.)
$checks++
$writes = @()
$writes += @($allRefs | Where-Object { $_[2].DeclaringType -and $_[2].DeclaringType.Name -match '^(PlayerPrefs|PlatformPrefs|ZPlayerPrefs)$' -and $_[2].Name -match '^(Set|Delete|Save)' })
$writes += @($allRefs | Where-Object { $_[2].DeclaringType -and $_[2].DeclaringType.Namespace -eq "System.IO" -and $_[2].DeclaringType.Name -match '^(File|Directory|FileInfo|DirectoryInfo|FileStream|StreamWriter|BinaryWriter)$' -and -not ($_[2].DeclaringType.Name -eq "File" -and $_[2].Name -eq "Exists") })
$writes += Find-Refs "UnityEngine.Object" '^(Instantiate|Destroy|DestroyImmediate)$'
$writes += @($allRefs | Where-Object { $_[2].DeclaringType -and $_[2].DeclaringType.Name -like "ConfigEntry*" -and $_[2].Name -eq "set_Value" })
$writes += @($allRefs | Where-Object { $_[2].DeclaringType -and $_[2].DeclaringType.Name -eq "ConfigFile" -and $_[2].Name -match '^(Save|Reload|Remove|Clear)' })
if ($writes.Count -eq 0) { Ok "writes no file, preference or setting, and instantiates or destroys no object (its own audio object is made with new GameObject; game members: the reviewed list)" }
else { Fail ("writes or spawns: {0}" -f (($writes | ForEach-Object { "{0}.{1} in {2}" -f $_[2].DeclaringType.Name, $_[2].Name, (Get-Owner $_[0]) } | Sort-Object -Unique) -join "; ")) }
# Nothing may throw into the game: every patch method that calls anything, the network handler, the send and Update.
$checks++
$why = @()
foreach ($pair in @(@("EquipItemPatch", "Prefix"), @("EquipItemPatch", "Postfix"), @("ProjectileAttackTriggeredPatch", "Postfix"), @("GameStartPatch", "Postfix"), @("Sharing", "OnAlert"), @("Sharing", "Send"), @("Plugin", "Update"), @("Plugin", "OnVolumeChanged"))) {
    $r = Test-CatchAll (Get-PluginMethod $pair[0] $pair[1])
    if ($r) { $why += "$($pair[0]).$($pair[1]): $r" }
}
if ($why.Count -eq 0) { Ok "the patch methods above, the network handler, the send, Update and the volume handler each catch every exception without rethrowing it" }
else { Fail ("may throw into the game: {0}" -f ($why -join "; ")) }
$checks++
$ug = @()
foreach ($pc in $patchClasses) { foreach ($m in $pc.Methods) {
    if (@("Prefix", "Postfix", "Finalizer", "Transpiler", "Prepare", "Cleanup", "TargetMethod", "TargetMethods") -notcontains $m.Name -or -not $m.HasBody) { continue }
    if (@($m.Body.Instructions | Where-Object { $_.OpCode.Name -match '^(call|callvirt|newobj)$' }).Count -eq 0) { continue }
    $r = Test-CatchAll $m; if ($r) { $ug += "$($pc.Name).$($m.Name): $r" } } }
if ($ug.Count -eq 0) { Ok "every patch method that makes a call catches every exception (the marks' Prefix/Finalizer only set a field)" }
else { Fail ("a patch method that makes a call may throw into the game: {0}" -f ($ug -join "; ")) }
# Game fields are only read, and nothing is reached by name (reflection, Traverse, AccessTools, SendMessage), so the
# reviewed list of game members is the whole of what the plugin can touch.
$checks++
$gw = @()
foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; foreach ($i in $m.Body.Instructions) {
    if ($i.OpCode.Name -match '^(stfld|stsfld|ldflda|ldsflda)$' -and $i.Operand -is [Mono.Cecil.FieldReference]) { $dt = $i.Operand.DeclaringType; while ($dt.IsNested) { $dt = $dt.DeclaringType }
        if ($dt.Scope.Name -eq "assembly_valheim" -or $dt.Scope.Name -eq "assembly_utils") { $gw += "{0} {1}::{2} in {3}" -f $i.OpCode.Name, $i.Operand.DeclaringType.Name, $i.Operand.Name, (Get-Owner $m) } } } } }
$refl = @($allRefs | Where-Object { $d = $_[2].DeclaringType; $n = $_[2].Name; $d -and (
    ($d.FullName -like "System.Reflection.*" -and $n -ne "get_Name") -or
    ($d.FullName -eq "System.Type" -and $n -match '^(GetMethod|GetMethods|GetField|GetFields|GetProperty|GetProperties|GetMember|GetMembers|InvokeMember|GetType)$') -or
    $d.FullName -eq "System.Activator" -or $d.FullName -like "HarmonyLib.Traverse*" -or $d.FullName -eq "HarmonyLib.AccessTools" -or
    ($d.FullName -match '^UnityEngine\.(Component|GameObject)$' -and $n -match '^(SendMessage|SendMessageUpwards|BroadcastMessage)$')) })
if ($gw.Count -eq 0 -and $refl.Count -eq 0) { Ok "game fields are only read, and no member is reached by name (reflection, Traverse, AccessTools, SendMessage)" }
else { Fail ("writes a game field or reaches members by name: {0}" -f ((@($gw) + @($refl | ForEach-Object { "{0}::{1} in {2}" -f $_[2].DeclaringType.Name, $_[2].Name, (Get-Owner $_[0]) } | Sort-Object -Unique)) -join "; ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== the decisions' inputs, traced further =="
function Get-StoreBefore($m, [int]$at) {
    # When instruction $at loads a local: the index of the last store to it before $at (-1 if none); else $at.
    $ins = @($m.Body.Instructions)
    if ($ins[$at].OpCode.Name -notlike "ldloc*") { return $at }
    $li = Get-LocalIndex $ins[$at]
    for ($k = $at - 1; $k -ge 0; $k--) { if ($ins[$k].OpCode.Name -like "stloc*" -and (Get-LocalIndex $ins[$k]) -eq $li) { return $k } }
    return -1
}
function Get-Indexes($m, [string]$kind, [string]$typeName, [string]$memberName) {
    $ins = @($m.Body.Instructions)
    for ($k = 0; $k -lt $ins.Count; $k++) { if (Test-Is $ins[$k] $kind $typeName $memberName) { $k } }
}
# The arm alert: Trollstav.Is of the item being equipped; the before-state set exactly twice (true, then InHand);
# the pickup mark's Finalizer exactly "if (Depth > 0) Depth--"; Trollstav.Is passes (prefab name, name token).
$checks++
$why = @()
$g = @(Find-Calls $ep "AlertRules" "ArmOnEquip")
if ($g.Count -eq 1) { $s = Get-ArgumentSources $ep $g[0]; $eins = @($ep.Body.Instructions); if ($s -and (Test-Is $eins[$s[7]] "call" "Trollstav" "Is")) { $w = Get-ArgumentSources $ep $s[7]; if (-not ($w -and (Get-ArgName $ep $eins[$w[0]]) -eq "item")) { $why += "Trollstav.Is is not of the item being equipped" } } }
$pr = @($epre.Body.Instructions)
$stI = @(for ($k = 1; $k -lt $pr.Count; $k++) { if ($pr[$k].OpCode.Name -eq "stind.i1") { $pr[$k - 1] } })
if (-not ($stI.Count -eq 2 -and $stI[0].OpCode.Name -eq "ldc.i4.1" -and (Test-Is $stI[1] "call" "AlertRules" "InHand"))) { $why += "__state is not set to true and then to InHand's result, and nothing else" }
if ((Get-Ops $pf) -ne "ldsfld PickupPatch::Depth; ldc.i4.0; ble.s; ldsfld PickupPatch::Depth; ldc.i4.1; sub; stsfld PickupPatch::Depth; ret") { $why += "PickupPatch.Finalizer is not exactly if (Depth > 0) Depth--" }
$c = @(Find-Calls $ti "AlertRules" "IsTrollstav"); $sh = @(Get-Indexes $ti "ldfld" "ItemData" "m_shared"); $nm = @(Get-Indexes $ti "ldfld" "SharedData" "m_name")
$isOk = $false
if ($c.Count -eq 1 -and $sh.Count -ge 1 -and $nm.Count -eq 1) { $s = Get-ArgumentSources $ti $c[0]; if ($s) { $a0 = Get-StoreBefore $ti $s[0]; $a1 = Get-StoreBefore $ti $s[1]; $isOk = $a0 -ge 0 -and $a0 -lt $sh[0] -and $a1 -gt $nm[0] } }
if (-not $isOk) { $why += "Trollstav.Is does not pass (prefab name, name token) in that order" }
if ($why.Count -eq 0) { Ok "arm alert: Trollstav.Is(item); __state = true, then InHand(...), nothing else; the pickup mark's Finalizer is exactly if (Depth > 0) Depth--; IsTrollstav(prefab name, name token)" }
else { Fail ("the arm alert's inputs: {0}" -f ($why -join "; ")) }
# The launch alert records the attack itself.
$checks++
$rec = @(Get-Indexes $ap "stsfld" "ProjectileAttackTriggeredPatch" "_last"); $recOk = $false
if ($rec.Count -eq 1) { $s = Get-ArgumentSources $ap $rec[0]; $recOk = $s -and (Get-ArgName $ap @($ap.Body.Instructions)[$s[0]]) -eq "__instance" }
if ($recOk) { Ok "launch alert: _last = __instance, the Postfix's only store to it" } else { Fail "the attack recorded in _last is not __instance" }
# Hearing: 'dead or not' is the local player's IsDead(); d is only Vector3.zero or the subtraction; the sender's
# character is matched on both its ZDOID's id and user.
$checks++
$why = @()
$meL = $null
for ($k = 1; $k -lt $hins.Count; $k++) { if ($hins[$k].OpCode.Name -like "stloc*" -and (Test-Is $hins[$k - 1] "ldsfld" "Player" "m_localPlayer")) { $meL = Get-LocalIndex $hins[$k] } }
$dead = @(Find-Calls $oh "Character" "IsDead"); $g = @(Find-Calls $oh "AlertRules" "MayHear"); $deadOk = $false
if ($dead.Count -eq 1 -and $g.Count -eq 1 -and $null -ne $meL) {
    $di = Get-ArgumentSources $oh $dead[0]; $s = Get-ArgumentSources $oh $g[0]
    if ($di -and $hins[$di[0]].OpCode.Name -like "ldloc*" -and (Get-LocalIndex $hins[$di[0]]) -eq $meL -and $s -and $hins[$s[6]].OpCode.Name -like "ldloc*") { $deadOk = (Get-StoreBefore $oh $s[6]) -gt $dead[0] }
}
if (-not $deadOk) { $why += "MayHear's arg 7 is not the local player's IsDead()" }
$sub = @(Find-Calls $oh "Vector3" "op_Subtraction"); $dOk = $false
if ($sub.Count -eq 1 -and $hins[$sub[0] + 1].OpCode.Name -like "stloc*") {
    $dl = Get-LocalIndex $hins[$sub[0] + 1]
    $stores = @(for ($k = 0; $k -lt $hins.Count; $k++) { if ($hins[$k].OpCode.Name -like "stloc*" -and (Get-LocalIndex $hins[$k]) -eq $dl) { $k } })
    $fw = @($hins | Where-Object { $_.OpCode.Name -eq "stfld" -and $_.Operand.DeclaringType.Name -eq "Vector3" })
    $io = @(for ($k = 1; $k -lt $hins.Count; $k++) { if ($hins[$k].OpCode.Name -eq "initobj" -and $hins[$k - 1].OpCode.Name -like "ldloca*" -and (Get-LocalIndex $hins[$k - 1]) -eq $dl) { $k } })
    $dOk = $stores.Count -eq 2 -and $fw.Count -eq 0 -and $io.Count -eq 0
}
if (-not $dOk) { $why += "the offset d is changed after the subtraction" }
$fl = Get-PluginMethod "Sharing" "FindLoadedPlayer"; $flOk = $false
if ($fl) {
    $fins = @($fl.Body.Instructions); $idc = @(Find-Calls $fl "ZDOID" "get_ID"); $uc = @(Find-Calls $fl "ZDOID" "get_UserID")
    $cmp = { param($at, $argName) ($at + 2 -lt $fins.Count) -and ((Get-ArgName $fl $fins[$at + 1]) -eq $argName) -and ($fins[$at + 2].OpCode.Name -match '^bne\.un(\.s)?$') }
    $flOk = $idc.Count -eq 1 -and $uc.Count -eq 1 -and (& $cmp $idc[0] "id") -and (& $cmp $uc[0] "user")
}
if (-not $flOk) { $why += "FindLoadedPlayer does not match both the ZDOID's id and user" }
if ($why.Count -eq 0) { Ok "hearing: 'dead' is the local player's IsDead(); d is only zero or source - me; the sender's character matches both id and user" }
else { Fail ("hearing's inputs: {0}" -f ($why -join "; ")) }
# Sharing: the one Encode, (AlertKind, long, uint); the handler registered is OnAlert; _inLocalSend is set once in Send
# and cleared in its finally; the throttle and the send get this alert's kind and the clock.
$checks++
$why = @()
$enc = @(Find-Calls $ss "AlertWire" "Encode")
if ($enc.Count -ne 1) { $why += "Send calls AlertWire.Encode $($enc.Count) times" }
else { $sig = @(@($ss.Body.Instructions)[$enc[0]].Operand.Parameters | ForEach-Object { $_.ParameterType.FullName }) -join ","; if ($sig -ne "NuclearTrollstav.AlertKind,System.Int64,System.UInt32") { $why += "Send uses Encode($sig)" } }
$encDefs = @(); foreach ($t in (Get-AllTypes $plug)) { if ($t.Name -eq "AlertWire") { $encDefs += @($t.Methods | Where-Object { $_.Name -eq "Encode" }) } }
if ($encDefs.Count -ne 1) { $why += "AlertWire declares $($encDefs.Count) Encode methods" }
$hOk = $false
if ($regs.Count -eq 1) { $rs = Get-ArgumentSources $regs[0][0] $regs[0][1]; $rinsR = @($regs[0][0].Body.Instructions)
    $cc = Get-PluginMethod "Sharing" ".cctor"
    if ($rs -and (Test-Is $rinsR[$rs[2]] "ldsfld" "Sharing" "Handler") -and $cc) { $ci = @($cc.Body.Instructions); $hst = @(Get-Indexes $cc "stsfld" "Sharing" "Handler")
        if ($hst.Count -eq 1) { $hs = Get-ArgumentSources $cc $hst[0]; $hOk = $hs -and $ci[$hs[0]].OpCode.Name -eq "newobj" -and $hs[0] -ge 1 -and $ci[$hs[0] - 1].OpCode.Name -eq "ldftn" -and $ci[$hs[0] - 1].Operand.Name -eq "OnAlert" -and $ci[$hs[0] - 1].Operand.DeclaringType.Name -eq "Sharing" } } }
if (-not $hOk) { $why += "the handler registered is not Sharing.OnAlert" }
$stores = @(); foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; $mi = @($m.Body.Instructions); for ($k = 1; $k -lt $mi.Count; $k++) { if (Test-Is $mi[$k] "stsfld" "Sharing" "_inLocalSend") { $stores += ,@($m, $k, $mi[$k - 1].OpCode.Name) } } } }
$fin = @($ss.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Finally" }); $sn = @($ss.Body.Instructions)
$clear = @($stores | Where-Object { (Get-Owner $_[0]) -eq "NuclearTrollstav.Sharing::Send" -and $_[2] -eq "ldc.i4.0" -and $fin.Count -eq 1 -and $_[1] -ge [array]::IndexOf($sn, $fin[0].HandlerStart) -and ($null -eq $fin[0].HandlerEnd -or $_[1] -lt [array]::IndexOf($sn, $fin[0].HandlerEnd)) })
if (-not ($stores.Count -eq 2 -and $clear.Count -eq 1 -and @($stores | Where-Object { $_[2] -eq "ldc.i4.1" }).Count -eq 1)) { $why += "_inLocalSend is not set once in Send and cleared in its finally" }
$oins = @($ol.Body.Instructions); $tp = @(Find-Calls $ol "SendThrottle" "TryPass"); $sd = @(Find-Calls $ol "Sharing" "Send"); $kOk = $false
if ($tp.Count -eq 1 -and $sd.Count -eq 1) { $s = Get-ArgumentSources $ol $tp[0]; $s2 = Get-ArgumentSources $ol $sd[0]
    if ($s -and $s2) { $st = Get-StoreBefore $ol $s[2]; $kOk = (Get-ArgName $ol $oins[$s[1]]) -eq "kind" -and $st -ge 1 -and $st -ne $s[2] -and (Test-Is $oins[$st - 1] "call" "Alerts" "get_Now") -and (Get-ArgName $ol $oins[$s2[0]]) -eq "kind" } }
if (-not $kOk) { $why += "the throttle or the send is not given this alert's kind and the clock" }
if ($why.Count -eq 0) { Ok "sharing: the one Encode(AlertKind, long, uint); Register's handler is OnAlert; _inLocalSend set in Send and cleared in its finally; TryPass(kind, now, 5) and Send(kind)" }
else { Fail ("sharing's inputs: {0}" -f ($why -join "; ")) }
# Settings: each key feeds the field of its own name.
$checks++
$fieldOf = @{ "Sound.Volume" = "Volume"; "Sound.ArmSound" = "ArmSoundFile"; "Sound.LaunchSound" = "LaunchSoundFile"; "Alerts.CooldownMinutes" = "CooldownMinutes"; "Multiplayer.ShareMyAlerts" = "ShareMyAlerts"; "Multiplayer.HearOthers" = "HearOthers"; "Multiplayer.HearingRange" = "HearingRange" }
$bad9 = @(); $ainsN = @($awake.Body.Instructions); $bound = 0
for ($k = 0; $k -lt $ainsN.Count; $k++) { $op = $ainsN[$k].Operand
    if (($ainsN[$k].OpCode.Name -eq "callvirt" -or $ainsN[$k].OpCode.Name -eq "call") -and $op.Name -eq "Bind" -and $op.DeclaringType.Name -eq "ConfigFile") {
        $bound++
        $src = Get-ArgumentSources $awake $k
        $key = if ($src) { "{0}.{1}" -f $ainsN[$src[1]].Operand, $ainsN[$src[2]].Operand } else { "?" }
        $st = $ainsN[$k + 1]; $fld = if ($st.OpCode.Name -eq "stsfld" -and $st.Operand.DeclaringType.Name -eq "Plugin") { $st.Operand.Name } else { "?" }
        if ($fieldOf[$key] -ne $fld) { $bad9 += "$key goes into $fld" } } }
if ($bad9.Count -eq 0 -and $bound -eq $fieldOf.Count) { Ok "each setting's key feeds the field of its own name" } else { Fail ("settings cross-wired: " + ($bad9 -join "; ")) }
# Patching: Awake makes the Harmony instance, then calls ApplyPatches with no condition; the loop starts at the first class.
$checks++
$why = @()
$a10 = @(Find-Calls $awake "Plugin" "ApplyPatches")
if ($a10.Count -eq 1) {
    $hs = @(for ($k = 1; $k -lt $ainsN.Count; $k++) { if ($ainsN[$k].OpCode.Name -eq "stfld" -and $ainsN[$k].Operand.Name -eq "_harmony" -and $ainsN[$k - 1].OpCode.Name -eq "newobj" -and $ainsN[$k - 1].Operand.DeclaringType.Name -eq "Harmony") { $k } })
    $over = @(for ($k = 0; $k -lt $a10[0]; $k++) { if ("$($ainsN[$k].OpCode.FlowControl)" -eq "Cond_Branch" -and $ainsN[$k].Operand -is [Mono.Cecil.Cil.Instruction] -and [array]::IndexOf($ainsN, $ainsN[$k].Operand) -gt $a10[0]) { $k } })
    if (-not ($hs.Count -eq 1 -and $hs[0] -lt $a10[0] -and $over.Count -eq 0)) { $why += "ApplyPatches runs before the Harmony instance exists, or under a condition" }
} else { $why += "Awake calls ApplyPatches $($a10.Count) times" }
$apl = @($apply.Body.Instructions); $loopOk = $false
$le = @(for ($k = 1; $k -lt $apl.Count; $k++) { if ($apl[$k].OpCode.Name -eq "ldelem.ref") { $k } })
if ($le.Count -eq 1 -and $apl[$le[0] - 1].OpCode.Name -like "ldloc*") {
    $I = Get-LocalIndex $apl[$le[0] - 1]
    $st = @(for ($k = 2; $k -lt $apl.Count; $k++) { if ($apl[$k].OpCode.Name -like "stloc*" -and (Get-LocalIndex $apl[$k]) -eq $I) { "{0}/{1}" -f $apl[$k - 1].OpCode.Name, $apl[$k - 2].OpCode.Name } })
    $loopOk = $st.Count -eq 2 -and $st[0] -like "ldc.i4.0/*" -and $st[1] -eq "add/ldc.i4.1"
}
if (-not $loopOk) { $why += "ApplyPatches' loop does not start at the first class and step by one" }
if ($why.Count -eq 0) { Ok "patching: Awake sets _harmony = new Harmony, then calls ApplyPatches with no condition; its loop covers every class from the first" }
else { Fail ("patching: {0}" -f ($why -join "; ")) }
# Audio: Routed returns group != null; Start returns right after the refusal's Cancel; FindGuiGroup compares names
# only with == and branches away when not equal.
$checks++
$why = @()
$rinsN = @($ro.Body.Instructions); $gi = @(Find-Calls $ro "AudioSource" "get_outputAudioMixerGroup")
if (-not ($gi.Count -eq 1 -and $rinsN[$gi[0] + 1].OpCode.Name -eq "ldnull" -and (Test-Is $rinsN[$gi[0] + 2] "call" "Object" "op_Inequality") -and $rinsN[$gi[0] + 3].OpCode.Name -eq "ret" -and @(Find-Calls $ro "Object" "op_Equality").Count -eq 0)) { $why += "Routed does not return source.outputAudioMixerGroup != null" }
$sinsN = @($as.Body.Instructions); $pl = @(Find-Calls $as "AudioSource" "Play"); $cn = @(Find-Calls $as "AlertScheduler" "Cancel" | Where-Object { $pl.Count -eq 1 -and $_ -lt $pl[0] })
if (-not ($cn.Count -eq 1 -and $sinsN[$cn[0] + 1].OpCode.Name -match '^(ret|leave|leave\.s)$')) { $why += "Start does not return right after the refusal's Cancel" }
$fgi = @($fg.Body.Instructions)
$otherStr = @($fgi | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -eq "System.String" -and $_.Operand.Name -ne "op_Equality" })
$eqs = @(Find-Calls $fg "String" "op_Equality"); $notBf = @($eqs | Where-Object { $fgi[$_ + 1].OpCode.Name -notmatch '^brfalse(\.s)?$' })
if (-not ($otherStr.Count -eq 0 -and $eqs.Count -ge 1 -and $notBf.Count -eq 0)) { $why += "FindGuiGroup compares names another way: " + ((@($otherStr | ForEach-Object { $_.Operand.Name }) + @($notBf | ForEach-Object { "op_Equality then " + $fgi[$_ + 1].OpCode.Name })) -join ", ") }
if ($why.Count -eq 0) { Ok "audio: Routed returns group != null; Start returns right after refusing; FindGuiGroup takes a group only when its name == GUI" }
else { Fail ("audio routing: {0}" -f ($why -join "; ")) }
# Can it be heard now: Alerts.Audible returns AlertRules.Audible of the live inputs; CanPlay is Audible(its clip is
# loaded), CanPlayAny is Audible(true); ListenerAlive is exactly "the local player exists and is not dead"; the local and
# the remote alert are offered only when CanPlay says so; Tick's canStart comes from CanPlayAny.
$checks++
$why = @()
$au = Get-PluginMethod "Alerts" "Audible"
if (-not $au) { $why += "no Alerts.Audible" }
else {
    $uins = @($au.Body.Instructions); $c = @(Find-Calls $au "AlertRules" "Audible")
    if ($c.Count -ne 1 -or $uins[$c[0] + 1].OpCode.Name -ne "ret") { $why += "Alerts.Audible does not return AlertRules.Audible's result" }
    else {
        $s = Get-ArgumentSources $au $c[0]
        function Test-NotNull($at, [string]$kind, [string]$tn, [string]$mn) { $x = Get-ArgumentSources $au $at; return (Test-Is $uins[$at] "call" "Object" "op_Inequality") -and $x -and (Test-Is $uins[$x[0]] $kind $tn $mn) -and $uins[$x[1]].OpCode.Name -eq "ldnull" }
        if (-not $s) { $why += "AlertRules.Audible's arguments cannot be traced" }
        else {
            if ((Get-ArgName $au $uins[$s[0]]) -ne "clipLoaded") { $why += "arg 1 is not clipLoaded" }
            if (-not (Test-NotNull $s[1] "call" "ZNet" "get_instance")) { $why += "arg 2 is not ZNet.instance != null" }
            if (-not (Test-Is $uins[$s[2]] "call" "Alerts" "ListenerAlive")) { $why += "arg 3 is not ListenerAlive()" }
            if (-not (Test-NotNull $s[3] "call" "Alerts" "EnsureSource")) { $why += "arg 4 is not EnsureSource() != null" }
            if (-not (Test-Is $uins[$s[4]] "call" "AlertRules" "ClampVolume")) { $why += "arg 5 is not ClampVolume(Volume)" }
            if (-not (Test-Is $uins[$s[5]] "call" "CinematicsManager" "IsStartedPlaying")) { $why += "arg 6 is not CinematicsManager.IsStartedPlaying()" }
            if (-not (Test-Is $uins[$s[6]] "call" "AudioListener" "get_volume")) { $why += "arg 7 is not AudioListener.volume" }
            if (-not (Test-NotNull $s[7] "call" "AudioMan" "get_instance")) { $why += "arg 8 is not AudioMan.instance != null" }
            if (-not (Test-Is $uins[$s[8]] "call" "AudioMan" "GetSFXVolume")) { $why += "arg 9 is not AudioMan.GetSFXVolume()" }
        }
    }
}
$cp = Get-PluginMethod "Alerts" "CanPlay"; $cpa = Get-PluginMethod "Alerts" "CanPlayAny"; $la = Get-PluginMethod "Alerts" "ListenerAlive"
if (-not $cp -or (Get-Ops $cp) -ne "ldsfld Alerts::Clips; ldarg.0; ldelem.ref; ldnull; call; call; ret" -or @(Find-Calls $cp "Alerts" "Audible").Count -ne 1) { $why += "CanPlay is not Audible(Clips[kind] != null)" }
if (-not $cpa -or (Get-Ops $cpa) -ne "ldc.i4.1; call; ret" -or @(Find-Calls $cpa "Alerts" "Audible").Count -ne 1) { $why += "CanPlayAny is not Audible(true)" }
if (-not $la -or (Get-Ops $la) -ne "ldsfld Player::m_localPlayer; stloc.0; ldloc.0; ldnull; call; brfalse.s; ldc.i4.0; ret; ldloc.0; callvirt; ldc.i4.0; ceq; ret" -or @(Find-Calls $la "Object" "op_Equality").Count -ne 1 -or @(Find-Calls $la "Character" "IsDead").Count -ne 1) { $why += "ListenerAlive is not exactly m_localPlayer != null && !IsDead()" }
foreach ($pair in @(@($ol, "OnLocal"), @((Get-PluginMethod "Alerts" "OnRemote"), "OnRemote"))) {
    $m = $pair[0]
    if (-not $m) { $why += "no Alerts.$($pair[1])"; continue }
    $cps = @(Find-Calls $m "Alerts" "CanPlay"); $ofs = @(Find-Calls $m "AlertScheduler" "Offer")
    if ($cps.Count -ne 1 -or $ofs.Count -ne 1 -or -not (Test-Decides $m $cps[0] $ofs[0])) { $why += "$($pair[1]): CanPlay does not decide the Offer" }
    else { $s = Get-ArgumentSources $m $cps[0]; if (-not $s -or (Get-ArgName $m @($m.Body.Instructions)[$s[0]]) -ne "kind") { $why += "$($pair[1]): CanPlay is not of this alert's kind" } }
}
$stT = @(Find-Calls $at "AlertScheduler" "Tick"); $cpT = @(Find-Calls $at "Alerts" "CanPlayAny"); $csOk = $false
if ($stT.Count -eq 1 -and $cpT.Count -ge 1) { $s = Get-ArgumentSources $at $stT[0]; if ($s -and @($at.Body.Instructions)[$s[4]].OpCode.Name -like "ldloc*") { $csOk = (Get-StoreBefore $at $s[4]) -gt $cpT[0] } }
if (-not $csOk) { $why += "the scheduler's canStart does not come from CanPlayAny" }
if ($why.Count -eq 0) { Ok "audibility: AlertRules.Audible(clip loaded, ZNet.instance, ListenerAlive, EnsureSource, ClampVolume(Volume), cinematic, listener volume, AudioMan, its effect volume) decides every Offer and the scheduler's canStart" }
else { Fail ("audibility is not decided as described: {0}" -f ($why -join "; ")) }
# Waiting alerts: dropped on leaving the world and at death; the clock is real time (it runs through the pause).
$checks++
$why = @()
if (@(Find-Calls $at "AlertScheduler" "DropWaiting").Count -ne 2) { $why += "Alerts.Tick does not call DropWaiting twice (leaving the world, death)" }
$nowM = Get-PluginMethod "Alerts" "get_Now"; $nowI = if ($nowM) { @($nowM.Body.Instructions) } else { @() }
$rt = if ($nowM) { @(Find-Calls $nowM "Time" "get_realtimeSinceStartupAsDouble") } else { @() }
if (-not ($rt.Count -eq 1 -and $nowI[$rt[0] + 1].OpCode.Name -eq "ret")) { $why += "Alerts.Now is not Time.realtimeSinceStartupAsDouble" }
if ($why.Count -eq 0) { Ok "waiting alerts are dropped on leaving the world and at death; the clock is Time.realtimeSinceStartupAsDouble" }
else { Fail ($why -join "; ") }
# The log: another player's refused alerts go through a throttle (kind, now, 10 s) that decides the line.
$checks++
$lr = Get-PluginMethod "Alerts" "LogRemoteRefusal"; $lrOk = $false
if ($lr) {
    $lins2 = @($lr.Body.Instructions); $tp = @(Find-Calls $lr "SendThrottle" "TryPass"); $li = @(Find-Calls $lr "ManualLogSource" "LogInfo")
    if ($tp.Count -eq 1 -and $li.Count -eq 1 -and (Test-Decides $lr $tp[0] $li[0])) {
        $s = Get-ArgumentSources $lr $tp[0]
        $lrOk = $s -and (Test-Is $lins2[$s[0]] "ldsfld" "Alerts" "RefusalLog") -and (Get-ArgName $lr $lins2[$s[1]]) -eq "kind" -and (Get-ArgName $lr $lins2[$s[2]]) -eq "now" -and (Get-Literal $lins2 $s[3]) -eq 10
    }
}
$orm = Get-PluginMethod "Alerts" "OnRemote"
$direct = if ($orm) { @(Find-Calls $orm "ManualLogSource" "LogInfo").Count } else { 1 }
if ($lrOk -and $direct -eq 0) { Ok "another player's refused alerts are logged only through RefusalLog.TryPass(kind, now, 10 s)" }
else { Fail "another player's refused alerts are not logged only through the 10 s throttle" }
# A volume changed in game applies at once: Awake subscribes OnVolumeChanged to Volume.SettingChanged, and it applies it.
$checks++
$vOk = $false
$sub2 = @(Find-Calls $awake "ConfigEntry``1" "add_SettingChanged")
if ($sub2.Count -eq 1) {
    $s = Get-ArgumentSources $awake $sub2[0]
    $vOk = $s -and (Test-Is $ainsN[$s[0]] "ldsfld" "Plugin" "Volume") -and @($ainsN | Where-Object { $_.OpCode.Name -eq "ldftn" -and $_.Operand.Name -eq "OnVolumeChanged" -and $_.Operand.DeclaringType.Name -eq "Plugin" }).Count -eq 1
}
$ovc = Get-PluginMethod "Plugin" "OnVolumeChanged"
if ($vOk -and $ovc -and @(Find-Calls $ovc "Alerts" "ApplyVolume").Count -eq 1) { Ok "Volume.SettingChanged is handled by OnVolumeChanged, which applies the volume" }
else { Fail "a volume changed in game is not applied at once (Volume.SettingChanged -> OnVolumeChanged -> ApplyVolume)" }
# ---------------------------------------------------------------------------------------------------------------
# Each of these was proven on a planted defect when it was added: the scheduler's clock and kinds, the direction
# of the start gate and the drops, the log throttle's inputs, the volume handler, calls by name, Awake's early return,
# the send flag's order, the "playing now" line, and the message's parameter array.
Write-Output "== scheduling, logging and sending, traced further =="
function Test-NowLocal($m, [int]$at) {
    # Instruction $at loads a local whose last store before it takes Alerts.Now's result.
    $ins = @($m.Body.Instructions)
    if ($at -lt 0 -or $ins[$at].OpCode.Name -notlike "ldloc*") { return $false }
    $st = Get-StoreBefore $m $at
    return $st -ge 1 -and (Test-Is $ins[$st - 1] "call" "Alerts" "get_Now")
}
function Test-Window($ins, [int]$from, [string[]]$ops) {
    if ($from -lt 0 -or $from + $ops.Count -gt $ins.Count) { return $false }
    for ($j = 0; $j -lt $ops.Count; $j++) { if ($ins[$from + $j].OpCode.Name -notmatch ('^' + $ops[$j] + '$')) { return $false } }
    return $true
}
$tiR = @($at.Body.Instructions); $tkR = @(Find-Calls $at "AlertScheduler" "Tick"); $dwR = @(Find-Calls $at "AlertScheduler" "DropWaiting")
$checks++
$why = @()
if (-not ($cp -and @(Find-Calls $cp "Object" "op_Inequality").Count -eq 1 -and @(Find-Calls $cp "Object" "op_Equality").Count -eq 0)) { $why += "CanPlay does not pass Clips[kind] != null" }
foreach ($o in $offers) { $s = Get-ArgumentSources $o[0] $o[1]; $oi = @($o[0].Body.Instructions)
    if (-not $s -or (Get-ArgName $o[0] $oi[$s[1]]) -ne "kind" -or -not (Test-NowLocal $o[0] $s[2])) { $why += "the Offer in $(Get-Owner $o[0]) is not given (kind, now)" } }
if ($tkR.Count -ne 1) { $why += "AlertScheduler.Tick is called $($tkR.Count) times" } else { $s = Get-ArgumentSources $at $tkR[0]; if (-not $s -or -not (Test-NowLocal $at $s[1])) { $why += "AlertScheduler.Tick is not given now" } }
$r3 = $false
if ($tkR.Count -eq 1) { $s = Get-ArgumentSources $at $tkR[0]
    if ($s -and $tiR[$s[4]].OpCode.Name -like "ldloc*") { $k = Get-StoreBefore $at $s[4]
        if ($k -ge 6) { $w = @($tiR[($k - 6)..$k])
            $r3 = (Test-Is $w[0] "call" "AlertScheduler" "get_WaitingCount") -and (Test-Window $w 1 @("ldc\.i4\.0", "ble(\.s)?")) -and $w[2].Operand -eq $w[5] -and (Test-Is $w[3] "call" "Alerts" "CanPlayAny") -and (Test-Window $w 4 @("br(\.s)?", "ldc\.i4\.0", "stloc.*")) -and $w[4].Operand -eq $w[6] } } }
if (-not $r3) { $why += "canStart is not exactly WaitingCount > 0 && CanPlayAny()" }
$r4 = $dwR.Count -eq 2 -and $dwR[1] -ge 3 -and (Test-Is $tiR[$dwR[1] - 3] "call" "Alerts" "ListenerAlive") -and (Test-Window $tiR ($dwR[1] - 2) @("brtrue(\.s)?", "ldsfld")) -and [array]::IndexOf($tiR, $tiR[$dwR[1] - 2].Operand) -eq $dwR[1] + 1
if (-not $r4) { $why += "the death drop is not skipped exactly when ListenerAlive() is true" }
$d1 = if ($dwR.Count -ge 1) { $dwR[0] } else { -1 }
$r5 = $d1 -ge 9 -and (Test-Is $tiR[$d1 - 9] "call" "ZNet" "get_instance") -and $tiR[$d1 - 8].OpCode.Name -eq "ldnull" -and (Test-Is $tiR[$d1 - 7] "call" "Object" "op_Equality") -and (Test-Window $tiR ($d1 - 6) @("brfalse(\.s)?")) -and [array]::IndexOf($tiR, $tiR[$d1 - 6].Operand) -gt $d1 -and (Test-Is $tiR[$d1 - 5] "ldsfld" "Alerts" "_inWorld") -and (Test-Window $tiR ($d1 - 4) @("brfalse(\.s)?")) -and [array]::IndexOf($tiR, $tiR[$d1 - 4].Operand) -gt $d1
if (-not $r5) { $why += "the leave drop is not guarded by ZNet.instance == null and _inWorld, the right way round" }
if ($why.Count -eq 0) { Ok "scheduling: CanPlay tests Clips[kind] != null; every Offer gets (kind, now) and Tick gets now (= Alerts.Now); canStart = WaitingCount > 0 && CanPlayAny(); the death drop runs only when ListenerAlive() is false, the leave drop only when ZNet.instance == null after being in a world" }
else { Fail ("scheduling's inputs: {0}" -f ($why -join "; ")) }
$checks++
$why = @()
foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; $mi = @($m.Body.Instructions)
    foreach ($k in (Find-Calls $m "Alerts" "LogRemoteRefusal")) { $s = Get-ArgumentSources $m $k; if (-not $s -or (Get-ArgName $m $mi[$s[0]]) -ne "kind" -or -not (Test-NowLocal $m $s[1])) { $why += "LogRemoteRefusal in $(Get-Owner $m) is not given (kind, now)" } } } }
$dl = @(); if ($orm) { $dl = @($orm.Body.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MemberReference] -and $_.Operand.DeclaringType -and ($_.Operand.DeclaringType.Name -eq "ManualLogSource" -or $_.Operand.DeclaringType.FullName -eq "UnityEngine.Debug" -or $_.Operand.Name -eq "LogThrottled") }) }
if (-not $orm -or $dl.Count -gt 0) { $why += "OnRemote logs directly: " + (($dl | ForEach-Object { $_.Operand.Name }) -join ", ") }
$tpR = @(Find-Calls $ol "SendThrottle" "TryPass"); $r8 = $false
if ($tpR.Count -eq 1) { $s = Get-ArgumentSources $ol $tpR[0]; $r8 = $s -and (Test-Is @($ol.Body.Instructions)[$s[0]] "ldsfld" "Alerts" "Throttle") }
if (-not $r8) { $why += "the send's throttle is not Alerts.Throttle" }
if ($why.Count -eq 0) { Ok "logging: every LogRemoteRefusal gets (kind, now), OnRemote writes no log line itself, and the send has its own throttle (Alerts.Throttle)" }
else { Fail ("logging and throttles: {0}" -f ($why -join "; ")) }
$checks++
$why = @()
if ($ovc) { $vi = @($ovc.Body.Instructions); $vh = @($ovc.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Catch" }); $vt = if ($vh.Count -eq 1) { [array]::IndexOf($vi, $vh[0].TryStart) } else { -1 }
    if (-not ($vt -ge 0 -and (Test-Is $vi[$vt] "call" "Alerts" "ApplyVolume") -and (Test-Window $vi ($vt + 1) @("leave(\.s)?")))) { $why += "OnVolumeChanged's try is not exactly Alerts.ApplyVolume()" } } else { $why += "no OnVolumeChanged" }
$avm = Get-PluginMethod "Alerts" "ApplyVolume"
if (-not $avm -or (Get-Ops $avm) -ne "ldsfld Alerts::_source; ldnull; call; brfalse.s; ldsfld Alerts::_source; ldsfld Plugin::Volume; callvirt; call; callvirt; ret" -or @(Find-Calls $avm "Object" "op_Inequality").Count -ne 1 -or @(Find-Calls $avm "AudioSource" "set_volume").Count -ne 1) { $why += "ApplyVolume is not exactly if (_source != null) _source.volume = ClampVolume(Volume)" }
if ($why.Count -eq 0) { Ok "the volume handler runs ApplyVolume unconditionally, and ApplyVolume sets the playing source's volume" } else { Fail ("the volume handler: {0}" -f ($why -join "; ")) }
$checks++
$bn = @($allRefs | Where-Object { $d = $_[2].DeclaringType; $n = $_[2].Name; $_[2] -is [Mono.Cecil.MethodReference] -and $d -and (@($_[2].Parameters | Where-Object { $_.ParameterType.FullName -eq "System.String" }).Count -gt 0) -and (
    ($d.FullName -eq "System.Delegate" -and $n -eq "CreateDelegate") -or
    ($d.FullName -eq "UnityEngine.MonoBehaviour" -and $n -match '^(Invoke|InvokeRepeating|CancelInvoke|IsInvoking|StartCoroutine|StopCoroutine)$')) })
if ($bn.Count -eq 0) { Ok "no Delegate.CreateDelegate or MonoBehaviour call by method name" } else { Fail ("reaches a member by name: " + (($bn | ForEach-Object { "{0}::{1} in {2}" -f $_[2].DeclaringType.Name, $_[2].Name, (Get-Owner $_[0]) } | Sort-Object -Unique) -join "; ")) }
$checks++
$awI = @($awake.Body.Instructions); $apR = @(Find-Calls $awake "Plugin" "ApplyPatches"); $bad11 = @()
$catchR = @($awake.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Catch" } | ForEach-Object { ,@([array]::IndexOf($awI, $_.HandlerStart), $(if ($_.HandlerEnd) { [array]::IndexOf($awI, $_.HandlerEnd) } else { $awI.Count })) })
if ($apR.Count -eq 1) { for ($k = 0; $k -lt $apR[0]; $k++) { if ($awI[$k].OpCode.Name -ne "ret") { continue }
        $prev = if ($k -gt 0) { "$($awI[$k - 1].OpCode.FlowControl)" } else { "Next" }
        $from = @(for ($j = 0; $j -lt $awI.Count; $j++) { if ($awI[$j].Operand -eq $awI[$k]) { $j } })
        $okFrom = $from.Count -ge 1 -and @($from | Where-Object { $jj = $_; $awI[$jj].OpCode.Name -notmatch '^leave(\.s)?$' -or @($catchR | Where-Object { $jj -ge $_[0] -and $jj -lt $_[1] }).Count -eq 0 }).Count -eq 0
        if (-not ($prev -match '^(Branch|Return|Throw)$' -and $okFrom)) { $bad11 += "IL_{0:x4}" -f $awI[$k].Offset } } } else { $bad11 += "ApplyPatches calls: $($apR.Count)" }
if ($bad11.Count -eq 0) { Ok "Awake returns before ApplyPatches only out of the configuration's catch" } else { Fail ("Awake can return before ApplyPatches: " + ($bad11 -join ", ")) }
$checks++
$why = @()
$snI = @($ss.Body.Instructions); $setR = @(for ($k = 1; $k -lt $snI.Count; $k++) { if ((Test-Is $snI[$k] "stsfld" "Sharing" "_inLocalSend") -and $snI[$k - 1].OpCode.Name -eq "ldc.i4.1") { $k } }); $invR = @(Find-Calls $ss "ZRoutedRpc" "InvokeRoutedRPC")
$finR = @($ss.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Finally" })
if (-not ($setR.Count -eq 1 -and $invR.Count -eq 1 -and $finR.Count -eq 1 -and $setR[0] -lt $invR[0] -and $setR[0] -ge [array]::IndexOf($snI, $finR[0].TryStart))) { $why += "_inLocalSend is not set before InvokeRoutedRPC, inside the try its finally clears" }
# The parameters array: exactly { the ZPackage made from Encode's bytes } - nothing else rides along.
$arrOk = $false
if ($invR.Count -eq 1 -and $zpNew.Count -eq 1 -and $snI[$zpNew[0][1] + 1].OpCode.Name -like "stloc*") {
    $pkL = Get-LocalIndex $snI[$zpNew[0][1] + 1]; $e = $invR[0] - 1
    $arrOk = $e -ge 5 -and $snI[$e].OpCode.Name -eq "stelem.ref" -and $snI[$e - 1].OpCode.Name -like "ldloc*" -and (Get-LocalIndex $snI[$e - 1]) -eq $pkL -and
        $snI[$e - 2].OpCode.Name -eq "ldc.i4.0" -and $snI[$e - 3].OpCode.Name -eq "dup" -and $snI[$e - 4].OpCode.Name -eq "newarr" -and $snI[$e - 5].OpCode.Name -eq "ldc.i4.1" -and
        @($snI | Where-Object { $_.OpCode.Name -like "stelem*" }).Count -eq 1
}
if (-not $arrOk) { $why += "InvokeRoutedRPC's parameters are not exactly { the ZPackage }" }
if ($why.Count -eq 0) { Ok "sending: _inLocalSend is set before InvokeRoutedRPC inside the try its finally clears, and the call's parameters are exactly { the ZPackage }" }
else { Fail ("sending: {0}" -f ($why -join "; ")) }
# The one "playing now" line: in Start, after Play and after the try, reached only when the start did not throw (the
# catch leaves past it), naming Who[kind]; Who is written only as Who[kind] = "you" (OnLocal) and Who[kind] = who (OnRemote).
$checks++
$why = @()
$stI = @($as.Body.Instructions); $plR = @(Find-Calls $as "AudioSource" "Play"); $liR = @(Find-Calls $as "ManualLogSource" "LogInfo"); $shR = @($as.Body.ExceptionHandlers | Where-Object { "$($_.HandlerType)" -eq "Catch" })
if (-not ($plR.Count -eq 1 -and $liR.Count -eq 1 -and $shR.Count -eq 1 -and $liR[0] -gt $plR[0])) { $why += "Start does not have one LogInfo after Play" }
else {
    $hS = [array]::IndexOf($stI, $shR[0].HandlerStart); $hE = if ($shR[0].HandlerEnd) { [array]::IndexOf($stI, $shR[0].HandlerEnd) } else { $stI.Count }
    if ($liR[0] -lt $hE) { $why += "Start's LogInfo is inside the try or the catch" }
    $catchLeaves = @(for ($k = $hS; $k -lt $hE; $k++) { if ($stI[$k].OpCode.Name -match '^leave(\.s)?$') { [array]::IndexOf($stI, $stI[$k].Operand) } })
    if ($catchLeaves.Count -lt 1 -or @($catchLeaves | Where-Object { $_ -le $liR[0] }).Count -gt 0) { $why += "a failed start can reach the 'playing now' line" }
    if (@(for ($k = $hE; $k -lt $liR[0]; $k++) { if ("$($stI[$k].OpCode.FlowControl)" -eq "Cond_Branch" -and [array]::IndexOf($stI, $stI[$k].Operand) -gt $liR[0]) { $k } }).Count -gt 0) { $why += "Start's LogInfo is under a condition" }
}
$wr = @(for ($k = 0; $k -lt $stI.Count - 2; $k++) { if ((Test-Is $stI[$k] "ldsfld" "Alerts" "Who")) { $k } })
if (-not ($wr.Count -eq 1 -and (Get-ArgName $as $stI[$wr[0] + 1]) -eq "kind" -and $stI[$wr[0] + 2].OpCode.Name -eq "ldelem.ref")) { $why += "Start does not name Who[kind]" }
$litOwners = @(); foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if ($m.HasBody) { foreach ($i in $m.Body.Instructions) { if ($i.OpCode.Name -eq "ldstr" -and "$($i.Operand)" -like "*playing now*") { $litOwners += (Get-Owner $m) } } } } }
if ((($litOwners | Sort-Object -Unique) -join ",") -ne "NuclearTrollstav.Alerts::Start") { $why += "'playing now' is written in: " + $(if ($litOwners.Count) { ($litOwners | Sort-Object -Unique) -join ", " } else { "no method" }) }
$ws = @(); foreach ($t in (Get-AllTypes $plug)) { foreach ($m in $t.Methods) { if (-not $m.HasBody) { continue }; $mi = @($m.Body.Instructions); for ($k = 3; $k -lt $mi.Count; $k++) { if ($mi[$k].OpCode.Name -eq "stelem.ref" -and (Test-Is $mi[$k - 3] "ldsfld" "Alerts" "Who")) { $ws += ,@($m, $k) } } } }
$wOk = $ws.Count -eq 2
foreach ($w in $ws) { $m = $w[0]; $mi = @($m.Body.Instructions); $k = $w[1]; $o = Get-Owner $m
    if ((Get-ArgName $m $mi[$k - 2]) -ne "kind") { $wOk = $false }
    elseif ($o -eq "NuclearTrollstav.Alerts::OnLocal") { if (-not ($mi[$k - 1].OpCode.Name -eq "ldstr" -and "$($mi[$k - 1].Operand)" -eq "you")) { $wOk = $false } }
    elseif ($o -eq "NuclearTrollstav.Alerts::OnRemote") { $st = Get-StoreBefore $m ($k - 1); if (-not ($mi[$k - 1].OpCode.Name -like "ldloc*" -and $st -ge 1 -and (Test-Is $mi[$st - 1] "call" "String" "Format"))) { $wOk = $false } }
    else { $wOk = $false } }
if (-not $wOk) { $why += "Who is not written exactly as Who[kind] = ""you"" (OnLocal) and Who[kind] = who (OnRemote)" }
if ($why.Count -eq 0) { Ok "the one 'playing now' line: in Start after Play, only when it started, naming Who[kind]; Who[kind] is set to you / who on acceptance" } else { Fail ("the 'playing now' line: {0}" -f ($why -join "; ")) }
# The game: Attack.OnAttackTrigger's callers are the reviewed two (Humanoid.OnAttackTrigger, owner-gated above, and
# Attack.StartWithoutAnimation, reached only from BlockAttack with build-block charges, which Trollstav has none of).
$checks++
$aot = @((Get-GameCallSites "Attack" "OnAttackTrigger") | ForEach-Object { "{0}::{1}" -f $_[0].DeclaringType.Name, $_[0].Name } | Sort-Object -Unique)
if (($aot -join ",") -eq "Attack::StartWithoutAnimation,Humanoid::OnAttackTrigger") { Ok "the game calls Attack.OnAttackTrigger only from Humanoid.OnAttackTrigger and Attack.StartWithoutAnimation" }
else { Fail ("Attack.OnAttackTrigger callers changed: " + ($aot -join ", ")) }

# ---------------------------------------------------------------------------------------------------------------
Write-Output "== assembly references =="
foreach ($ar in $plug.AssemblyReferences) {
    if ($ar.Name -eq "mscorlib" -or $ar.Name -eq "System.Core" -or $ar.Name -eq "System" -or $ar.Name -eq "netstandard") { continue }
    $checks++
    if ((Test-Path -LiteralPath (Join-Path $managed ($ar.Name + ".dll"))) -or (Test-Path -LiteralPath (Join-Path $core ($ar.Name + ".dll")))) { Ok $ar.Name }
    else { Fail ("{0} cannot be found in the game folder" -f $ar.Name) }
}

Write-Output ""
if ($failedChecks.Count -eq 0) { Write-Output "PREFLIGHT PASSED - $checks checks, 0 failed."; exit 0 }
Write-Output ("PREFLIGHT FAILED - {0} of {1} checks failed." -f $failedChecks.Count, $checks)
exit 1
