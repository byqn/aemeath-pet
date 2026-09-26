[CmdletBinding()]
param(
    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" })
)

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
$CliPath = Join-Path $CodexHome "skills\.system\imagegen\scripts\image_gen.py"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$FallbackImage = Join-Path $PSScriptRoot "hfrun\base-a1.webp"
$ReportPath = Join-Path $RunDir "qa\cli-plan-dryrun.json"
$PromptTempDir = Join-Path $RunDir "qa\cli-plan-dryrun-prompts"

if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "找不到 Python 运行时：$Python" }
if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { throw "找不到 image_gen.py：$CliPath" }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "找不到任务清单：$ManifestPath" }
if (-not (Test-Path -LiteralPath $FallbackImage -PathType Leaf)) { throw "缺少 dry-run 参考占位图：$FallbackImage" }

$env:PYTHONPATH = Join-Path $PSScriptRoot "pylibs"
$env:PYTHONIOENCODING = "utf-8"
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportPath), $PromptTempDir | Out-Null
$results = @()
$errors = @()
$blockers = @()
$usedFallback = $false
$lookMechanicsPath = Join-Path $RunDir "qa\look-mechanics.md"
$hasLookMechanics = Test-Path -LiteralPath $lookMechanicsPath -PathType Leaf

foreach ($job in $manifest.jobs) {
    $isBase = $job.kind -eq "base-pet"
    $mode = if ($isBase) { "generate" } else { "edit" }
    $size = if ($isBase) { "1024x1536" } else { "1536x512" }
    $promptPath = Join-Path $RunDir $job.prompt_file
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        $errors += "$($job.id): missing prompt $($job.prompt_file)"
        continue
    }

    $effectivePrompt = $promptPath
    $lookJob = $job.id -like "look-*"
    if ($lookJob -and $hasLookMechanics) {
        $effectivePrompt = Join-Path $PromptTempDir ($job.id + ".md")
        $promptText = (Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8).TrimEnd() +
            "`n`nPET-SPECIFIC LOOK MECHANICS (authoritative):`n" +
            (Get-Content -LiteralPath $lookMechanicsPath -Raw -Encoding UTF8).Trim()
        Set-Content -LiteralPath $effectivePrompt -Value $promptText -Encoding UTF8
    }

    $outputPath = Join-Path $RunDir $job.output_path
    $cliArgs = @(
        $mode, "--model", "gpt-image-2", "--prompt-file", $effectivePrompt,
        "--size", $size, "--quality", "high", "--output-format", "png",
        "--out", $outputPath, "--no-augment", "--dry-run"
    )
    $fallbackPaths = @()
    if (-not $isBase) {
        foreach ($entry in @($job.input_images)) {
            $resolved = Join-Path $RunDir $entry.path
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                $imagePath = $resolved
            }
            else {
                $imagePath = $FallbackImage
                $fallbackPaths += $entry.path
                $usedFallback = $true
            }
            $cliArgs += @("--image", $imagePath)
        }
    }

    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $text = (& $Python $CliPath @cliArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    $payload = $null
    $start = $text.IndexOf("{")
    if ($start -ge 0) {
        try { $payload = $text.Substring($start) | ConvertFrom-Json } catch { }
    }
    $expectedEndpoint = if ($isBase) { "/v1/images/generations" } else { "/v1/images/edits" }
    $referenceCount = if ($isBase) { 0 } else { @($job.input_images).Count }
    $row = [ordered]@{
        id = $job.id
        mode = $mode
        exit_code = $exitCode
        endpoint = if ($payload) { $payload.endpoint } else { $null }
        expected_endpoint = $expectedEndpoint
        model = if ($payload) { $payload.model } else { $null }
        size = if ($payload) { $payload.size } else { $null }
        reference_count = $referenceCount
        fallback_reference_paths = $fallbackPaths
        look_mechanics_injected = if ($lookJob) { [bool]$hasLookMechanics } else { $null }
        api_called = $false
    }
    $results += $row
    if ($fallbackPaths.Count -gt 0) { $blockers += "$($job.id): placeholder reference paths used" }
    if ($exitCode -ne 0) { $errors += "$($job.id): CLI dry-run exit $exitCode" }
    if (-not $payload -or $payload.endpoint -ne $expectedEndpoint -or $payload.model -ne "gpt-image-2") {
        $errors += "$($job.id): CLI dry-run payload did not match expected endpoint/model"
    }
    if ($lookJob -and -not $hasLookMechanics) { $blockers += "$($job.id): qa/look-mechanics.md is not written yet" }
}

$apiKeyPresent = -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)
if (-not $apiKeyPresent) { $blockers += "OPENAI_API_KEY is absent" }
$report = [ordered]@{
    ok = ($errors.Count -eq 0)
    ready_to_generate = ($errors.Count -eq 0 -and $blockers.Count -eq 0)
    api_key_present = $apiKeyPresent
    api_called = $false
    placeholder_references_used = $usedFallback
    job_count = $results.Count
    results = $results
    errors = $errors
    blockers = $blockers
    note = "CLI payload-only dry-run. ok validates CLI request construction only; blockers prevent production generation and no assets are created or approved."
}
$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host ($report | ConvertTo-Json -Depth 30)
Write-Host "报告：$ReportPath"
if ($errors.Count -gt 0) { exit 1 }
