[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$RequestPath = Join-Path $RunDir "pet_request.json"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$QaDir = Join-Path $RunDir "qa"
$FinalDir = Join-Path $RunDir "final"
$Atlas = Join-Path $FinalDir "spritesheet-extended.webp"
$ValidationPath = Join-Path $FinalDir "validation-extended.json"
$DespillPath = Join-Path $QaDir "chroma-despill-extended.json"
$SemanticPath = Join-Path $QaDir "direction-semantics.json"
$BlindValidationPath = Join-Path $QaDir "direction-blind-validation.json"
$FinalVisualQaPath = Join-Path $QaDir "final-visual-qa.json"
$DeliverableRoot = Join-Path $PSScriptRoot "deliverable\aemeath-pet-v2"
$ZipPath = Join-Path $PSScriptRoot "deliverable\aemeath-pet-v2.zip"

$requiredJobs = @("base", "idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review", "look-cardinals", "look-row-9", "look-row-10")
$requiredQaFiles = @(
    (Join-Path $QaDir "review.json"),
    (Join-Path $QaDir "standard-stage.json"),
    (Join-Path $QaDir "contact-sheet.png"),
    (Join-Path $QaDir "contact-sheet-extended.png"),
    (Join-Path $QaDir "look-directions.png"),
    (Join-Path $QaDir "direction-blind-pairs.png"),
    (Join-Path $QaDir "direction-blind-answer-key.json"),
    (Join-Path $QaDir "direction-blind-verdicts-1.json"),
    (Join-Path $QaDir "direction-blind-verdicts-2.json"),
    (Join-Path $QaDir "direction-blind-verdicts-3.json"),
    (Join-Path $QaDir "direction-blind-verdicts.json"),
    (Join-Path $QaDir "direction-blind-validation.json"),
    (Join-Path $QaDir "look-continuity.json"),
    $SemanticPath,
    $FinalVisualQaPath,
    $DespillPath,
    $ValidationPath
)

foreach ($path in @($RequestPath, $ManifestPath, $Atlas) + $requiredQaFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "打包前缺少必需文件：$path" }
}
if ((Test-Path -LiteralPath $DeliverableRoot) -or (Test-Path -LiteralPath $ZipPath)) {
    if (-not $Force) { throw "已有 deliverable 文件；确认覆盖请加 -Force。" }
    Remove-Item -LiteralPath $DeliverableRoot, $ZipPath -Recurse -Force -ErrorAction SilentlyContinue
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($jobId in $requiredJobs) {
    $job = @($manifest.jobs | Where-Object { $_.id -eq $jobId }) | Select-Object -First 1
    if ($null -eq $job -or $job.status -ne "complete") { throw "任务 '$jobId' 仍未 complete；不能打包。" }
}

$despill = Get-Content -LiteralPath $DespillPath -Raw -Encoding UTF8 | ConvertFrom-Json
$validation = Get-Content -LiteralPath $ValidationPath -Raw -Encoding UTF8 | ConvertFrom-Json
$blind = Get-Content -LiteralPath $BlindValidationPath -Raw -Encoding UTF8 | ConvertFrom-Json
$visual = Get-Content -LiteralPath $FinalVisualQaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$semantics = Get-Content -LiteralPath $SemanticPath -Raw -Encoding UTF8 | ConvertFrom-Json
$standardReview = Get-Content -LiteralPath (Join-Path $QaDir "review.json") -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $despill.ok) { throw "despill 报告未通过。" }
if (-not $validation.ok) { throw "8x11 atlas validation 未通过。" }
if (-not $blind.ok) { throw "blind direction validation 未通过；cardinal 歧义/冲突会阻止打包。" }
if ($visual.visual_qa -ne "pass") { throw "最终独立视觉 QA 未通过。" }
if (-not $standardReview.ok) { throw "标准帧 review.json 有错误。" }
if (@($semantics.directions).Count -ne 16) { throw "direction-semantics.json 必须包含全部 16 个方向。" }
foreach ($direction in $semantics.directions) {
    if ($direction.verdict -notin @("pass", "warning")) { throw "方向 $($direction.degree) 尚未通过语义审核，或标记为 fail。" }
    if ([string]::IsNullOrWhiteSpace($direction.observed) -or [string]::IsNullOrWhiteSpace($direction.reason)) {
        throw "方向 $($direction.degree) 缺少 observed/reason 视觉证据。"
    }
    if ($direction.horizontal_axis_expected -ne "not_required" -and [string]::IsNullOrWhiteSpace($direction.horizontal_axis_evidence)) {
        throw "方向 $($direction.degree) 缺少水平轴证据。"
    }
    if ($direction.vertical_axis_expected -ne "not_required" -and [string]::IsNullOrWhiteSpace($direction.vertical_axis_evidence)) {
        throw "方向 $($direction.degree) 缺少垂直轴证据。"
    }
}

$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pet = [ordered]@{
    id = $request.pet_id
    displayName = $request.display_name
    description = $request.description
    spriteVersionNumber = 2
    spritesheetPath = "spritesheet.webp"
}
$petJson = Join-Path $DeliverableRoot "pet.json"
New-Item -ItemType Directory -Force -Path $DeliverableRoot, (Join-Path $DeliverableRoot "qa") | Out-Null
$pet | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $petJson -Encoding UTF8
Copy-Item -LiteralPath $Atlas -Destination (Join-Path $DeliverableRoot "spritesheet.webp")

foreach ($source in $requiredQaFiles) {
    Copy-Item -LiteralPath $source -Destination (Join-Path $DeliverableRoot "qa")
}
foreach ($optionalName in @("direction-blind-answer-key.json", "blind-review-resolution.json", "direction-semantics-template.json")) {
    $optional = Join-Path $QaDir $optionalName
    if ((Test-Path -LiteralPath $optional -PathType Leaf) -and $optionalName -ne "direction-semantics-template.json") {
        Copy-Item -LiteralPath $optional -Destination (Join-Path $DeliverableRoot "qa")
    }
}
$previewDir = Join-Path $QaDir "previews"
if (Test-Path -LiteralPath $previewDir -PathType Container) {
    Copy-Item -LiteralPath $previewDir -Destination (Join-Path $DeliverableRoot "qa") -Recurse
}

$summaryPath = Join-Path $QaDir "run-summary.json"
$summary = [ordered]@{
    ok = $true
    spriteVersionNumber = 2
    run_dir = $RunDir
    spritesheet = $Atlas
    validation = $ValidationPath
    chroma_despill = $DespillPath
    contact_sheet = (Join-Path $QaDir "contact-sheet-extended.png")
    direction_sheet = (Join-Path $QaDir "look-directions.png")
    direction_semantics = $SemanticPath
    blind_direction_validation = $BlindValidationPath
    continuity = (Join-Path $QaDir "look-continuity.json")
    review = (Join-Path $QaDir "review.json")
    package = $DeliverableRoot
    created_at = (Get-Date).ToUniversalTime().ToString("o")
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $DeliverableRoot "qa\run-summary.json") -Force
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ZipPath) | Out-Null
Compress-Archive -Path (Join-Path $DeliverableRoot "*") -DestinationPath $ZipPath -CompressionLevel Optimal

if ($Install) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
    $petInstallDir = Join-Path $CodexHome "pets\aemeath"
    New-Item -ItemType Directory -Force -Path $petInstallDir | Out-Null
    Copy-Item -LiteralPath $petJson -Destination (Join-Path $petInstallDir "pet.json") -Force
    Copy-Item -LiteralPath (Join-Path $DeliverableRoot "spritesheet.webp") -Destination (Join-Path $petInstallDir "spritesheet.webp") -Force
    Write-Host "已安装到：$petInstallDir"
}

Write-Host "桌宠文件包：$ZipPath"
Write-Host "解压目录：$DeliverableRoot"
