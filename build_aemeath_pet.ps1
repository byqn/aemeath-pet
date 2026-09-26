[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$DryRun,
    [switch]$SkipPackage,

    # 可选：OpenAI 兼容的自定义端点（中转）。地址不是密钥，可直接传参。
    [string]$BaseUrl,

    # 图像模型名，默认 gpt-image-2。
    [string]$Model = "gpt-image-2",

    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" })
)

# 爱弥斯 v2 桌宠端到端编排：生成 -> 组装标准行 -> v2 QA -> 打包。
# 刻意不做的事：不自动批准任务、不把密钥写入任何文件、不在缺少素材时伪造产物。
# 密钥只在本次进程内存里存活，整条链跑完立即清除。
# 退出码：0 = 请求的阶段已全部走完（或仅计划/演练）；3 = 仍在等待素材或人工审核；1 = 出错。

$ErrorActionPreference = "Stop"
$RunDir = Join-Path $PSScriptRoot "work\aemeath-run"
$ManifestPath = Join-Path $RunDir "imagegen-jobs.json"
$FinalDir = Join-Path $RunDir "final"
$AtlasPath = Join-Path $FinalDir "spritesheet-extended.webp"
$ZipPath = Join-Path $PSScriptRoot "deliverable\aemeath-pet-v2.zip"
$JobScript = Join-Path $PSScriptRoot "run_imagegen_job.ps1"
$AssembleScript = Join-Path $PSScriptRoot "assemble_standard_pet.ps1"
$FinalizeScript = Join-Path $PSScriptRoot "finalize_v2_qa.ps1"
$PackageScript = Join-Path $PSScriptRoot "package_v2_pet.ps1"

$StandardStates = @("idle", "running-right", "running-left", "waving", "jumping", "failed", "waiting", "running", "review")
$LookStates = @("look-cardinals", "look-row-9", "look-row-10")

function Get-Manifest {
    return Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-JobEntry([object]$Manifest, [string]$JobId) {
    return @($Manifest.jobs | Where-Object { $_.id -eq $JobId }) | Select-Object -First 1
}

function Get-JobStates([object]$Manifest) {
    $states = [ordered]@{}
    foreach ($job in $Manifest.jobs) {
        $depsComplete = $true
        foreach ($depId in @($job.depends_on)) {
            $dep = Get-JobEntry $Manifest $depId
            if ($null -eq $dep -or $dep.status -ne "complete") { $depsComplete = $false }
        }
        $outputPath = [System.IO.Path]::GetFullPath((Join-Path $RunDir $job.output_path))
        $hasOutput = Test-Path -LiteralPath $outputPath -PathType Leaf
        $state = if ($job.status -eq "complete") { "complete" }
            elseif (-not $depsComplete) { "blocked" }
            elseif ($hasOutput) { "awaiting-approval" }
            else { "ready" }
        $states[$job.id] = [pscustomobject]@{
            Id           = $job.id
            Dependencies = @($job.depends_on)
            State        = $state
            OutputPath   = $outputPath
        }
    }
    return $states
}

function Test-AllComplete([object]$Manifest, [string[]]$JobIds) {
    foreach ($jobId in $JobIds) {
        $job = Get-JobEntry $Manifest $jobId
        if ($null -eq $job -or $job.status -ne "complete") { return $false }
    }
    return $true
}

function Show-Plan([object]$Manifest, [object]$States) {
    Write-Host "计划（严格按依赖顺序，审核永不自动跳过）：" -ForegroundColor Cyan
    foreach ($job in $Manifest.jobs) {
        $info = $States[$job.id]
        $depText = if ($info.Dependencies.Count -gt 0) { $info.Dependencies -join "," } else { "无" }
        Write-Host ("  {0,-14} 依赖={1,-60} 状态={2}" -f $info.Id, $depText, $info.State)
    }
    Write-Host ""
    Write-Host "阶段 2 组装标准行：需要 9 个标准行全部 complete"
    Write-Host "阶段 3 v2 QA：需要 13 项全部 complete"
    Write-Host "阶段 4 打包：需要 13 项 complete 且 QA 产物齐备"
}

Write-Host "=== 爱弥斯 v2 桌宠构建 ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "找不到任务清单：$ManifestPath" }
foreach ($script in @($JobScript, $AssembleScript, $FinalizeScript, $PackageScript)) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "缺少流程脚本：$script" }
}

$manifest = Get-Manifest
$states = Get-JobStates $manifest
Show-Plan $manifest $states

if ($PlanOnly) {
    Write-Host "仅计划模式：未执行任何生成或打包，也未调用任何 API。" -ForegroundColor Yellow
    exit 0
}

# ── 中转与密钥：整条链只输一次，密钥只存在于本进程内存，结束即清 ──
$useRelay = -not [string]::IsNullOrWhiteSpace($BaseUrl)
$previousBaseUrl = $env:OPENAI_BASE_URL
$keySetHere = $false
$secureKey = $null
$keyPointer = [IntPtr]::Zero
$keyPlain = $null
$relayHost = ""

if ($useRelay) {
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsedUri)) { throw "BaseUrl 不是合法地址：$BaseUrl" }
    if ($parsedUri.Scheme -ne "https") { throw "拒绝非 https 端点：$($parsedUri.Scheme)" }
    $relayHost = $parsedUri.Host
    Write-Warning "使用自定义端点：$relayHost；提示词与密钥都会经过该第三方服务。"
}

try {
    if ($useRelay) { $env:OPENAI_BASE_URL = $BaseUrl }

    if (-not $DryRun -and [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        $promptText = if ($useRelay) { "API key（$relayHost 签发；整条链只输一次，输入隐藏，不写入任何文件）" } else { "OpenAI API key（整条链只输一次，输入隐藏）" }
        $secureKey = Read-Host -Prompt $promptText -AsSecureString
        if ($null -eq $secureKey -or $secureKey.Length -lt 12) { throw "输入为空或长度异常；未发起任何请求。" }
        $keyPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $keyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        if ([string]::IsNullOrWhiteSpace($keyPlain)) { throw "密钥读取为空；未发起任何请求。" }
        $env:OPENAI_API_KEY = $keyPlain
        $keySetHere = $true
        Write-Host "密钥已载入本进程内存；整条链结束后自动清除。" -ForegroundColor DarkGray
    }

# ── 阶段 1：生成（逐项依赖推进，遇到失败立即停下）──
Write-Host ""
Write-Host "=== 阶段 1：视觉素材生成 ===" -ForegroundColor Cyan

$generatedThisRun = @()
$approvalQueue = @()
while ($true) {
    $manifest = Get-Manifest
    $states = Get-JobStates $manifest
    $ready = @($manifest.jobs | Where-Object { $states[$_.id].State -eq "ready" })

    if ($ready.Count -eq 0) { break }

    foreach ($job in $ready) {
        if ($DryRun) {
            Write-Host "-> 演练 $($job.id)（不会调用 API）" -ForegroundColor DarkGray
        }
        else {
            Write-Host "-> 生成 $($job.id)" -ForegroundColor Green
        }
        $jobArgs = @{ JobId = $job.id; Python = $Python; Model = $Model }
        if ($DryRun) { $jobArgs["DryRun"] = $true }
        if ($useRelay) { $jobArgs["AllowCustomEndpoint"] = $true }
        & $JobScript @jobArgs
        if (-not $DryRun) { $generatedThisRun += $job.id }
    }

    if ($DryRun) { break }
}

$manifest = Get-Manifest
$states = Get-JobStates $manifest
$approvalQueue = @($manifest.jobs | Where-Object { $states[$_.id].State -eq "awaiting-approval" })

if ($approvalQueue.Count -gt 0) {
    Write-Host ""
    Write-Host "以下任务已产出图像，等待你目视审核后才算完成（我不会代你批准）：" -ForegroundColor Yellow
    foreach ($job in $approvalQueue) {
        Write-Host "  .\approve_imagegen_job.ps1 -JobId $($job.id) -DecisionNote `"<至少12字的目视依据>`" -ConfirmVisualReview"
    }
    Write-Host "未完成审核前，依赖它的任务不会开始。" -ForegroundColor Yellow
}

$buildComplete = $false

# ── 阶段 2：组装标准行 ──
if (Test-AllComplete $manifest $StandardStates) {
    Write-Host ""
    Write-Host "=== 阶段 2：提取帧并组装标准图集 ===" -ForegroundColor Cyan
    & $AssembleScript -Python $Python
}
else {
    $missing = @($StandardStates | Where-Object { (Get-JobEntry $manifest $_).status -ne "complete" })
    Write-Host ""
    Write-Host "阶段 2 跳过：标准行未全部完成（缺：$($missing -join ', ')）" -ForegroundColor DarkGray
}

# ── 阶段 3：v2 QA ──
$allJobs = @("base") + $StandardStates + $LookStates
if (Test-AllComplete $manifest $allJobs) {
    Write-Host ""
    Write-Host "=== 阶段 3：v2 方向与图集 QA ===" -ForegroundColor Cyan
    & $FinalizeScript -Python $Python
}
else {
    Write-Host "阶段 3 跳过：13 项任务未全部完成" -ForegroundColor DarkGray
}

# ── 阶段 4：打包 ──
if ($SkipPackage) {
    Write-Host "已按要求跳过打包。" -ForegroundColor DarkGray
}
elseif (Test-AllComplete $manifest $allJobs) {
    Write-Host ""
    Write-Host "=== 阶段 4：打包交付 ===" -ForegroundColor Cyan
    & $PackageScript
    $buildComplete = Test-Path -LiteralPath $ZipPath -PathType Leaf
}
else {
    Write-Host "阶段 4 跳过：13 项任务未全部完成" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== 结果 ===" -ForegroundColor Cyan
$completedCount = @($manifest.jobs | Where-Object { $_.status -eq "complete" }).Count
Write-Host "任务完成：$completedCount/$($manifest.jobs.Count)"
Write-Host "扩展图集：$(if (Test-Path -LiteralPath $AtlasPath -PathType Leaf) { '已生成' } else { '未生成' })"
Write-Host "交付 ZIP：$(if (Test-Path -LiteralPath $ZipPath -PathType Leaf) { '已生成' } else { '未生成' })"

if ($DryRun) {
    Write-Host "演练模式结束：未调用 API，未生成素材。" -ForegroundColor Yellow
    exit 0
}
if ($buildComplete) {
    Write-Host "构建完成。" -ForegroundColor Green
    exit 0
}
Write-Host "流程尚未走完：等待素材生成与逐项目视审核。" -ForegroundColor Yellow
exit 3
}
finally {
    # 只清除本次自己设置的内容，绝不动用户原有的环境变量。
    if ($keySetHere) { Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue }
    if ($useRelay) {
        if ([string]::IsNullOrWhiteSpace($previousBaseUrl)) { Remove-Item Env:OPENAI_BASE_URL -ErrorAction SilentlyContinue }
        else { $env:OPENAI_BASE_URL = $previousBaseUrl }
    }
    if ($keyPointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer) }
    if ($null -ne $secureKey) { $secureKey.Dispose() }
    $keyPlain = $null
    if ($keySetHere) { Write-Host "密钥已从本进程清除。" -ForegroundColor DarkGray }
}
