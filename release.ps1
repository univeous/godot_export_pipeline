<#
.SYNOPSIS
One-command verified export: export via the real --export-debug/--export-release
path (so GDExtension shared libraries and their declared dependencies come
along the way Godot itself copies them) -> assert pck contents match the
reachability analysis (zero unused leaked, zero used missing) -> smoke-run
and assert no errors. Exits non-zero on any failure; CI-friendly.

Runs against a preset's own custom_template/{debug,release} field. When a
self-built template is available (or an official one, as fallback) and the
field is empty, this script temporarily points the preset at it for the
duration of the export and restores export_presets.cfg from a backup file
afterward — including self-healing on the *next* run if this one gets killed
before it can restore (see $presetsBakPath below). If no template can be
found at all, falls back to a pack-only export (--export-pack): no exe, no
shared libraries, no smoke/artifact stages, just a verified pck.

.EXAMPLE
pwsh addons/export_pipeline/release.ps1 -GodotExe C:\godot\godot.exe -Preset "Windows Desktop" `
     -OutputPck out\game.pck -TemplateExe C:\templates\custom_template.exe
#>
param(
    [Parameter(Mandatory)] [string]$GodotExe,
    # Script lives at <project>/addons/export_pipeline/release.ps1.
    [string]$ProjectPath = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$Preset = "Windows Desktop",
    [switch]$DebugExport,
    # Lives in its own subdirectory, never a parent of $workDir's other
    # subdirectories (smoke/, pck_lister/) — copying the whole export
    # directory into those would otherwise copy it into its own descendant.
    [string]$OutputPck = "$env:TEMP\release_verify\export\game.pck",
    # Template exe to export against. When omitted, the newest exe in
    # <project>/tools/templates/ is auto-discovered (falling back to the
    # official installed template, with a staleness warning).
    [string]$TemplateExe = "",
    # Shippable output. Defaults to <project>/dist (kept invisible to Godot
    # via an auto-created .gdignore).
    [string]$ArtifactDir = "",
    [int]$SmokeFrames = 300,
    # Opens the output directory on success; pass -NoOpen for CI/scripted runs.
    [switch]$NoOpen
)
# "Continue", not "Stop": with Stop, redirected native stderr (Godot's normal
# startup chatter) becomes a terminating error. Failures are checked explicitly.
$ErrorActionPreference = "Continue"

$presetsPath = Join-Path $ProjectPath "export_presets.cfg"
$presetsBakPath = "$presetsPath.release_ps1.bak"
$script:presetsPatched = $false

# Self-heal: a previous run patched custom_template and got killed (timeout,
# Ctrl+C, crash) before it could restore — the .bak is the pre-patch original.
if (Test-Path $presetsBakPath) {
    Write-Host "   found leftover $presetsBakPath from an interrupted run — restoring it first." -ForegroundColor Yellow
    Move-Item $presetsBakPath $presetsPath -Force
}
function Restore-Presets {
    if ($script:presetsPatched -and (Test-Path $presetsBakPath)) {
        Move-Item $presetsBakPath $presetsPath -Force
        $script:presetsPatched = $false
    }
}
function Fail([string]$msg) {
    Restore-Presets
    Write-Host "RELEASE FAILED: $msg" -ForegroundColor Red
    exit 1
}
function Stage([string]$msg) { Write-Host "== $msg" -ForegroundColor Cyan }
# Guards the whole-directory Copy-Item calls below: copying a directory into
# its own descendant recurses forever, silently filling the disk (this bit
# us once already — $exportDir and $workDir aliased to the same path).
function Assert-NotNested([string]$Source, [string]$Dest) {
    $srcFull = ([IO.Path]::GetFullPath($Source)).TrimEnd('\') + '\'
    $destFull = ([IO.Path]::GetFullPath($Dest)).TrimEnd('\') + '\'
    if ($destFull.StartsWith($srcFull, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "refusing to copy '$Source' into '$Dest' — destination is nested inside the source (would recurse forever)"
    }
}

$workDir = "$env:TEMP\release_verify"
New-Item -ItemType Directory -Force $workDir | Out-Null

# Godot must run via Start-Process -Wait with file redirects: plain `&`
# invocation inside a non-interactive pwsh returns before the export
# finishes and captures no output.
function Invoke-Godot([string[]]$GodotArgs, [string]$Tag) {
    $p = Start-Process $GodotExe -ArgumentList $GodotArgs `
        -RedirectStandardOutput "$workDir\$Tag.out.log" -RedirectStandardError "$workDir\$Tag.err.log" -PassThru -Wait
    return @{
        Exit = $p.ExitCode
        Out  = @(Get-Content "$workDir\$Tag.out.log" -ErrorAction SilentlyContinue)
        Err  = @(Get-Content "$workDir\$Tag.err.log" -ErrorAction SilentlyContinue)
    }
}
function Quoted([string]$s) { '"{0}"' -f $s }

$gameName = [IO.Path]::GetFileNameWithoutExtension($OutputPck)
$outputExe = Join-Path (Split-Path $OutputPck -Parent) "$gameName.exe"

# ── 1. Resolve the template up front — needed before exporting, since the
#      only way to point a preset at an ad-hoc template exe is to patch
#      export_presets.cfg's custom_template field before Godot reads it. ──
if ($TemplateExe -eq "") {
    # Template resolution: fresh self-built (tools/templates/) > official
    # installed template (with a warning when the self-built one is stale).
    # Freshness = the profile_used.build sidecar matching the current
    # engine.build by CONTENT — timestamps lie (copies preserve mtime,
    # identical rewrites bump it).
    $tplDir = Join-Path $ProjectPath "tools\templates"
    $tpl = if (Test-Path $tplDir) { Get-ChildItem $tplDir -Filter *.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    $profilePath = Join-Path $ProjectPath "tools\engine.build"
    $sidecar = Join-Path $tplDir "profile_used.build"
    $tplStale = $false
    if ($tpl -and (Test-Path $profilePath)) {
        $tplStale = -not (Test-Path $sidecar) -or
            ((Get-FileHash $sidecar).Hash -ne (Get-FileHash $profilePath).Hash)
    }
    if ($tpl -and -not $tplStale) {
        $TemplateExe = $tpl.FullName
        Write-Host "   auto-discovered template: tools/templates/$($tpl.Name)"
    } else {
        if ($tplStale) {
            Write-Host "   WARNING: tools/templates/$($tpl.Name) was built from an outdated (or unverifiable) profile — recompile/reinstall it with its profile_used.build sidecar (Project > Tools > Generate Build Profile). Falling back to the official template." -ForegroundColor Yellow
        }
        $ver = (Invoke-Godot @("--version") "version").Out | Select-Object -First 1
        if ($ver -match '^(\d+\.\d+(?:\.\d+)?\.\w+)') {
            $official = "$env:APPDATA\Godot\export_templates\$($Matches[1])\windows_release_x86_64.exe"
            if (Test-Path $official) {
                $TemplateExe = $official
                Write-Host "   using official template: $official"
            }
        }
    }
}

# ── 2. Export (the export_pruner addon re-runs the analysis itself) ────────
New-Item -ItemType Directory -Force (Split-Path $OutputPck -Parent) | Out-Null
if (Test-Path $OutputPck) { Remove-Item $OutputPck -Force }
if (Test-Path $outputExe) { Remove-Item $outputExe -Force }

if ($TemplateExe -eq "") {
    Write-Host "   (no template given or discovered — falling back to a pack-only export; no exe, no shared libraries, smoke/artifact stages skipped)" -ForegroundColor Yellow
    Stage "Exporting preset '$Preset' (pack only)"
    $r = Invoke-Godot @("--headless", "--path", (Quoted $ProjectPath), "--export-pack", (Quoted $Preset), (Quoted $OutputPck)) "export"
} else {
    Stage "Exporting preset '$Preset' against $(Split-Path $TemplateExe -Leaf)"
    Copy-Item $presetsPath $presetsBakPath -Force
    $script:presetsPatched = $true
    $rp = Invoke-Godot @("--headless", "--path", (Quoted $ProjectPath), "-s", "addons/export_pipeline/set_preset_template.gd",
        "--", (Quoted $Preset), $(if ($DebugExport) { "true" } else { "false" }), (Quoted $TemplateExe)) "patch_template"
    if ($rp.Exit -ne 0) { Fail "could not patch export_presets.cfg custom_template (see $workDir\patch_template.err.log)" }
    $exportCmd = if ($DebugExport) { "--export-debug" } else { "--export-release" }
    $r = Invoke-Godot @("--headless", "--path", (Quoted $ProjectPath), $exportCmd, (Quoted $Preset), (Quoted $outputExe)) "export"
    Restore-Presets
}
$exportLog = $r.Out + $r.Err
$exportLog | Where-Object { $_ -match "export_pruner|STALE|ERROR: " } | ForEach-Object { Write-Host "   $_" }
if (-not (Test-Path $OutputPck)) { Fail "no pck produced at $OutputPck" }
if ($exportLog -match "profile is STALE") { Fail "engine build profile is stale (see warning above)" }

# ── 3. Verify pck contents against the analysis report ─────────────────────
Stage "Verifying pck contents against export_report.json"
$reportPath = Join-Path $ProjectPath "tools\export_report.json"
if (-not (Test-Path $reportPath)) { Fail "no analysis report at $reportPath" }
$report = Get-Content $reportPath -Raw | ConvertFrom-Json

# Minimal throwaway project whose only job is to mount the pck and list it.
$verifyDir = "$env:TEMP\release_verify\pck_lister"
New-Item -ItemType Directory -Force $verifyDir | Out-Null
Set-Content "$verifyDir\project.godot" "config_version=5`n"
Set-Content "$verifyDir\list_pck.gd" @'
extends SceneTree
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if not ProjectSettings.load_resource_pack(args[0], false):
		push_error("failed to load pack")
		quit(1)
		return
	_walk("res://")
	quit()
func _walk(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var path := dir_path.path_join(name)
		if dir.current_is_dir():
			_walk(path)
		else:
			print("PCK:" + path)
		name = dir.get_next()
	dir.list_dir_end()
'@
$r2 = Invoke-Godot @("--headless", "--path", (Quoted $verifyDir), "-s", "list_pck.gd", "--", (Quoted $OutputPck)) "lister"
$pckList = $r2.Out | Where-Object { $_ -like "PCK:*" } | ForEach-Object { $_.Substring(4) }
if (-not $pckList) { Fail "pck listing produced no entries" }

# Map pck entries back to source paths (.import/.remap sidecars, .gdc tokens).
$logical = [System.Collections.Generic.HashSet[string]]::new()
foreach ($e in $pckList) {
    if ($e.StartsWith("res://.godot/")) { continue }
    $b = $e -replace '\.(import|remap)$','' -replace '\.gdc$','.gd'
    [void]$logical.Add($b)
}
$leaked = @($report.unused | Where-Object { $logical.Contains($_) })
$resExt = '\.(tscn|scn|tres|res|gd|gdshader|dialogue|png|jpg|jpeg|svg|webp|ogg|wav|mp3|ttf|otf|ogv|po|mo)$'
$missing = @($report.used | Where-Object { $_ -match $resExt -and -not $logical.Contains($_) })
Write-Host "   pck files: $($pckList.Count) ($($logical.Count) logical) | leaked unused: $($leaked.Count) | missing used: $($missing.Count)"
if ($leaked.Count) { $leaked | Select-Object -First 10 | ForEach-Object { Write-Host "   LEAKED: $_" -ForegroundColor Red }; Fail "unused files leaked into pck" }
if ($missing.Count) { $missing | Select-Object -First 10 | ForEach-Object { Write-Host "   MISSING: $_" -ForegroundColor Red }; Fail "used files missing from pck" }

# ── 4. Smoke-run + assemble artifact from the exported directory ───────────
# Whichever files Godot itself wrote alongside the exe (shared objects from
# GDExtensions, their declared dependencies, console wrapper, ...) — the
# whole directory ships as-is; nothing here hand-picks individual files.
$exportDir = Split-Path $outputExe -Parent
if (-not (Test-Path $outputExe)) {
    Write-Host "   (pack-only export — no exe to smoke-run or ship)" -ForegroundColor Yellow
} else {
    Stage "Smoke-running $SmokeFrames frames"
    $smokeDir = "$env:TEMP\release_verify\smoke"
    if (Test-Path $smokeDir) { Remove-Item $smokeDir -Recurse -Force }
    Assert-NotNested $exportDir $smokeDir
    Copy-Item $exportDir $smokeDir -Recurse -Force
    $smokeExe = Join-Path $smokeDir (Split-Path $outputExe -Leaf)
    $p = Start-Process $smokeExe -ArgumentList "--headless","--quit-after",$SmokeFrames `
        -RedirectStandardOutput "$smokeDir\out.log" -RedirectStandardError "$smokeDir\err.log" -PassThru -Wait
    # Exit-time leak chatter from tool scripts is benign and not a load failure.
    $benign = "resources still in use at exit|ObjectDB instances were leaked|RID allocations of type|Pages in use exist at exit"
    $errors = @(Get-Content "$smokeDir\err.log" | Select-String "ERROR|SCRIPT ERROR" |
        Where-Object { $_.Line -notmatch $benign })
    $errorReport = Join-Path $ProjectPath "tools\smoke_errors.log"
    $errors | Set-Content $errorReport
    Write-Host "   smoke exit: $($p.ExitCode) | real errors: $($errors.Count) (full list saved to $errorReport)"
    if ($errors.Count) { $errors | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }; Fail "smoke run produced errors — see $errorReport" }

    # ── 5. Assemble the shippable artifact ──────────────────────────────────
    Stage "Assembling artifact"
    if ($ArtifactDir -eq "") { $ArtifactDir = Join-Path $ProjectPath "dist" }
    if (Test-Path $ArtifactDir) { Remove-Item $ArtifactDir -Recurse -Force }
    Assert-NotNested $exportDir $ArtifactDir
    # If the artifact lands inside the project, keep Godot (editor, importer
    # and the analyzer) from ever looking at it.
    Copy-Item $exportDir $ArtifactDir -Recurse -Force
    $marker = Join-Path $ArtifactDir ".gdignore"
    if (-not (Test-Path $marker)) { New-Item -ItemType File $marker | Out-Null }
    $shipDir = $ArtifactDir
}

$pckMB = [math]::Round((Get-Item $OutputPck).Length/1MB,1)
if ($shipDir) {
    $total = (Get-ChildItem $shipDir -File -Recurse | Where-Object Name -ne ".gdignore" | Measure-Object Length -Sum).Sum
    Stage "RELEASE OK — $shipDir ($([math]::Round($total/1MB,1)) MB; pck $pckMB MB)"
} else {
    $shipDir = Split-Path $OutputPck -Parent
    Stage "RELEASE OK — $OutputPck ($pckMB MB; no template, pck only)"
}
if (-not $NoOpen) { Start-Process explorer.exe $shipDir }
exit 0
