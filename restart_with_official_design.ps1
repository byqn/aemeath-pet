# 按官方设定重做：把现有成果整包存档，更新角色设定，重置任务状态。
#
# 安全设计：
#  * 先完整复制存档到 archive\official-redesign-<时间戳>\，不删除任何原始文件
#  * 设计相关的产物（decoded / final / frames / 审核记录）会移入存档，
#    因为它们属于旧设计，重做后必须重新生成
#  * -DryRun 只打印计划，不动任何文件
#
# 用法：
#   .\restart_with_official_design.ps1 -DryRun     # 看计划
#   .\restart_with_official_design.ps1             # 真正执行

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$runDir = Join-Path $root 'work\aemeath-run'
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
$archiveRoot = Join-Path $root "archive\official-redesign-$stamp"

# 新的身份描述（按官方角色卡：高马尾 + 脑后水晶翼 + 侧面羽毛夹）
$oldIdentity = 'long pastel-pink hair with soft side locks, small compact translucent cyan crystal hair clips sitting flat against the hair (tiny clip-sized ornaments only, never large wings, never oversized headpieces), warm amber-gold eyes, fair skin,'
$newIdentity = 'pastel-pink hair tied UP into a clear high ponytail with the long tail flowing down behind her, straight soft bangs and two short side locks framing the face (never loose hair hanging down over the shoulders in front), a large translucent pale-cyan crystal wing ornament attached at the base of the ponytail behind her head and spreading out to both sides, plus one small silver-white feather hair clip on the side of the bangs, warm amber-gold eyes with star-shaped highlights, fair skin,'

# 描述句（pet_request.json 里那一句）
$oldDesc = 'with pastel-pink hair, small cyan crystal hair clips, amber-gold eyes,'
$newDesc = 'with a pastel-pink high ponytail, large pale-cyan crystal wing ornaments behind her head, amber-gold eyes,'

# look-mechanics 里描述头发的句子（影响转头行的遮挡逻辑）
$mechOld = '- Long pastel-pink side locks frame both sides of the face. Two small cyan crystal clips sit flat
  against the hair on the upper left and upper right of the head.'
$mechNew = '- The pastel-pink hair is tied up into a high ponytail; straight bangs and two short side locks
  frame the face, and the ponytail tail hangs down behind her.
- A large translucent pale-cyan crystal wing ornament is attached at the base of the ponytail behind
  her head and spreads to both sides, plus one small silver-white feather clip on the side of the bangs.
  Both travel with the head when she turns.'

function Show-Step([string]$Text) {
    Write-Host $(if ($DryRun) { "  [计划] $Text" } else { "  $Text" })
}

Write-Host "=== 按官方设定重做 ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host '（演练模式：不会改动任何文件）' -ForegroundColor Yellow }

foreach ($required in @($runDir, (Join-Path $runDir 'imagegen-jobs.json'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "缺少必要路径：$required" }
}

# ── 1. 整包存档 ──
Write-Host ''
Write-Host '1) 存档现有成果' -ForegroundColor Cyan
Show-Step "复制 $runDir → $archiveRoot\aemeath-run"
Show-Step "复制 app\spritesheet-hires.png → $archiveRoot\app\"
Show-Step "复制 deliverable\*.zip → $archiveRoot\deliverable\"
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    Copy-Item -LiteralPath $runDir -Destination (Join-Path $archiveRoot 'aemeath-run') -Recurse -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $archiveRoot 'app') | Out-Null
    foreach ($f in @('spritesheet-hires.png', 'spritesheet-hires.json')) {
        $src = Join-Path $root "app\$f"
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $archiveRoot "app\$f") -Force }
    }
    $deliverable = Join-Path $root 'deliverable'
    if (Test-Path -LiteralPath $deliverable) {
        New-Item -ItemType Directory -Force -Path (Join-Path $archiveRoot 'deliverable') | Out-Null
        Copy-Item -Path (Join-Path $deliverable '*.zip') -Destination (Join-Path $archiveRoot 'deliverable') -Force -ErrorAction SilentlyContinue
    }
    $size = (Get-ChildItem $archiveRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host "  已存档 $([math]::Round($size / 1MB, 1)) MB → $archiveRoot" -ForegroundColor Green
}

# ── 2. 更新角色设定 ──
Write-Host ''
Write-Host '2) 更新角色设定（高马尾 + 脑后水晶翼 + 羽毛夹）' -ForegroundColor Cyan
$enc = New-Object System.Text.UTF8Encoding($false)
$changedFiles = @()
Get-ChildItem -LiteralPath $runDir -Recurse -File -Include '*.md', '*.json' | ForEach-Object {
    $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    if (-not $text) { return }
    $before = $text
    $text = $text.Replace($oldIdentity, $newIdentity).Replace($oldDesc, $newDesc).Replace($mechOld.Replace("`n", [Environment]::NewLine), $mechNew.Replace("`n", [Environment]::NewLine))
    # look-mechanics 的文件是 LF，两种换行都试一次
    $text = $text.Replace($oldIdentity, $newIdentity).Replace($oldDesc, $newDesc)
    if ($text -ne $before) {
        if (-not $DryRun) { [System.IO.File]::WriteAllText($_.FullName, $text, $enc) }
        $changedFiles += $_.FullName.Substring($runDir.Length + 1)
    }
}
Show-Step "会改写 $($changedFiles.Count) 个文件："
$changedFiles | ForEach-Object { Write-Host "    $_" }
if (-not $DryRun) {
    $left = @(Get-ChildItem -LiteralPath $runDir -Recurse -File -Include '*.md', '*.json' | Where-Object {
        $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $t -and ($t.Contains('soft side locks') -or $t.Contains('crystal hair clips'))
    })
    Write-Host "  残留旧设定的文件：$($left.Count)" -ForegroundColor $(if ($left.Count -gt 0) { 'Yellow' } else { 'Green' })
}

# ── 3. 重置任务状态 ──
Write-Host ''
Write-Host '3) 重置 13 项任务状态为 pending' -ForegroundColor Cyan
$manifestPath = Join-Path $runDir 'imagegen-jobs.json'
$manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
foreach ($job in $manifest.jobs) {
    $job.status = 'pending'
    foreach ($field in @('source_path', 'completed_at', 'review_note')) {
        if ($job.PSObject.Properties[$field]) { $job.PSObject.Properties.Remove($field) }
    }
}
Show-Step "base / idle / ... / look-row-10 共 $($manifest.jobs.Count) 项 → pending"
if (-not $DryRun) {
    $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

# ── 4. 移走旧设计产物 ──
Write-Host ''
Write-Host '4) 把旧设计产物移入存档（不删除）' -ForegroundColor Cyan
$moveTargets = @('decoded', 'final', 'frames', 'qa\rows', 'qa\previews')
$moveTargets += (Get-ChildItem -LiteralPath (Join-Path $runDir 'qa') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(contact-sheet|look-directions|direction-blind|cardinal-|chroma-despill|validation|look-row-9-|look-row-10-|direction-semantics|final-visual-qa|look-continuity|review\.json|standard-stage|run-summary)' } |
    ForEach-Object { "qa\$($_.Name)" })
foreach ($rel in $moveTargets) {
    $src = Join-Path $runDir $rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Show-Step "移动 $rel → 存档"
    if (-not $DryRun) {
        $dst = Join-Path $archiveRoot "moved\$rel"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Move-Item -LiteralPath $src -Destination $dst -Force
    }
}
if (-not $DryRun) {
    foreach ($dir in @('decoded', 'final', 'frames')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $runDir $dir) | Out-Null
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host '演练结束：没有改动任何文件。' -ForegroundColor Yellow
    exit 0
}
Write-Host "完成。存档位置：$archiveRoot" -ForegroundColor Green
Write-Host '下一步：重新生成 base（1 张），审核通过后再跑 9 个动作行。' -ForegroundColor Cyan
