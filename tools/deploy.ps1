<#
.SYNOPSIS
  Installs a NuclearTrollstav build into the game: BepInEx\plugins\NuclearTrollstav\ (the DLL and the two sounds).

.DESCRIPTION
  Runs preflight on the DLL first and installs nothing if it fails. Refuses while Valheim is running (the game holds
  the plugin open). An existing BepInEx\plugins\NuclearTrollstav\ folder is moved, never deleted, into -KeepDir
  (default: retired\ in this folder, git-ignored) under a time-stamped name. Then it copies the DLL and the two
  sounds, checks each installed file's SHA-256 against its source, and runs preflight on the installed DLL.

  -Dll is the plugin to install (default build\NuclearTrollstav.dll); -Sounds is the folder holding
  "Nuclear Silo Arm.mp3" and "Nuclear Missile Launch Sound.mp3" (default: the DLL's own folder when both are
  there - an unpacked release zip - else sounds\ in this folder). The game folder is -ValheimDir, else the VALHEIM
  environment variable, else the default.

.EXAMPLE
  .\tools\deploy.ps1
  .\tools\deploy.ps1 -Dll C:\unpacked\NuclearTrollstav\NuclearTrollstav.dll
#>
[CmdletBinding(PositionalBinding = $false)]   # every argument named: a stray one is an error
param(
    [string]$Dll = "",
    [string]$Sounds = "",
    [string]$ValheimDir = "",
    [string]$KeepDir = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
if ($ValheimDir -eq "") { $ValheimDir = if ($env:VALHEIM) { $env:VALHEIM } else { "E:\SteamLibrary\steamapps\common\Valheim" } }
$ValheimDir = $ValheimDir.TrimEnd('\', '"')
if ($Dll -eq "") { $Dll = Join-Path $repo "build\NuclearTrollstav.dll" }
if ($KeepDir -eq "") { $KeepDir = Join-Path $repo "retired" }
$Dll = $Dll.TrimEnd('"'); $Sounds = $Sounds.TrimEnd('\', '"'); $KeepDir = $KeepDir.TrimEnd('\', '"')
$names = @("Nuclear Silo Arm.mp3", "Nuclear Missile Launch Sound.mp3")

if (-not (Test-Path -LiteralPath $Dll -PathType Leaf)) { throw "No plugin at $Dll - build it first (dotnet build NuclearTrollstav.csproj -c Release)." }
$Dll = (Resolve-Path -LiteralPath $Dll).ProviderPath
if ($Sounds -eq "") {
    $beside = Split-Path $Dll -Parent
    $Sounds = if (@($names | Where-Object { Test-Path -LiteralPath (Join-Path $beside $_) }).Count -eq 2) { $beside } else { Join-Path $repo "sounds" }
}
foreach ($n in $names) { if (-not (Test-Path -LiteralPath (Join-Path $Sounds $n) -PathType Leaf)) { throw "No '$n' in $Sounds." } }
if (@(Get-Process -Name valheim -ErrorAction SilentlyContinue).Count -gt 0) { throw "Valheim is running - close it first." }

Write-Output "Preflight on $Dll"
& (Join-Path $PSScriptRoot "preflight.ps1") -Plugin $Dll -ValheimDir $ValheimDir | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Preflight failed - nothing was installed." }

$dest = Join-Path $ValheimDir "BepInEx\plugins\NuclearTrollstav"
if (Test-Path -LiteralPath $dest) {
    New-Item -ItemType Directory -Force -Path $KeepDir | Out-Null
    $kept = Join-Path $KeepDir ("NuclearTrollstav-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    Move-Item -LiteralPath $dest -Destination $kept
    Write-Output "Moved the previous install to $kept"
}
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$pairs = @(,@($Dll, (Join-Path $dest "NuclearTrollstav.dll")))   # the comma keeps the pair one element: @(@(a, b)) flattens
foreach ($n in $names) { $pairs += ,@((Join-Path $Sounds $n), (Join-Path $dest $n)) }
foreach ($p in $pairs) {
    Copy-Item -LiteralPath $p[0] -Destination $p[1]
    $a = (Get-FileHash -LiteralPath $p[0] -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $p[1] -Algorithm SHA256).Hash
    if ($a -ne $b) { throw "Copy of $(Split-Path $p[0] -Leaf) does not match its source." }
    Write-Output ("{0}  {1}" -f $b.ToLowerInvariant(), $p[1])
}
& (Join-Path $PSScriptRoot "preflight.ps1") -Plugin (Join-Path $dest "NuclearTrollstav.dll") -ValheimDir $ValheimDir | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Preflight failed on the installed plugin." }
Write-Output "Installed. The next game start logs 'NuclearTrollstav <version> loaded.' in BepInEx\LogOutput.log."
