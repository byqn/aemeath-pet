[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "base", "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review", "look-cardinals",
        "look-row-9", "look-row-10"
    )]
    [string]$JobId,

    [Parameter(Mandatory = $true)]
    [string]$DecisionNote,

    [Parameter(Mandatory = $true)]
    [switch]$ConfirmVisualReview
)

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$job = @($manifest.jobs | Where-Object { $_.id -eq $JobId }) | Select-Object -First 1
if ($null -eq $job) { throw "imagegen-jobs.json 中没有任务 '$JobId'" }
if ($job.status -eq "complete") { throw "任务 '$JobId' 已 complete；拒绝重复批准和覆盖审核记录。" }
if (-not $ConfirmVisualReview) { throw "必须先目视检查该任务图像，再传入 -ConfirmVisualReview。" }
if ([string]::IsNullOrWhiteSpace($DecisionNote) -or $DecisionNote.Trim().Length -lt 12) {
    throw "请写至少 12 个字符的具体审核依据，不要只写简单的通过说明。"
}

function Assert-SemanticsReview([string]$Path, [string[]]$ExpectedDegrees, [string[]]$HardCardinals) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "缺少方向语义审核记录：$Path" }
    $review = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $directions = @($review.directions)
    if ($directions.Count -ne $ExpectedDegrees.Count) { throw "方向记录数量错误：$Path" }
    for ($i = 0; $i -lt $ExpectedDegrees.Count; $i++) {
        $direction = $directions[$i]
        if ([string]$direction.degree -ne $ExpectedDegrees[$i]) { throw "方向顺序错误：期望 $($ExpectedDegrees[$i])，得到 $($direction.degree)。" }
        if ($direction.verdict -notin @("pass", "warning")) { throw "方向 $($direction.degree) 仍为 pending 或 fail。" }
        if ($HardCardinals -contains $ExpectedDegrees[$i] -and $direction.verdict -ne "pass") { throw "cardinal $($direction.degree) 必须明确 pass。" }
        if ([string]::IsNullOrWhiteSpace($direction.observed) -or [string]::IsNullOrWhiteSpace($direction.reason)) { throw "方向 $($direction.degree) 缺少 observed/reason 证据。" }
        if ($direction.horizontal_axis_expected -ne "not_required" -and [string]::IsNullOrWhiteSpace($direction.horizontal_axis_evidence)) { throw "方向 $($direction.degree) 缺少水平轴证据。" }
        if ($direction.vertical_axis_expected -ne "not_required" -and [string]::IsNullOrWhiteSpace($direction.vertical_axis_evidence)) { throw "方向 $($direction.degree) 缺少垂直轴证据。" }
    }
}

$outputPath = [System.IO.Path]::GetFullPath((Join-Path $RunDir $job.output_path))
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "任务输出不存在：$outputPath" }

switch ($JobId) {
    "base" {
        # The base has no deterministic image inspector; visual approval is required above.
        $canonical = Join-Path $RunDir "references\canonical-base.png"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $canonical) | Out-Null
        Copy-Item -LiteralPath $outputPath -Destination $canonical -Force
    }
    { $_ -in @("idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review") } {
        $reviewPath = Join-Path $RunDir "qa\rows\$JobId\review.json"
        if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) { throw "缺少逐行 inspect_frames QA：$reviewPath" }
        $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $review.ok) { throw "逐行确定性 QA 未通过：$reviewPath；先修复错误，不能批准。" }
    }
    "look-cardinals" {
        $reportPath = Join-Path $RunDir "qa\cardinal-anchors.json"
        $candidate = Join-Path $RunDir "decoded\look-anchors-candidate.png"
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "缺少 cardinal 锚点候选或检查报告。"
        }
        $anchorReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $anchorReport.ok) { throw "cardinal 锚点确定性检查失败；不能批准。" }
        Assert-SemanticsReview (Join-Path $RunDir "qa\cardinal-semantics.json") @("000", "090", "180", "270") @("000", "090", "180", "270")
        Copy-Item -LiteralPath $candidate -Destination (Join-Path $RunDir "decoded\look-anchors-approved.png") -Force
    }
    "look-row-9" {
        foreach ($required in @(
            (Join-Path $RunDir "qa\look-row-9-registered.png"),
            (Join-Path $RunDir "qa\look-row-9-registration.json")
        )) { if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少 row 9 注册/边缘 QA：$required" } }
        Assert-SemanticsReview (Join-Path $RunDir "qa\look-row-9-semantics.json") @("000", "022.5", "045", "067.5", "090", "112.5", "135", "157.5") @("000", "090")
    }
    "look-row-10" {
        $candidate = Join-Path $RunDir "final\spritesheet-extended-candidate.webp"
        $candidateDirections = Join-Path $RunDir "qa\look-directions-candidate.png"
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or -not (Test-Path -LiteralPath $candidateDirections -PathType Leaf)) { throw "缺少 row 10 扩展 atlas 或方向 QA 候选。" }
        Assert-SemanticsReview (Join-Path $RunDir "qa\look-row-10-semantics.json") @("180", "202.5", "225", "247.5", "270", "292.5", "315", "337.5") @("180", "270")
    }
}

$job.status = "complete"
$job.source_path = $outputPath
$job.completed_at = (Get-Date).ToUniversalTime().ToString("o")
$job.review_note = $DecisionNote.Trim()
$tempManifest = $ManifestPath + ".tmp"
$manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tempManifest -Encoding UTF8
Move-Item -LiteralPath $tempManifest -Destination $ManifestPath -Force
Write-Host "已记录 $JobId 的人工视觉审核并标记 complete：$ManifestPath"
