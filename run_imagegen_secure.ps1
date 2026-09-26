[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "base", "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review", "look-cardinals",
        "look-row-9", "look-row-10"
    )]
    [string]$JobId,

    # 可选：OpenAI 兼容的自定义端点（例如中转站）。地址不是密钥，可以直接作为参数传入。
    [string]$BaseUrl,

    # 可选：图像模型名，默认 gpt-image-2。
    [string]$Model = "gpt-image-2",

    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "run_imagegen_job.ps1"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "找不到 CLI 运行器：$runner" }

$useRelay = -not [string]::IsNullOrWhiteSpace($BaseUrl)
if ($useRelay) {
    $parsed = $null
    if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsed)) {
        throw "BaseUrl 不是合法的绝对地址：$BaseUrl"
    }
    if ($parsed.Scheme -ne "https") { throw "拒绝非 https 端点，避免密钥明文外发：$($parsed.Scheme)" }
    if ([string]::IsNullOrWhiteSpace($parsed.Host)) { throw "BaseUrl 缺少主机名：$BaseUrl" }
    Write-Warning "将使用自定义端点：$($parsed.Host)。提示词与密钥都会经过该第三方服务，请确认你信任它。"
}
elseif (-not [string]::IsNullOrWhiteSpace($env:OPENAI_BASE_URL)) {
    throw "检测到自定义 OPENAI_BASE_URL；如确实要使用该端点，请用 -BaseUrl 显式指定，避免误发到未知中转。"
}

$runnerArgs = @{ JobId = $JobId; Force = $Force; Model = $Model }
if ($DryRun) { $runnerArgs["DryRun"] = $true }
if ($useRelay) { $runnerArgs["AllowCustomEndpoint"] = $true }

# 只恢复本次改动过的环境变量，绝不动用户自己设置的内容。
$previousBaseUrl = $env:OPENAI_BASE_URL
$keySetByThisScript = $false
$secure = $null
$pointer = [IntPtr]::Zero
$plainText = $null

try {
    if ($useRelay) { $env:OPENAI_BASE_URL = $BaseUrl }

    if ($DryRun) {
        & $runner @runnerArgs
        return
    }

    # 当前进程已有密钥：直接使用，不提示、不保存、也不清除（可能是用户自己设置的）。
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        Write-Host "使用当前进程中已有的 API key（不提示、不写入项目文件）。"
        & $runner @runnerArgs
        return
    }

    $promptText = if ($useRelay) {
        "API key（$($parsed.Host) 签发；输入隐藏，不会保存到项目文件）"
    }
    else {
        "OpenAI API key（输入隐藏，不会保存到项目文件）"
    }
    $secure = Read-Host -Prompt $promptText -AsSecureString
    if ($null -eq $secure -or $secure.Length -lt 20) { throw "输入为空或长度异常；未发起图像请求。" }
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($plainText)) { throw "密钥读取为空；未发起图像请求。" }

    # 密钥只存在于当前 PowerShell 进程环境里，用完即清。
    $env:OPENAI_API_KEY = $plainText
    $keySetByThisScript = $true
    & $runner @runnerArgs
}
finally {
    if ($keySetByThisScript) { Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue }
    if ($useRelay) {
        if ([string]::IsNullOrWhiteSpace($previousBaseUrl)) { Remove-Item Env:OPENAI_BASE_URL -ErrorAction SilentlyContinue }
        else { $env:OPENAI_BASE_URL = $previousBaseUrl }
    }
    if ($pointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ($null -ne $secure) { $secure.Dispose() }
    $plainText = $null
}
