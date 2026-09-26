[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "base", "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review", "look-cardinals",
        "look-row-9", "look-row-10"
    )]
    [string]$JobId,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$AllowCustomEndpoint,

    # 图像模型名，必须保持 gpt-image-* 前缀。默认沿用 gpt-image-2。
    [string]$Model = "gpt-image-2",

    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" })
)

$ErrorActionPreference = "Stop"
if ($Model -notlike "gpt-image-*") { throw "模型名必须以 gpt-image- 开头：$Model" }
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$CliPath = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }) "skills\.system\imagegen\scripts\image_gen.py"
$OutputRoot = Join-Path $RunDir "decoded"
$ReportDir = Join-Path $RunDir "qa\cli-runs"
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$HatchScripts = Join-Path $CodexHome "skills\hatch-pet\scripts"

function Resolve-RunPath([string]$RelativePath) {
    $root = [System.IO.Path]::GetFullPath($RunDir).TrimEnd([char[]]@("\", "/")) + [System.IO.Path]::DirectorySeparatorChar
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $RunDir $RelativePath))
    if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "任务清单路径越出运行目录，已拒绝：$RelativePath"
    }
    return $resolved
}

function Invoke-PythonScript([string]$ScriptPath, [string[]]$Arguments) {
    # Python writes progress and dry-run notices to stderr; temporarily keep those native
    # stderr records from becoming terminating PowerShell errors under Stop preference.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $Python $ScriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    foreach ($line in $output) { Write-Host $line }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = [string]::Join([Environment]::NewLine, [string[]]$output)
    }
}

function Invoke-HatchScript([string]$ScriptName, [string[]]$Arguments) {
    $scriptPath = Join-Path $HatchScripts $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "找不到 hatch-pet 工具：$scriptPath" }
    $toolResult = Invoke-PythonScript $scriptPath $Arguments
    if ($toolResult.ExitCode -ne 0) { throw "hatch-pet 工具失败（$ScriptName，exit $($toolResult.ExitCode)）。候选图保留，但不会标记任务完成。" }
    return $toolResult
}

function Write-SemanticsTemplate([string]$OutputPath, [object[]]$Specs) {
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { return }
    $entries = @($Specs | ForEach-Object {
        [ordered]@{
            degree = $_.degree
            expected = $_.expected
            observed = ""
            horizontal_axis_expected = $_.horizontal
            horizontal_axis_evidence = ""
            vertical_axis_expected = $_.vertical
            vertical_axis_evidence = ""
            verdict = "pending"
            reason = ""
        }
    })
    $template = [ordered]@{
        status = "pending_visual_review"
        directions = $entries
        note = "This is a blank template, not an approval. A reviewer must inspect each normal-size pose and the ordered loop."
    }
    $template | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "找不到 Python 运行时：$Python" }
if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { throw "找不到 image_gen.py：$CliPath" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "找不到任务清单：$ManifestPath" }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$job = @($manifest.jobs | Where-Object { $_.id -eq $JobId }) | Select-Object -First 1
if ($null -eq $job) { throw "imagegen-jobs.json 中没有任务 '$JobId'" }
if ($job.status -eq "complete") { throw "任务 '$JobId' 已标记 complete；为保护已审核结果，先按审核流程撤销状态再重新生成。" }

$promptPath = Resolve-RunPath $job.prompt_file
if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) { throw "找不到提示词文件：$promptPath" }
$effectivePromptPath = $promptPath
$lookMechanicsPath = Join-Path $RunDir "qa\look-mechanics.md"
if ($JobId -like "look-*") {
    if (-not (Test-Path -LiteralPath $lookMechanicsPath -PathType Leaf)) {
        throw "look 任务必须先创建 pet 专属机制说明：$lookMechanicsPath"
    }
    $effectivePromptPath = Join-Path $ReportDir ($JobId + "-prompt.md")
    $combinedPrompt = (Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8).TrimEnd() +
        "`n`nPET-SPECIFIC LOOK MECHANICS (authoritative):`n" +
        (Get-Content -LiteralPath $lookMechanicsPath -Raw -Encoding UTF8).Trim()
    Set-Content -LiteralPath $effectivePromptPath -Value $combinedPrompt -Encoding UTF8
}

foreach ($dependency in @($job.depends_on)) {
    $dep = @($manifest.jobs | Where-Object { $_.id -eq $dependency }) | Select-Object -First 1
    if ($null -eq $dep -or $dep.status -ne "complete") {
        throw "依赖任务 '$dependency' 尚未通过 QA 并标记 complete；停止运行 '$JobId'。"
    }
}

$inputImages = @()
foreach ($entry in @($job.input_images)) {
    $imagePath = Resolve-RunPath $entry.path
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "缺少输入图（$($entry.role)）：$imagePath"
    }
    $inputImages += $imagePath
}

$outputPath = Resolve-RunPath $job.output_path
if ((Test-Path -LiteralPath $outputPath) -and -not $Force) {
    throw "输出文件已存在：$outputPath。若确认要覆盖，请加 -Force。"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath), $ReportDir | Out-Null

if (-not $DryRun) {
    if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        throw "未检测到 OPENAI_API_KEY。请在本机安全地设置新密钥后重试；不要把密钥粘贴到聊天或写入脚本。"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_BASE_URL) -and -not $AllowCustomEndpoint) {
        $endpointHost = "unknown"
        try { $endpointHost = ([uri]$env:OPENAI_BASE_URL).Host } catch { }
        throw "检测到自定义 OPENAI_BASE_URL（主机：$endpointHost）。此前的中转鉴权失败；确认该端点可用后，显式加 -AllowCustomEndpoint 再运行。"
    }
}

# Keep CLI dependencies local to this project without printing or persisting credentials.
$env:PYTHONPATH = Join-Path $PSScriptRoot "pylibs"
$env:PYTHONIOENCODING = "utf-8"

$cliMode = if ($job.kind -eq "base-pet") { "generate" } else { "edit" }
$size = if ($job.kind -eq "base-pet") { "1024x1536" } else { "1536x512" }
$arguments = @(
    $cliMode,
    "--model", $Model,
    "--prompt-file", $effectivePromptPath,
    "--size", $size,
    "--quality", "high",
    "--output-format", "png",
    "--out", $outputPath,
    "--no-augment"
)
foreach ($imagePath in $inputImages) { $arguments += @("--image", $imagePath) }
if ($DryRun) { $arguments += "--dry-run" }
if ($Force) { $arguments += "--force" }

Write-Host "任务：$JobId  模式：$cliMode  画布：$size"
Write-Host "输出：$outputPath"
Write-Host "输入参考图：$($inputImages.Count) 张"

$result = Invoke-PythonScript $CliPath $arguments
$retried = $false
if ($result.ExitCode -ne 0 -and -not $DryRun -and $result.Text -match "(?i)bad request") {
    $retryRelative = $job.retry_prompt_file
    if (-not [string]::IsNullOrWhiteSpace($retryRelative)) {
        $retryPrompt = Resolve-RunPath $retryRelative
        if (Test-Path -LiteralPath $retryPrompt -PathType Leaf) {
            Write-Warning "收到 Bad Request；按技能要求用同一组参考图重试一次精简提示词。"
            $retryEffectivePrompt = $retryPrompt
            if ($JobId -like "look-*") {
                $retryEffectivePrompt = Join-Path $ReportDir ($JobId + "-retry-prompt.md")
                $retryText = (Get-Content -LiteralPath $retryPrompt -Raw -Encoding UTF8).TrimEnd() +
                    "`n`nPET-SPECIFIC LOOK MECHANICS (authoritative):`n" +
                    (Get-Content -LiteralPath $lookMechanicsPath -Raw -Encoding UTF8).Trim()
                Set-Content -LiteralPath $retryEffectivePrompt -Value $retryText -Encoding UTF8
            }
            $effectivePromptPath = $retryEffectivePrompt
            $retryArgs = @($arguments)
            $promptIndex = [Array]::IndexOf([string[]]$retryArgs, "--prompt-file")
            if ($promptIndex -ge 0 -and $promptIndex + 1 -lt $retryArgs.Count) { $retryArgs[$promptIndex + 1] = $retryEffectivePrompt }
            $result = Invoke-PythonScript $CliPath $retryArgs
            $retried = $true
        }
    }
}

if ($result.ExitCode -ne 0) {
    # Preserve only a bounded, redacted diagnostic so API/auth failures can be debugged
    # without exposing a key or changing the job's pending status.
    $errorLines = [string[]]($result.Text -split '\r?\n' | Select-Object -Last 80)
    $diagnosticText = [string]::Join([Environment]::NewLine, $errorLines)
    $diagnosticText = $diagnosticText -replace '(?i)\bsk-[A-Za-z0-9_-]{12,}\b', '[REDACTED_API_KEY]'
    $diagnosticText = $diagnosticText -replace '(?i)\bsk-[A-Za-z0-9_-]{3,}\*+[A-Za-z0-9_-]*\b', '[REDACTED_API_KEY]'
    $diagnosticText = $diagnosticText -replace '(?im)(Authorization\s*:\s*Bearer\s+)[^\s,;]+', '$1[REDACTED]'
    $diagnosticText = $diagnosticText -replace '(?im)(OPENAI_API_KEY\s*[=:]\s*)[^\s,;]+', '$1[REDACTED]'
    $diagnosticText = $diagnosticText -replace '(?im)(api[_-]?key\s*[=:]\s*)[^\s,;]+', '$1[REDACTED]'
    $diagnosticStamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $diagnosticPath = Join-Path $ReportDir ($JobId + '-cli-error-' + $diagnosticStamp + '.log')
    Set-Content -LiteralPath $diagnosticPath -Value $diagnosticText -Encoding UTF8
    throw "imagegen CLI 失败（exit $($result.ExitCode)）。未修改任务完成状态；脱敏诊断已保存：$diagnosticPath"
}
if (-not $DryRun -and -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "CLI 返回成功但没有生成文件：$outputPath"
}

$qaOutputs = @()
if (-not $DryRun -and $job.kind -eq "row-strip" -and $JobId -notlike "look-row-*") {
    # Incremental standard-row QA: extract the just-generated row and run the bundled inspector.
    $rowQaRoot = Join-Path $RunDir "qa\rows\$JobId"
    $rowFrames = Join-Path $rowQaRoot "frames"
    $rowReview = Join-Path $rowQaRoot "review.json"
    New-Item -ItemType Directory -Force -Path $rowQaRoot | Out-Null
    Invoke-HatchScript "extract_strip_frames.py" @(
        "--decoded-dir", $OutputRoot,
        "--output-dir", $rowFrames,
        "--states", $JobId,
        "--method", "auto"
    ) | Out-Null
    Invoke-HatchScript "inspect_frames.py" @(
        "--frames-root", $rowFrames,
        "--json-out", $rowReview,
        "--states", $JobId,
        "--require-components"
    ) | Out-Null
    $qaOutputs += $rowReview
}
elseif (-not $DryRun -and $JobId -eq "look-cardinals") {
    # Extract candidate anchors, but deliberately do not name or treat them as approved.
    $request = Get-Content -LiteralPath (Join-Path $RunDir "pet_request.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $anchorsDir = Join-Path $OutputRoot "look-anchors"
    $anchorReport = Join-Path $RunDir "qa\cardinal-anchors.json"
    $candidateStrip = Join-Path $OutputRoot "look-anchors-candidate.png"
    Invoke-HatchScript "extract_cardinal_anchors.py" @(
        "--strip", $outputPath,
        "--output-dir", $anchorsDir,
        "--chroma-key", $request.chroma_key.hex,
        "--json-out", $anchorReport
    ) | Out-Null
    Invoke-HatchScript "compose_cardinal_anchor_strip.py" @(
        "--anchors-dir", $anchorsDir,
        "--output", $candidateStrip
    ) | Out-Null
    $cardinalTemplate = Join-Path $RunDir "qa\cardinal-semantics-template.json"
    Write-SemanticsTemplate $cardinalTemplate @(
        @{ degree = "000"; expected = "up"; horizontal = "not_required"; vertical = "up" },
        @{ degree = "090"; expected = "screen-right"; horizontal = "screen-right"; vertical = "not_required" },
        @{ degree = "180"; expected = "down"; horizontal = "not_required"; vertical = "down" },
        @{ degree = "270"; expected = "screen-left"; horizontal = "screen-left"; vertical = "not_required" }
    )
    $qaOutputs += @($anchorReport, $candidateStrip, $cardinalTemplate)
}
elseif (-not $DryRun -and $JobId -eq "look-row-9") {
    $baseAtlas = Resolve-RunPath "final\spritesheet.webp"
    $neutralCell = Resolve-RunPath "frames\idle\00.png"
    if (-not (Test-Path -LiteralPath $baseAtlas) -or -not (Test-Path -LiteralPath $neutralCell)) {
        throw "look-row-9 已生成，但缺少标准 8x9 atlas 或 idle/00.png；先完成标准帧 QA 与 compose_atlas。"
    }
    $request = Get-Content -LiteralPath (Join-Path $RunDir "pet_request.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $registered = Join-Path $RunDir "qa\look-row-9-registered.png"
    $registration = Join-Path $RunDir "qa\look-row-9-registration.json"
    Invoke-HatchScript "assemble_extended_atlas.py" @(
        "--base-atlas", $baseAtlas,
        "--look-row-9", $outputPath,
        "--neutral-cell", $neutralCell,
        "--chroma-key", $request.chroma_key.hex,
        "--chroma-threshold", "96",
        "--registered-row-output", $registered,
        "--registration-manifest-output", $registration
    ) | Out-Null
    $row9Template = Join-Path $RunDir "qa\look-row-9-semantics-template.json"
    Write-SemanticsTemplate $row9Template @(
        @{ degree = "000"; expected = "up"; horizontal = "not_required"; vertical = "up" },
        @{ degree = "022.5"; expected = "up-right"; horizontal = "screen-right"; vertical = "up" },
        @{ degree = "045"; expected = "up-right"; horizontal = "screen-right"; vertical = "up" },
        @{ degree = "067.5"; expected = "up-right"; horizontal = "screen-right"; vertical = "up" },
        @{ degree = "090"; expected = "screen-right"; horizontal = "screen-right"; vertical = "not_required" },
        @{ degree = "112.5"; expected = "down-right"; horizontal = "screen-right"; vertical = "down" },
        @{ degree = "135"; expected = "down-right"; horizontal = "screen-right"; vertical = "down" },
        @{ degree = "157.5"; expected = "down-right"; horizontal = "screen-right"; vertical = "down" }
    )
    $qaOutputs += @($registered, $registration, $row9Template)
}
elseif (-not $DryRun -and $JobId -eq "look-row-10") {
    $baseAtlas = Resolve-RunPath "final\spritesheet.webp"
    $registered = Join-Path $RunDir "qa\look-row-9-registered.png"
    $registration = Join-Path $RunDir "qa\look-row-9-registration.json"
    $neutralCell = Resolve-RunPath "frames\idle\00.png"
    foreach ($required in @($baseAtlas, $registered, $registration, $neutralCell)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "look-row-10 缺少前置 QA 资源：$required" }
    }
    $request = Get-Content -LiteralPath (Join-Path $RunDir "pet_request.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $candidatePng = Resolve-RunPath "final\spritesheet-extended-candidate.png"
    $candidateWebp = Resolve-RunPath "final\spritesheet-extended-candidate.webp"
    $candidateManifest = Resolve-RunPath "final\spritesheet-extended-candidate.json"
    Invoke-HatchScript "assemble_extended_atlas.py" @(
        "--base-atlas", $baseAtlas,
        "--registered-row-9", $registered,
        "--row-9-registration", $registration,
        "--look-row-10", $outputPath,
        "--neutral-cell", $neutralCell,
        "--chroma-key", $request.chroma_key.hex,
        "--chroma-threshold", "96",
        "--output", $candidatePng,
        "--webp-output", $candidateWebp,
        "--manifest-output", $candidateManifest
    ) | Out-Null
    $candidateDirectionSheet = Join-Path $RunDir "qa\look-directions-candidate.png"
    Invoke-HatchScript "make_direction_qa_sheet.py" @($candidateWebp, "--output", $candidateDirectionSheet) | Out-Null
    $row10Template = Join-Path $RunDir "qa\look-row-10-semantics-template.json"
    Write-SemanticsTemplate $row10Template @(
        @{ degree = "180"; expected = "down"; horizontal = "not_required"; vertical = "down" },
        @{ degree = "202.5"; expected = "down-left"; horizontal = "screen-left"; vertical = "down" },
        @{ degree = "225"; expected = "down-left"; horizontal = "screen-left"; vertical = "down" },
        @{ degree = "247.5"; expected = "down-left"; horizontal = "screen-left"; vertical = "down" },
        @{ degree = "270"; expected = "screen-left"; horizontal = "screen-left"; vertical = "not_required" },
        @{ degree = "292.5"; expected = "up-left"; horizontal = "screen-left"; vertical = "up" },
        @{ degree = "315"; expected = "up-left"; horizontal = "screen-left"; vertical = "up" },
        @{ degree = "337.5"; expected = "up-left"; horizontal = "screen-left"; vertical = "up" }
    )
    $qaOutputs += @($candidatePng, $candidateWebp, $candidateManifest, $candidateDirectionSheet, $row10Template)
}

if (-not $DryRun -and $JobId -eq "base") {
    Write-Warning "base 候选已生成；请先视觉审核，再复制到 references/canonical-base.png 并标记 manifest complete。"
}

$reportPath = Join-Path $ReportDir ($JobId + ".json")
$report = [ordered]@{
    job_id = $JobId
    mode = $cliMode
    dry_run = [bool]$DryRun
    retried_bad_request = $retried
    output_path = $outputPath
    prompt_path = $promptPath
    effective_prompt_path = $effectivePromptPath
    input_images = $inputImages
    qa_outputs = $qaOutputs
    cli_exit_code = $result.ExitCode
    completed_at = (Get-Date).ToUniversalTime().ToString("o")
    note = if ($DryRun) { "CLI 参数预检；未调用图像 API。" } else { "必须完成技能规定的视觉审核后再复制 canonical base / 手动更新 imagegen-jobs.json；脚本不会自动标记 complete。" }
}
$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($DryRun) {
    Write-Host "Dry-run 完成；没有调用 API，也没有把任务标记为 complete。报告：$reportPath"
} else {
    Write-Host "图像已写入 decoded；仍需执行对应帧提取/QA并人工审核，脚本不会自动标记 complete。报告：$reportPath"
}
