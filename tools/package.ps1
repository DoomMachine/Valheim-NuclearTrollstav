<#
.SYNOPSIS
  Builds the release zip from a clean checkout: dist\NuclearTrollstav-<version>.zip, the same bytes every time.

.DESCRIPTION
  Refuses unless the checkout is clean - no changed or untracked files, and no ignored file that can change a
  build (a NuclearTrollstav.csproj.user, a Directory.Build.* file; only the tools' own output folders may be there) -
  empties build\ and obj\ before building, so nothing an earlier build left there (an extra
  obj\NuclearTrollstav.csproj.*.props) reaches the zip, and builds with Directory.Build.* and Directory.Packages.props
  files above the checkout and MSBuild response files switched off. Other inputs besides the commit remain - among
  them the .NET SDK, the game's and BepInEx's files, per-user MSBuild imports and the shell's environment (MSBuild
  reads environment variables as properties) - so build in a plain shell. A release's zip comes from a fresh clone of
  its tag.

  It builds NuclearTrollstav.csproj from scratch (Release, with no debug symbols whatever a local .csproj.user says),
  checks that the DLL's version names this commit and that it carries no symbol-file path, and zips five entries in
  this order, all in a folder NuclearTrollstav/: NuclearTrollstav.dll as built, then the two sounds, README.md and
  LICENSE exactly as the commit stores them. Every entry carries the commit's time.

  So the same commit gives a byte-identical zip when this runs in Windows PowerShell 5.1 (its .NET Framework does
  the compressing; PowerShell 7 compresses differently, so this script refuses to run there) with the same .NET
  SDK, against the same Valheim and BepInEx files - which is how a release's zip can be checked. It prints the
  zip's SHA-256, writes it beside the zip as <zip>.sha256, and names the SDK, BepInEx and game files it used.

  The game folder is -ValheimDir, else the VALHEIM environment variable, else the default - as for the build.

.EXAMPLE
  .\tools\package.ps1
#>
[CmdletBinding(PositionalBinding = $false)]   # every argument named: a stray one is an error
param(
    [string]$ValheimDir = ""
)
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSEdition -ne "Desktop") {
    throw "Run this in Windows PowerShell 5.1 (powershell.exe): another PowerShell compresses the zip into different bytes."
}
$repo = Split-Path $PSScriptRoot -Parent
# Drop a trailing \, and the " that powershell.exe -File leaves when a quoted path ending in
# \ is the last argument (anywhere earlier it swallows the arguments after it: leave the \ off).
$ValheimDir = $ValheimDir.TrimEnd('\', '"')
if ($ValheimDir) {
    # Resolved here: MSBuild would resolve a relative path against the project's folder, not this shell's.
    if (-not (Test-Path -LiteralPath (Join-Path $ValheimDir "valheim_Data\Managed\assembly_valheim.dll"))) {
        throw "No Valheim install at $ValheimDir (valheim_Data\Managed\assembly_valheim.dll not found)."
    }
    $ValheimDir = (Resolve-Path -LiteralPath $ValheimDir).ProviderPath.TrimEnd('\')
}
$game = if ($ValheimDir) { $ValheimDir } elseif ($env:VALHEIM) { $env:VALHEIM.TrimEnd('\', '"') } else { "E:\SteamLibrary\steamapps\common\Valheim" }

function Git-Bytes([string[]]$arguments) {
    # git's output as raw bytes (PowerShell's own capture would re-encode it as text).
    $psi = New-Object System.Diagnostics.ProcessStartInfo("git")
    $psi.Arguments = "-C `"$repo`" " + ($arguments -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $buffer = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($buffer)
    $errors = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "git $($arguments -join ' ') failed: $errors" }
    return ,$buffer.ToArray()
}
function Git-Text([string[]]$arguments) { return [Text.Encoding]::UTF8.GetString((Git-Bytes $arguments)).Trim() }

if (Git-Text @("status", "--porcelain", "--untracked-files=normal")) { throw "The working tree has changes - commit or stash them; the zip must be exactly a commit." }
# Ignored files are invisible to the check above, and some change a build without changing the commit.
$outputs = @("build/", "dist/", "obj/", "bin/", "retired/", ".vs/", "tests/obj/", "tests/bin/")
$ignored = @((Git-Text @("status", "--porcelain", "--ignored", "--untracked-files=normal")) -split "`n" | Where-Object { $_.StartsWith("!! ") } |
    ForEach-Object { $_.Substring(3).Trim() } | Where-Object { $outputs -notcontains $_ })
if ($ignored.Count -gt 0) {
    throw ("Ignored files that can change the build: {0} - package from a fresh clone." -f ($ignored -join ", "))
}
$commit = Git-Text @("rev-parse", "HEAD")
$csproj = [IO.File]::ReadAllText((Join-Path $repo "NuclearTrollstav.csproj"))
$m = [regex]::Match($csproj, "<Version>([^<]+)</Version>")
if (-not $m.Success) { throw "No <Version> in NuclearTrollstav.csproj" }
$version = $m.Groups[1].Value
$seconds = [long](Git-Text @("log", "-1", "--format=%ct", "HEAD"))
$stamp = [DateTimeOffset]::FromUnixTimeSeconds($seconds)   # UTC, so the zip does not depend on the time zone
$tag = ""
try { $tag = Git-Text @("describe", "--exact-match", "--tags", "HEAD") } catch { }
if ($tag -ne "v$version") {
    Write-Warning "HEAD is not the tag v$version, so this zip is not that release's asset - upload only from a clone of the tag."
}

# The build's own folders are rebuilt from nothing. A directory link in them is refused rather than emptied through.
$generated = @("build", "obj", "tests\obj" | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path -LiteralPath $_ })
foreach ($dir in $generated) {   # all checked before any is emptied
    $isLink = (Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
    $links = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
    if ($isLink -or $links.Count -gt 0) { throw "$dir is or holds a directory link - package from a fresh clone." }
}
foreach ($dir in $generated) { [IO.Directory]::Delete($dir, $true) }

# DebugType=none on the command line: a global property, so an ignored NuclearTrollstav.csproj.user cannot turn
# symbols (and the build folder's path) back on. Directory.Build.* and Directory.Packages.props files above the
# checkout, and MSBuild.rsp files, are switched off too: global properties and -noAutoResponse, since a property
# inside the project would come too late for the SDK's imports.
$build = @("build", (Join-Path $repo "NuclearTrollstav.csproj"), "-c", "Release", "--no-incremental", "-nologo", "-v", "q", "-p:DebugType=none",
    "-p:ImportDirectoryBuildProps=false", "-p:ImportDirectoryBuildTargets=false", "-p:ImportDirectoryPackagesProps=false",
    "-noAutoResponse")
if ($ValheimDir) { $build += "-p:ValheimDir=$ValheimDir" }
& dotnet @build
if ($LASTEXITCODE -ne 0) { throw "The build failed." }
$dll = Join-Path $repo "build\NuclearTrollstav.dll"
$stamped = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll).ProductVersion
if ($stamped -ne "$version+$commit") { throw "The DLL says $stamped, not $version+$commit." }
$dllBytes = [IO.File]::ReadAllBytes($dll)
$ascii = [Text.Encoding]::ASCII.GetString($dllBytes)
if ($ascii.Contains("RSDS") -or $ascii.IndexOf(".pdb", [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "The DLL carries a symbol-file (CodeView) entry or a .pdb name - it would publish a local path."
}

$dist = Join-Path $repo "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist ("NuclearTrollstav-{0}.zip" -f $version)
Add-Type -AssemblyName System.IO.Compression
$entries = @(
    @("NuclearTrollstav/NuclearTrollstav.dll", $dllBytes),
    @("NuclearTrollstav/Nuclear Silo Arm.mp3", (Git-Bytes @("cat-file", "blob", "`"HEAD:sounds/Nuclear Silo Arm.mp3`""))),
    @("NuclearTrollstav/Nuclear Missile Launch Sound.mp3", (Git-Bytes @("cat-file", "blob", "`"HEAD:sounds/Nuclear Missile Launch Sound.mp3`""))),
    @("NuclearTrollstav/README.md", (Git-Bytes @("cat-file", "blob", "HEAD:README.md"))),
    @("NuclearTrollstav/LICENSE", (Git-Bytes @("cat-file", "blob", "HEAD:LICENSE")))
)
$stream = [IO.File]::Open($zip, [IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $entries) {
            $entry = $archive.CreateEntry($e[0], [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $stamp
            $w = $entry.Open()
            try { $w.Write($e[1], 0, $e[1].Length) } finally { $w.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($zip + ".sha256", "$hash  NuclearTrollstav-$version.zip`n", (New-Object Text.UTF8Encoding $false))
$bepinex = Join-Path $game "BepInEx\core\BepInEx.dll"
$valheim = Join-Path $game "valheim_Data\Managed\assembly_valheim.dll"
Write-Output ("NuclearTrollstav {0} ({1})" -f $version, $commit)
Write-Output (".NET SDK {0}; BepInEx {1}; assembly_valheim.dll SHA-256 {2}" -f (& dotnet --version),
    $(if (Test-Path -LiteralPath $bepinex) { [Diagnostics.FileVersionInfo]::GetVersionInfo($bepinex).ProductVersion } else { "?" }),
    $(if (Test-Path -LiteralPath $valheim) { (Get-FileHash -LiteralPath $valheim -Algorithm SHA256).Hash.ToLowerInvariant() } else { "?" }))
Write-Output ("DLL SHA-256 {0}" -f ([BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash($dllBytes)).Replace("-", "").ToLowerInvariant()))
Write-Output ("{0}  {1}" -f $hash, $zip)
