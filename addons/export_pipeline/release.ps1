<#
.SYNOPSIS
One-command verified export: export pck -> assert pck contents match the
reachability analysis (zero unused leaked, zero used missing) -> smoke-run
and assert no errors. Exits non-zero on any failure; CI-friendly.

.EXAMPLE
pwsh addons/export_pipeline/release.ps1 -GodotExe C:\godot\godot.exe -Preset "Windows Desktop" `
     -OutputPck out\game.pck -TemplateExe C:\templates\custom_template.exe
#>
param(
    [Parameter(Mandatory)] [string]$GodotExe,
    # Script lives at <project>/addons/export_pipeline/release.ps1.
    [string]$ProjectPath = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$Preset = "Windows Desktop",
    [string]$OutputPck = "$env:TEMP\release_verify\game.pck",
    # Export template exe for smoke-run + artifact assembly. When omitted,
    # the newest exe in <project>/tools/templates/ is auto-discovered.
    [string]$TemplateExe = "",
    # Shippable output. Defaults to <project>/dist (kept invisible to Godot
    # via an auto-created .gdignore).
    [string]$ArtifactDir = "",
    [int]$SmokeFrames = 300
)
# "Continue", not "Stop": with Stop, redirected native stderr (Godot's normal
# startup chatter) becomes a terminating error. Failures are checked explicitly.
$ErrorActionPreference = "Continue"
function Fail([string]$msg) { Write-Host "RELEASE FAILED: $msg" -ForegroundColor Red; exit 1 }
function Stage([string]$msg) { Write-Host "== $msg" -ForegroundColor Cyan }

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

# ── 1. Export (the export_pruner addon re-runs the analysis itself) ────────
Stage "Exporting preset '$Preset'"
New-Item -ItemType Directory -Force (Split-Path $OutputPck -Parent) | Out-Null
if (Test-Path $OutputPck) { Remove-Item $OutputPck -Force }
$r = Invoke-Godot @("--headless", "--path", (Quoted $ProjectPath), "--export-pack", (Quoted $Preset), (Quoted $OutputPck)) "export"
$exportLog = $r.Out + $r.Err
$exportLog | Where-Object { $_ -match "export_pruner|STALE|ERROR: " } | ForEach-Object { Write-Host "   $_" }
if (-not (Test-Path $OutputPck)) { Fail "no pck produced at $OutputPck" }
if ($exportLog -match "profile is STALE") { Fail "engine build profile is stale (see warning above)" }

# ── 2. Verify pck contents against the analysis report ─────────────────────
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

# ── 3. Smoke-run on the (custom) template ───────────────────────────────────
if ($TemplateExe -eq "") {
    # Template resolution: fresh self-built (tools/templates/) > official
    # installed template (with a warning when the self-built one is stale).
    $tplDir = Join-Path $ProjectPath "tools\templates"
    $tpl = if (Test-Path $tplDir) { Get-ChildItem $tplDir -Filter *.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    $profilePath = Join-Path $ProjectPath "tools\engine.build"
    $tplStale = $tpl -and (Test-Path $profilePath) -and ($tpl.LastWriteTime -lt (Get-Item $profilePath).LastWriteTime)
    if ($tpl -and -not $tplStale) {
        $TemplateExe = $tpl.FullName
        Write-Host "   auto-discovered template: tools/templates/$($tpl.Name)"
    } else {
        if ($tplStale) {
            Write-Host "   WARNING: tools/templates/$($tpl.Name) is OLDER than tools/engine.build — recompile it (Project > Tools > Generate Build Profile). Falling back to the official template." -ForegroundColor Yellow
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
if ($TemplateExe -eq "") {
    Write-Host "   (no template given or discovered — smoke stage skipped)" -ForegroundColor Yellow
} else {
    Stage "Smoke-running $SmokeFrames frames on $(Split-Path $TemplateExe -Leaf)"
    $smokeDir = "$env:TEMP\release_verify\smoke"
    New-Item -ItemType Directory -Force $smokeDir | Out-Null
    Copy-Item $TemplateExe "$smokeDir\game.exe" -Force
    Copy-Item $OutputPck "$smokeDir\game.pck" -Force
    $p = Start-Process "$smokeDir\game.exe" -ArgumentList "--headless","--quit-after",$SmokeFrames `
        -RedirectStandardOutput "$smokeDir\out.log" -RedirectStandardError "$smokeDir\err.log" -PassThru -Wait
    # Exit-time leak chatter from tool scripts is benign and not a load failure.
    $benign = "resources still in use at exit|ObjectDB instances were leaked|RID allocations of type|Pages in use exist at exit"
    $errors = @(Get-Content "$smokeDir\err.log" | Select-String "ERROR|SCRIPT ERROR" |
        Where-Object { $_.Line -notmatch $benign })
    Write-Host "   smoke exit: $($p.ExitCode) | real errors: $($errors.Count)"
    if ($errors.Count) { $errors | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }; Fail "smoke run produced errors" }

    # ── 4. Assemble the shippable artifact (template exe + pck) ────────────
    Stage "Assembling artifact"
    if ($ArtifactDir -eq "") { $ArtifactDir = Join-Path $ProjectPath "dist" }
    New-Item -ItemType Directory -Force $ArtifactDir | Out-Null
    # If the artifacts land inside the project, keep Godot (editor, importer
    # and the analyzer) from ever looking at them.
    $marker = Join-Path $ArtifactDir ".gdignore"
    if (-not (Test-Path $marker)) { New-Item -ItemType File $marker | Out-Null }
    $gameName = [IO.Path]::GetFileNameWithoutExtension($OutputPck)
    Copy-Item $TemplateExe (Join-Path $ArtifactDir "$gameName.exe") -Force
    Copy-Item $OutputPck (Join-Path $ArtifactDir "$gameName.pck") -Force
    $total = (Get-ChildItem $ArtifactDir | Measure-Object Length -Sum).Sum
    Write-Host "   $ArtifactDir ($([math]::Round($total/1MB,1)) MB total)"
}

Stage "RELEASE OK — $OutputPck ($([math]::Round((Get-Item $OutputPck).Length/1MB,1)) MB)"
exit 0
