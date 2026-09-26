[CmdletBinding()]
param(
    # 中转地址；只读查询模型列表，不生成任何图片、不产生费用。
    [string]$BaseUrl = "https://code0.ai/v1",

    # 只打印名称里含该关键字（不区分大小写）的模型；留空则打印全部。
    [string]$Filter = "image"
)

$ErrorActionPreference = "Stop"

$parsed = $null
if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$parsed)) { throw "BaseUrl 不是合法地址：$BaseUrl" }
if ($parsed.Scheme -ne "https") { throw "拒绝非 https 端点：$($parsed.Scheme)" }

Write-Host "=== 中转模型探测（只读，不生成图片，不产生费用）===" -ForegroundColor Cyan
Write-Host "端点：$BaseUrl"

$secure = $null
$pointer = [IntPtr]::Zero
$plainText = $null
$keySet = $false

try {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        Write-Host "使用当前进程中已有的 API key。" -ForegroundColor DarkGray
    }
    else {
        $secure = Read-Host -Prompt "API key（$($parsed.Host) 签发；输入隐藏，不会保存）" -AsSecureString
        if ($null -eq $secure -or $secure.Length -lt 12) { throw "输入为空或长度异常；未发起请求。" }
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plainText)) { throw "密钥读取为空；未发起请求。" }
        $env:OPENAI_API_KEY = $plainText
        $keySet = $true
    }

    $headers = @{ Authorization = "Bearer $($env:OPENAI_API_KEY)" }
    $response = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + "/models") -Headers $headers -Method GET -TimeoutSec 60

    $ids = @($response.data | ForEach-Object { $_.id }) | Sort-Object -Unique
    Write-Host ""
    Write-Host "模型总数：$($ids.Count)"

    $matched = if ([string]::IsNullOrWhiteSpace($Filter)) { $ids } else { @($ids | Where-Object { $_ -match [regex]::Escape($Filter) }) }
    Write-Host "匹配 `"$Filter`" 的模型（$($matched.Count) 个）：" -ForegroundColor Green
    $matched | ForEach-Object { Write-Host "  $_" }

    $twoFive = @($ids | Where-Object { $_ -match 'image' -and $_ -match '2\.5|2-5' })
    Write-Host ""
    if ($twoFive.Count -gt 0) {
        Write-Host "发现 2.5 代图像模型：" -ForegroundColor Green
        $twoFive | ForEach-Object { Write-Host "  $_" }
    }
    else {
        Write-Host "未发现 2.5 代图像模型；该中转大概率只有 gpt-image-2 及更早版本。" -ForegroundColor Yellow
    }

    # 落盘一份结果（只有模型名，不含任何密钥），方便后续排查时直接读取。
    $reportDir = Join-Path $PSScriptRoot "work\aemeath-run\qa"
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $reportPath = Join-Path $reportDir "relay-models.json"
    [ordered]@{
        base_url            = $BaseUrl
        queried_at          = [DateTime]::UtcNow.ToString("o")
        model_count         = $ids.Count
        image_models        = @($ids | Where-Object { $_ -match "image" })
        image_models_25     = $twoFive
        has_image_25        = ($twoFive.Count -gt 0)
        secrets_written     = $false
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host "结果已保存：$reportPath" -ForegroundColor DarkGray
}
finally {
    if ($keySet) { Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue }
    if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ($null -ne $secure) { $secure.Dispose() }
    $plainText = $null
}
