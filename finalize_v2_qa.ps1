[CmdletBinding()]
param(
    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" }),

    # 单次 chroma 去污染的强度参数。默认值即技能原始设定；仅当校验残留极少量边缘像素时才需要调高。
    [double]$DespillSpillTolerance = 0.15,
    [double]$DespillStrength = 1
)

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$HatchScripts = Join-Path $CodexHome "skills\hatch-pet\scripts"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$RequestPath = Join-Path $RunDir "pet_request.json"
$FinalDir = Join-Path $RunDir "final"
$QaDir = Join-Path $RunDir "qa"

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
    if ($exitCode -ne 0) { throw "$ScriptName 失败（exit $exitCode）；停止 v2 QA。" }
}

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "找不到 Python 运行时：$Python" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "找不到任务清单：$ManifestPath" }
if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) { throw "找不到 pet_request.json：$RequestPath" }
$env:PYTHONPATH = Join-Path $PSScriptRoot "pylibs"
$env:PYTHONIOENCODING = "utf-8"

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$requiredJobs = @("base", "idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review", "look-cardinals", "look-row-9", "look-row-10")
foreach ($jobId in $requiredJobs) {
    $job = @($manifest.jobs | Where-Object { $_.id -eq $jobId }) | Select-Object -First 1
    if ($null -eq $job -or $job.status -ne "complete") { throw "任务 '$jobId' 尚未通过审核并标记 complete。" }
    $outputPath = Join-Path $RunDir $job.output_path
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "任务 '$jobId' 的输出不存在：$outputPath" }
}

$chromaKey = (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json).chroma_key.hex
$baseAtlas = Join-Path $FinalDir "spritesheet.webp"
$registeredRow9 = Join-Path $QaDir "look-row-9-registered.png"
$row9Registration = Join-Path $QaDir "look-row-9-registration.json"
$row10 = Join-Path $RunDir "decoded\look-row-10.png"
$neutralCell = Join-Path $RunDir "frames\idle\00.png"
$approvedCardinals = Join-Path $RunDir "decoded\look-anchors-approved.png"
foreach ($required in @($baseAtlas, $registeredRow9, $row9Registration, $row10, $neutralCell, $approvedCardinals)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "v2 组装前置文件缺失：$required" }
}

$despillReport = Join-Path $QaDir "chroma-despill-extended.json"
if (Test-Path -LiteralPath $despillReport) {
    throw "已存在 despill 报告，技能要求仅执行一次 chroma 清理；为避免重复处理，脚本拒绝重跑。"
}
New-Item -ItemType Directory -Force -Path $FinalDir, $QaDir | Out-Null

$atlasPng = Join-Path $FinalDir "spritesheet-extended.png"
$atlasWebp = Join-Path $FinalDir "spritesheet-extended.webp"
$atlasManifest = Join-Path $FinalDir "spritesheet-extended.json"
Invoke-HatchTool "assemble_extended_atlas.py" @(
    "--base-atlas", $baseAtlas,
    "--registered-row-9", $registeredRow9,
    "--row-9-registration", $row9Registration,
    "--look-row-10", $row10,
    "--neutral-cell", $neutralCell,
    "--chroma-key", $chromaKey,
    "--chroma-threshold", "96",
    "--output", $atlasPng,
    "--webp-output", $atlasWebp,
    "--manifest-output", $atlasManifest
)

# This is the one and only despill invocation for the completed 8x11 atlas.
Invoke-HatchTool "despill_chroma_edges.py" @(
    $atlasPng,
    "--output", $atlasPng,
    "--webp-output", $atlasWebp,
    "--chroma-key", $chromaKey,
    "--strength", "$DespillStrength",
    "--spill-tolerance", "$DespillSpillTolerance",
    "--json-out", $despillReport
)
$despill = Get-Content -LiteralPath $despillReport -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $despill.ok) { throw "despill 报告未通过；停止，不重复运行清理：$despillReport" }

$validationPath = Join-Path $FinalDir "validation-extended.json"
Invoke-HatchTool "validate_atlas.py" @(
    $atlasWebp,
    "--json-out", $validationPath,
    "--chroma-key", $chromaKey,
    "--require-v2"
)
$validation = Get-Content -LiteralPath $validationPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $validation.ok) { throw "v2 atlas validation 未通过：$validationPath" }

$contactSheet = Join-Path $QaDir "contact-sheet-extended.png"
$directionSheet = Join-Path $QaDir "look-directions.png"
$blindSheet = Join-Path $QaDir "direction-blind-pairs.png"
$answerKey = Join-Path $QaDir "direction-blind-answer-key.json"
$continuity = Join-Path $QaDir "look-continuity.json"
Invoke-HatchTool "make_contact_sheet.py" @($atlasWebp, "--output", $contactSheet)
Invoke-HatchTool "make_direction_qa_sheet.py" @($atlasWebp, "--output", $directionSheet)
Invoke-HatchTool "make_direction_blind_qa_sheet.py" @($atlasWebp, "--output", $blindSheet, "--answer-key", $answerKey)
Invoke-HatchTool "measure_direction_continuity.py" @($atlasWebp, "--json-out", $continuity)

$semanticsTemplatePath = Join-Path $QaDir "direction-semantics-template.json"
if (-not (Test-Path -LiteralPath $semanticsTemplatePath)) {
    $directions = @(
        @{ degree = "000"; expected = "up"; horizontal_axis = "not_required"; vertical_axis = "up" },
        @{ degree = "022.5"; expected = "up-right"; horizontal_axis = "screen-right"; vertical_axis = "up" },
        @{ degree = "045"; expected = "up-right"; horizontal_axis = "screen-right"; vertical_axis = "up" },
        @{ degree = "067.5"; expected = "up-right"; horizontal_axis = "screen-right"; vertical_axis = "up" },
        @{ degree = "090"; expected = "right"; horizontal_axis = "screen-right"; vertical_axis = "not_required" },
        @{ degree = "112.5"; expected = "down-right"; horizontal_axis = "screen-right"; vertical_axis = "down" },
        @{ degree = "135"; expected = "down-right"; horizontal_axis = "screen-right"; vertical_axis = "down" },
        @{ degree = "157.5"; expected = "down-right"; horizontal_axis = "screen-right"; vertical_axis = "down" },
        @{ degree = "180"; expected = "down"; horizontal_axis = "not_required"; vertical_axis = "down" },
        @{ degree = "202.5"; expected = "down-left"; horizontal_axis = "screen-left"; vertical_axis = "down" },
        @{ degree = "225"; expected = "down-left"; horizontal_axis = "screen-left"; vertical_axis = "down" },
        @{ degree = "247.5"; expected = "down-left"; horizontal_axis = "screen-left"; vertical_axis = "down" },
        @{ degree = "270"; expected = "left"; horizontal_axis = "screen-left"; vertical_axis = "not_required" },
        @{ degree = "292.5"; expected = "up-left"; horizontal_axis = "screen-left"; vertical_axis = "up" },
        @{ degree = "315"; expected = "up-left"; horizontal_axis = "screen-left"; vertical_axis = "up" },
        @{ degree = "337.5"; expected = "up-left"; horizontal_axis = "screen-left"; vertical_axis = "up" }
    )
    $template = [ordered]@{
        status = "pending_visual_review"
        atlas = $atlasWebp
        directions = @($directions | ForEach-Object {
            [ordered]@{
                degree = $_.degree
                expected = $_.expected
                observed = ""
                horizontal_axis_expected = $_.horizontal_axis
                horizontal_axis_evidence = ""
                vertical_axis_expected = $_.vertical_axis
                vertical_axis_evidence = ""
                verdict = "pending"
                reason = ""
            }
        })
        note = "Reviewer must inspect normal-size cells and ordered loop; this template is not a QA verdict."
    }
    $template | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $semanticsTemplatePath -Encoding UTF8
}

Write-Host "v2 确定性 atlas、despill、validation 和 QA 图已生成。"
Write-Host "仍须由独立视觉审核者完成 direction-semantics.json、三份 blind verdict 与最终联系表审核，之后才能打包。"
Write-Host "Atlas：$atlasWebp"
Write-Host "联系表：$contactSheet"
Write-Host "方向表：$directionSheet"
Write-Host "blind sheet：$blindSheet"
