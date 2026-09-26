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
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "run_imagegen_job.ps1"
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "找不到 CLI 运行器：$runner" }
if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_BASE_URL)) {
    throw "检测到自定义 OPENAI_BASE_URL；为避免意外发送到未知中转，请在本机当前 PowerShell 中先清除此变量后重试。"
}

if ($DryRun) {
    & $runner -JobId $JobId -DryRun -Force:$Force
    return
}

# If the current PowerShell already has a key, preserve it and do not prompt or clear it.
if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
    & $runner -JobId $JobId -Force:$Force
    return
}

$secure = $null
$pointer = [IntPtr]::Zero
$plainText = $null
try {
    $secure = Read-Host -Prompt "OpenAI API key（输入隐藏，不会保存到项目文件）" -AsSecureString
    if ($null -eq $secure -or $secure.Length -lt 20) { throw "输入为空或长度异常；未发起图像请求。" }
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($plainText)) { throw "密钥读取为空；未发起图像请求。" }

    # The key exists only in this PowerShell process environment for the one CLI task.
    $env:OPENAI_API_KEY = $plainText
    & $runner -JobId $JobId -Force:$Force
}
finally {
    Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    if ($pointer -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    if ($null -ne $secure) { $secure.Dispose() }
    $plainText = $null
}
