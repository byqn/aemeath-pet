# 试水：只生成一张修正版 base（高马尾 + 脑后水晶翼饰），不碰任何已批准的素材。
#
# 输出到 decoded/base-ponytail-test.png，不覆盖 decoded/base.png，
# 也不修改 imagegen-jobs.json 的任何任务状态。
#
# 用法：.\try_base_ponytail.ps1
# 密钥在隐藏提示里输入，只存在于本进程内存，跑完即清。

[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://code0.ai/v1',
    [string]$Model = 'gpt-image-2',
    [string]$Python = $(if ($env:DSH_PYTHON) { $env:DSH_PYTHON } else { "C:\Users\32022\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" })
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$runDir = Join-Path $root 'work\aemeath-run'
$promptPath = Join-Path $runDir 'prompts\base-ponytail-test.md'
$outputPath = Join-Path $runDir 'decoded\base-ponytail-test.png'
$cliPath = Join-Path $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }) 'skills\.system\imagegen\scripts\image_gen.py'

foreach ($required in @($promptPath, $cliPath, $Python)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少文件：$required" }
}
if (Test-Path -LiteralPath $outputPath) { throw "已存在 $outputPath；先移走再跑，避免覆盖。" }

$parsed = $null
if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsed)) { throw "BaseUrl 不合法：$BaseUrl" }
if ($parsed.Scheme -ne 'https') { throw "拒绝非 https 端点" }
Write-Warning "将使用端点 $($parsed.Host)；提示词与密钥都会经过该第三方。"

Write-Host ''
Write-Host '本次只生成 1 张，输出到：' -ForegroundColor Cyan
Write-Host "  $outputPath"
Write-Host '不会覆盖 decoded\base.png，也不会改动任务清单。' -ForegroundColor Cyan
Write-Host ''

$secure = $null
$pointer = [IntPtr]::Zero
$plain = $null
$previousBase = $env:OPENAI_BASE_URL
try {
    $secure = Read-Host -Prompt "API key（$($parsed.Host) 签发；输入隐藏，不会保存）" -AsSecureString
    if ($null -eq $secure -or $secure.Length -lt 12) { throw '输入为空或长度异常；未发起请求。' }
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($plain)) { throw '密钥读取为空；未发起请求。' }

    $env:OPENAI_API_KEY = $plain
    $env:OPENAI_BASE_URL = $BaseUrl
    $env:PYTHONPATH = Join-Path $root 'pylibs'
    $env:PYTHONIOENCODING = 'utf-8'

    $arguments = @(
        'generate',
        '--model', $Model,
        '--prompt-file', $promptPath,
        '--size', '1024x1536',
        '--quality', 'high',
        '--output-format', 'png',
        '--out', $outputPath,
        '--no-augment'
    )
    Write-Host '正在生成，通常需要一到几分钟…' -ForegroundColor Yellow
    & $Python $cliPath @arguments
    if ($LASTEXITCODE -ne 0) { throw "imagegen CLI 失败（exit $LASTEXITCODE）" }
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "CLI 返回成功但没有生成文件：$outputPath" }

    $file = Get-Item -LiteralPath $outputPath
    Write-Host ''
    Write-Host "生成成功：$($file.FullName)（$([math]::Round($file.Length / 1KB)) KB）" -ForegroundColor Green
    Write-Host '这只是候选：已批准的 base 与全部动作行都没有被改动。' -ForegroundColor Green
}
finally {
    Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($previousBase)) { Remove-Item Env:OPENAI_BASE_URL -ErrorAction SilentlyContinue }
    else { $env:OPENAI_BASE_URL = $previousBase }
    if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ($null -ne $secure) { $secure.Dispose() }
    $plain = $null
}
