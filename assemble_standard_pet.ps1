[CmdletBinding()]
param(
    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" })
)

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$HatchScripts = Join-Path $CodexHome "skills\hatch-pet\scripts"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$DecodedDir = Join-Path $RunDir "decoded"
$FramesDir = Join-Path $RunDir "frames"
$FinalDir = Join-Path $RunDir "final"
$QaDir = Join-Path $RunDir "qa"
$StandardStates = @("idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review")

function Invoke-HatchTool([string]$ScriptName, [string[]]$Arguments) {
    $scriptPath = Join-Path $HatchScripts $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "找不到 hatch-pet 工具：$scriptPath" }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $Python $scriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    foreach ($line in $output) { Write-Host $line }
    if ($exitCode -ne 0) { throw "$ScriptName 失败（exit $exitCode）；停止后续步骤。" }
}

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "找不到 Python 运行时：$Python" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "找不到任务清单：$ManifestPath" }
$env:PYTHONPATH = Join-Path $PSScriptRoot "pylibs"
$env:PYTHONIOENCODING = "utf-8"

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($state in $StandardStates) {
    $row = @($manifest.jobs | Where-Object { $_.id -eq $state }) | Select-Object -First 1
    if ($null -eq $row -or $row.status -ne "complete") { throw "标准行 '$state' 尚未通过审核并标记 complete。" }
    $decoded = Join-Path $DecodedDir ($state + ".png")
    if (-not (Test-Path -LiteralPath $decoded -PathType Leaf)) { throw "缺少标准行图像：$decoded" }
}

New-Item -ItemType Directory -Force -Path $FramesDir, $FinalDir, $QaDir | Out-Null
$started = (Get-Date).ToUniversalTime().ToString("o")

Invoke-HatchTool "extract_strip_frames.py" @(
    "--decoded-dir", $DecodedDir,
    "--output-dir", $FramesDir,
    "--states", "all",
    "--method", "auto"
)

$reviewPath = Join-Path $QaDir "review.json"
Invoke-HatchTool "inspect_frames.py" @(
    "--frames-root", $FramesDir,
    "--json-out", $reviewPath,
    "--require-components"
)
$review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $review.ok) { throw "标准帧确定性检查未通过；请根据 $reviewPath 修复，不继续组装。" }

$atlasPng = Join-Path $FinalDir "spritesheet.png"
$atlasWebp = Join-Path $FinalDir "spritesheet.webp"
Invoke-HatchTool "compose_atlas.py" @(
    "--frames-root", $FramesDir,
    "--output", $atlasPng,
    "--webp-output", $atlasWebp
)

$contactSheet = Join-Path $QaDir "contact-sheet.png"
Invoke-HatchTool "make_contact_sheet.py" @($atlasWebp, "--output", $contactSheet)
$previewDir = Join-Path $QaDir "previews"
Invoke-HatchTool "render_animation_previews.py" @(
    "--frames-root", $FramesDir,
    "--output-dir", $previewDir
)

$stageReport = [ordered]@{
    ok = $true
    stage = "standard-rows-deterministic"
    started_at = $started
    completed_at = (Get-Date).ToUniversalTime().ToString("o")
    states = $StandardStates
    frames_root = $FramesDir
    review = $reviewPath
    atlas_png = $atlasPng
    atlas_webp = $atlasWebp
    contact_sheet = $contactSheet
    previews = $previewDir
    visual_review_required = $true
    note = "确定性检查已通过；必须目视审核联系表和 GIF 后，再继续 look mechanics/cardinal 阶段。"
}
$stageReportPath = Join-Path $QaDir "standard-stage.json"
$stageReport | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $stageReportPath -Encoding UTF8
Write-Host "标准 atlas 与 QA 媒体已生成。请先查看联系表和 previews，再继续；尚未生成/打包 v2。"
Write-Host "联系表：$contactSheet"
Write-Host "阶段报告：$stageReportPath"
