# 爱弥斯 v2 桌面宠 —— 双击即用，零安装（依赖 Windows 自带的 WPF）
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File AemeathPet.ps1
#   或直接双击「启动爱弥斯.vbs」
#
# 交互：
#   拖动            移动位置，并播放朝左/朝右的跑动
#   单击            挥手打招呼
#   右键            菜单：动作 / 自由活动 / 声音 / 说话 / 退出
#   鼠标移动        她会用 16 个方向里的对应方向看向你的鼠标
#   什么都不做      她会自己在屏幕底部走来走去，偶尔挥手、跳跃、发呆

[CmdletBinding()]
param(
    [double]$Scale = 2.0,
    # 各状态帧间隔（毫秒）。待机慢而稳；走动与跟随鼠标要快，否则看起来一顿一顿。
    [int]$IdleFrameMs = 150,
    [int]$LookFrameMs = 90,
    [int]$RunFrameMs = 80,
    [int]$OneShotFrameMs = 110,
    # 自由活动
    [switch]$NoRoam,
    [int]$WalkSpeed = 6,
    [switch]$Mute,
    [switch]$NoAi,
    [switch]$SelfTest,
    [int]$PerfTest = 0,
    # 命令行验证 AI 接线：发一次真实请求并打印结果，不开界面
    [switch]$TestAi,
    [string]$TestAiPrompt = '用一句话打个招呼'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hiresAtlas = Join-Path $scriptRoot 'spritesheet-hires.png'
$plainAtlas = Join-Path $scriptRoot 'spritesheet.png'
# 优先用高清图集：它是从原始条带重建的，细节比交付图集多得多
$atlasPath = if (Test-Path -LiteralPath $hiresAtlas -PathType Leaf) { $hiresAtlas } else { $plainAtlas }
$soundDir = Join-Path $scriptRoot 'sounds'
$logPath = Join-Path $scriptRoot 'aemeath-pet.log'

function Write-Log([string]$Message) {
    try { "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8 } catch { }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    # PowerShell 5.1 默认不加载 System.Net.Http，AI 请求需要它
    Add-Type -AssemblyName System.Net.Http

    if (-not (Test-Path -LiteralPath $atlasPath -PathType Leaf)) { throw "找不到图集：$atlasPath" }

    # 交付格式固定 192x208 一格；高清图集是它的整数倍，按实际尺寸自动推导每格大小
    $BaseCellW = 192
    $BaseCellH = 208
    $RowIdle = 0; $RowRight = 1; $RowLeft = 2; $RowWave = 3; $RowJump = 4
    $RowFail = 5; $RowWait = 6; $RowWork = 7; $RowReview = 8

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = New-Object System.Uri($atlasPath)
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()
    if ($bitmap.PixelWidth % 8 -ne 0 -or $bitmap.PixelHeight % 11 -ne 0) {
        throw "图集尺寸异常：$($bitmap.PixelWidth)x$($bitmap.PixelHeight)，应为 8x11 格"
    }
    $CellWidth = [int]($bitmap.PixelWidth / 8)
    $CellHeight = [int]($bitmap.PixelHeight / 11)

    $cells = New-Object 'object[,]' 11, 8
    for ($r = 0; $r -lt 11; $r++) {
        for ($c = 0; $c -lt 8; $c++) {
            $rect = New-Object System.Windows.Int32Rect(($c * $CellWidth), ($r * $CellHeight), $CellWidth, $CellHeight)
            $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($bitmap, $rect)
            $crop.Freeze()
            $cells[$r, $c] = $crop
        }
    }
    $rowFrames = @{ 0 = 6; 1 = 8; 2 = 8; 3 = 4; 4 = 5; 5 = 8; 6 = 6; 7 = 6; 8 = 6; 9 = 8; 10 = 8 }

    # ── 音效：预先载入，播放时零延迟 ──
    $script:soundOn = -not $Mute
    $players = @{}
    if (Test-Path -LiteralPath $soundDir -PathType Container) {
        foreach ($wav in Get-ChildItem -LiteralPath $soundDir -File -Filter '*.wav') {
            try {
                $player = New-Object System.Media.SoundPlayer($wav.FullName)
                $player.Load()
                $players[$wav.BaseName] = $player
            }
            catch { Write-Log "sound load failed: $($wav.Name) $($_.Exception.Message)" }
        }
    }
    function Play-Sound([string]$Name) {
        if (-not $script:soundOn) { return }
        $player = $players[$Name]
        if ($null -eq $player) { return }
        try { $player.Play() } catch { }
    }

    # ── 语音朗读（Windows 自带，默认关闭）──
    $script:speakOn = $false
    $synth = $null
    try {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.Rate = 0
        $voice = $synth.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'zh*' } | Select-Object -First 1
        if ($voice) { $synth.SelectVoice($voice.VoiceInfo.Name) }
    }
    catch { $synth = $null }
    $lines = @('在的', '需要帮忙吗', '我在这里', '看这里', '好累哦', '加油')
    function Say-Something([string]$Text) {
        if (-not $script:speakOn -or $null -eq $synth) { return }
        try { $synth.SpeakAsync($Text) | Out-Null } catch { }
    }

    # ── 偷吃桌面快捷方式 ──
    # 安全设计：
    #  * 默认只做动画和气泡，完全不碰文件
    #  * “真吃”必须由用户在菜单里显式打开，且只移动桌面顶层目录里的 *.lnk
    #  * 每次移动都记录原始路径，退出时、下次启动时、以及菜单里都能还原
    #  * 绝不删除任何文件；目标重名时改名而不是覆盖
    $script:canEat = $false
    $script:eatRealMode = $false
    $script:bellyDir = Join-Path $scriptRoot 'belly'
    $script:bellyRecord = Join-Path $script:bellyDir 'belly.json'
    $script:desktopDir = [Environment]::GetFolderPath('Desktop')

    function Get-BellyItems {
        if (-not (Test-Path -LiteralPath $script:bellyRecord -PathType Leaf)) { return @() }
        try { return @(Get-Content -LiteralPath $script:bellyRecord -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Log "belly.json 解析失败：$($_.Exception.Message)"; return @() }
    }

    function Save-BellyItems([object[]]$Items) {
        New-Item -ItemType Directory -Force -Path $script:bellyDir | Out-Null
        if ($Items.Count -eq 0) {
            if (Test-Path -LiteralPath $script:bellyRecord) { Remove-Item -LiteralPath $script:bellyRecord -Force }
            return
        }
        $Items | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:bellyRecord -Encoding UTF8
    }

    function Get-DesktopShortcuts {
        if ([string]::IsNullOrWhiteSpace($script:desktopDir)) { return @() }
        if (-not (Test-Path -LiteralPath $script:desktopDir -PathType Container)) { return @() }
        # 只认桌面顶层目录里的 .lnk，不递归、不碰文件夹和其他类型
        return @(Get-ChildItem -LiteralPath $script:desktopDir -File -Filter '*.lnk' -ErrorAction SilentlyContinue)
    }

    function Restore-Belly([switch]$Quiet) {
        $items = Get-BellyItems
        if ($items.Count -eq 0) {
            if (-not $Quiet) { Show-Bubble '她肚子里什么都没有' 4000 }
            return 0
        }
        $restored = 0
        $left = New-Object System.Collections.ArrayList
        foreach ($item in $items) {
            $stored = Join-Path $script:bellyDir $item.stored
            if (-not (Test-Path -LiteralPath $stored -PathType Leaf)) { continue }
            $target = $item.original
            if (Test-Path -LiteralPath $target) {
                # 原位已被占用，改名放回，绝不覆盖
                $dir = Split-Path -Parent $target
                $base = [IO.Path]::GetFileNameWithoutExtension($target)
                $ext = [IO.Path]::GetExtension($target)
                $target = Join-Path $dir ("$base (恢复)$ext")
            }
            try {
                Move-Item -LiteralPath $stored -Destination $target -Force
                $restored++
                Write-Log "restored: $target"
            }
            catch {
                Write-Log "restore failed: $target $($_.Exception.Message)"
                [void]$left.Add($item)
            }
        }
        Save-BellyItems $left.ToArray()
        if (-not $Quiet) { Show-Bubble "吐出来了 $restored 个" 5000 }
        return $restored
    }

    function Invoke-Eat {
        $shortcuts = Get-DesktopShortcuts
        if ($shortcuts.Count -eq 0) {
            Show-Bubble '桌上没有快捷方式可以吃…' 4000
            return
        }
        $pick = $shortcuts[$script:random.Next(0, $shortcuts.Count)]
        $name = [IO.Path]::GetFileNameWithoutExtension($pick.Name)
        if ($script:eatRealMode) {
            New-Item -ItemType Directory -Force -Path $script:bellyDir | Out-Null
            $stored = $pick.Name
            $counter = 1
            while (Test-Path -LiteralPath (Join-Path $script:bellyDir $stored)) {
                $stored = [IO.Path]::GetFileNameWithoutExtension($pick.Name) + "-$counter.lnk"
                $counter++
            }
            try {
                Move-Item -LiteralPath $pick.FullName -Destination (Join-Path $script:bellyDir $stored) -Force
                $items = New-Object System.Collections.ArrayList
                foreach ($existing in Get-BellyItems) { [void]$items.Add($existing) }
                [void]$items.Add([ordered]@{
                    name     = $name
                    original = $pick.FullName
                    stored   = $stored
                    eaten_at = (Get-Date).ToString('s')
                })
                Save-BellyItems $items.ToArray()
                Write-Log "ate: $($pick.FullName) -> $stored"
                Show-Bubble "嗯…「$name」被我吃掉了~（退出时会还给你）" 6000
            }
            catch {
                Write-Log "eat failed: $($_.Exception.Message)"
                Show-Bubble "咬不动「$name」…" 4000
                return
            }
        }
        else {
            Show-Bubble "嗯…「$name」看起来很好吃~（只是假装）" 5000
        }
        Play-Sound 'eat'
        Start-OneShot $RowWork ($rowFrames[$RowWork] * 3) $null
    }

    # 启动时先把上次没还回去的还掉，避免程序被强杀后东西一直留在肚子里
    $script:leftoverRestored = Restore-Belly -Quiet

    # ── AI 对话（任何 OpenAI 兼容接口）──
    # 密钥只放在本机 ai-config.json 里，程序不打印、不外传。
    $configPath = Join-Path $scriptRoot 'ai-config.json'
    $configTemplate = [ordered]@{
        enabled    = $false
        base_url   = 'https://api.openai.com/v1'
        api_key    = ''
        model      = 'gpt-4o-mini'
        max_tokens = 120
        timeout_seconds = 30
        system_prompt = '你是《鸣潮》爱弥斯风格的桌面宠物，Q版、粉发、金色星形瞳孔。说话简短可爱、口语化，一般不超过 30 个字，不要用 markdown，不要自称 AI 或语言模型。'
    }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        ($configTemplate | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $configPath -Encoding UTF8
        Write-Log "created ai-config.json template"
    }
    $script:aiConfig = $null
    $script:aiReady = $false
    function Reload-AiConfig() {
        try {
            $script:aiConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:aiReady = (-not $NoAi) -and $script:aiConfig.enabled -and
                              (-not [string]::IsNullOrWhiteSpace($script:aiConfig.api_key))
        }
        catch {
            $script:aiConfig = $null
            $script:aiReady = $false
            Write-Log "ai-config.json 解析失败：$($_.Exception.Message)"
        }
    }
    Reload-AiConfig

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    catch { }
    $script:http = New-Object System.Net.Http.HttpClient
    $script:httpTask = $null
    $script:httpTaskKind = 'chat'
    $script:httpTaskQueue = @()
    $script:balanceTried = @()
    $script:httpBusy = $false
    $script:history = New-Object System.Collections.ArrayList

    # ── 用量统计：每次回复里的 usage 累加 ──
    $script:usage = [ordered]@{ calls = 0; prompt = 0; completion = 0; total = 0; last = $null }
    function Get-UsageText {
        if ($script:usage.calls -eq 0) { return '本次会话还没调用过' }
        $u = $script:usage
        $lastText = ''
        if ($null -ne $u.last) {
            $lastText = "  上次：入 $($u.last.prompt) / 出 $($u.last.completion)"
        }
        return "调用 $($u.calls) 次；输入 $($u.prompt) tokens，输出 $($u.completion) tokens，合计 $($u.total)$lastText"
    }

    # ── 余额查询：不同服务商接口不同，按 base_url 猜，猜不到就依次试 ──
    function Get-BalanceEndpoints {
        $base = $script:aiConfig.base_url.TrimEnd('/')
        $host_ = ''
        try { $host_ = ([Uri]$base).Host.ToLower() } catch { }
        if ($host_ -like '*deepseek*') { return @("$base/user/balance") }
        if ($host_ -like '*siliconflow*') { return @("$base/user/info") }
        if ($host_ -like '*moonshot*') { return @("$base/users/me/balance") }
        if ($host_ -like '*openai*') {
            # OpenAI 的 API key 没有公开的余额接口，如实说明而不是瞎猜
            return @("$base/dashboard/billing/credit_grants")
        }
        return @("$base/user/balance", "$base/dashboard/billing/credit_grants", "$base/user/info")
    }

    function Start-BalanceQuery {
        if (-not $script:aiReady) { Show-Bubble (Get-AiStatusText) 6000; return }
        if ($script:httpBusy) { return }
        $script:httpBusy = $true
        $script:httpTask = $null
        $script:balanceTried = @()
        try {
            $script:http.Timeout = [TimeSpan]::FromSeconds(15)
            $script:http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiConfig.api_key)
            $endpoints = Get-BalanceEndpoints
            $script:balanceTried = $endpoints
            $script:httpTask = $script:http.GetAsync($endpoints[0])
            $script:httpTaskKind = 'balance'
            $script:httpTaskQueue = @($endpoints | Select-Object -Skip 1)
            Show-Bubble '查询余额…' 20000
        }
        catch {
            $script:httpBusy = $false
            Show-Bubble "查询失败：$($_.Exception.Message)" 8000
        }
    }

    function Complete-BalanceQuery {
        $task = $script:httpTask
        $script:httpTask = $null
        try {
            $response = $task.Result
            $text = $response.Content.ReadAsStringAsync().Result
            if (-not $response.IsSuccessStatusCode) {
                # 这个端点不认，换下一个试
                if ($script:httpTaskQueue.Count -gt 0) {
                    $next = $script:httpTaskQueue[0]
                    $script:httpTaskQueue = @($script:httpTaskQueue | Select-Object -Skip 1)
                    $script:httpTask = $script:http.GetAsync($next)
                    return
                }
                $script:httpBusy = $false
                Show-Bubble "该接口没有可用的余额端点（已试 $($script:balanceTried.Count) 个）" 8000
                Write-Log "balance failed: $($script:balanceTried -join ', ')"
                return
            }
            $script:httpBusy = $false
            $parsed = $text | ConvertFrom-Json
            $summary = $null
            # DeepSeek：balance_infos[].total_balance
            if ($parsed.balance_infos) {
                $summary = ($parsed.balance_infos | ForEach-Object { "$($_.total_balance) $($_.currency)" }) -join ' / '
            }
            elseif ($parsed.data -and $parsed.data.balance) { $summary = "$($parsed.data.balance)" }
            elseif ($parsed.balance) { $summary = "$($parsed.balance)" }
            elseif ($parsed.total_available) { $summary = "$($parsed.total_available)" }
            if ([string]::IsNullOrWhiteSpace($summary)) {
                $preview = $text.Substring(0, [Math]::Min(160, $text.Length))
                Show-Bubble "余额：$preview" 12000
            }
            else {
                Show-Bubble "余额：$summary" 12000
            }
            Write-Log "balance ok: $text"
        }
        catch {
            $script:httpBusy = $false
            Show-Bubble '余额解析失败' 8000
            Write-Log "balance parse failed: $($_.Exception.Message)"
        }
    }

    function Get-AiStatusText() {
        if ($null -eq $script:aiConfig) { return 'AI：配置文件损坏' }
        if (-not $script:aiConfig.enabled) { return 'AI：未启用（改 ai-config.json 里的 enabled）' }
        if ([string]::IsNullOrWhiteSpace($script:aiConfig.api_key)) { return 'AI：未填 api_key' }
        return "AI：已就绪（$($script:aiConfig.model)）"
    }

    function Start-AiRequest([string]$UserText) {
        if (-not $script:aiReady) {
            Show-Bubble (Get-AiStatusText) 6000
            return
        }
        if ($script:httpBusy) { return }
        $script:httpBusy = $true
        $script:httpTask = $null

        $messages = New-Object System.Collections.ArrayList
        [void]$messages.Add(@{ role = 'system'; content = $script:aiConfig.system_prompt })
        foreach ($turn in $script:history) { [void]$messages.Add($turn) }
        [void]$messages.Add(@{ role = 'user'; content = $UserText })

        $body = @{
            model      = $script:aiConfig.model
            messages   = $messages.ToArray()
            max_tokens = [int]$script:aiConfig.max_tokens
        } | ConvertTo-Json -Depth 6

        try {
            $script:http.Timeout = [TimeSpan]::FromSeconds([int]$script:aiConfig.timeout_seconds)
            $script:http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiConfig.api_key)
            $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
            $url = $script:aiConfig.base_url.TrimEnd('/') + '/chat/completions'
            # 异步发出，交给主循环轮询；同步调用会把界面卡死
            $script:httpTask = $script:http.PostAsync($url, $content)
            $script:httpTaskKind = 'chat'
            Show-Bubble '……' 30000
        }
        catch {
            $script:httpBusy = $false
            Show-Bubble "请求失败：$($_.Exception.Message)" 8000
        }
    }

    function Complete-AiRequest() {
        if ($null -eq $script:httpTask) { return }
        if (-not $script:httpTask.IsCompleted) { return }
        $task = $script:httpTask
        $script:httpTask = $null
        $script:httpBusy = $false
        try {
            $response = $task.Result
            $text = $response.Content.ReadAsStringAsync().Result
            if (-not $response.IsSuccessStatusCode) {
                $code = [int]$response.StatusCode
                $hint = switch ($code) {
                    401 { '密钥无效' }
                    404 { '模型或地址不对' }
                    429 { '额度/频率超限' }
                    default { 'HTTP ' + $code }
                }
                Write-Log "ai error $code : $text"
                Show-Bubble "AI 出错：$hint" 8000
                return
            }
            $parsed = $text | ConvertFrom-Json
            $reply = $parsed.choices[0].message.content
            # 统计用量：OpenAI 兼容接口都会在 usage 里返回 token 数
            if ($parsed.usage) {
                $p = [int]$parsed.usage.prompt_tokens
                $c = [int]$parsed.usage.completion_tokens
                $t = if ($parsed.usage.total_tokens) { [int]$parsed.usage.total_tokens } else { $p + $c }
                $script:usage.calls++
                $script:usage.prompt += $p
                $script:usage.completion += $c
                $script:usage.total += $t
                $script:usage.last = [ordered]@{ prompt = $p; completion = $c; total = $t }
            }
            if ([string]::IsNullOrWhiteSpace($reply)) { $reply = '（她没说话）' }
            $reply = $reply.Trim()
            [void]$script:history.Add(@{ role = 'user'; content = $script:lastUserText })
            [void]$script:history.Add(@{ role = 'assistant'; content = $reply })
            while ($script:history.Count -gt 8) { $script:history.RemoveAt(0) }
            Show-Bubble $reply 9000
            Say-Something $reply
            Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) $null
        }
        catch {
            Write-Log "ai parse failed: $($_.Exception.Message)"
            Show-Bubble 'AI 回复解析失败' 8000
        }
    }

    # ── 窗口 ──
    # 显示尺寸固定按交付格式的 192x208 乘以缩放；高清图集在这个尺寸下接近 1:1，所以清晰
    $displayW = $BaseCellW * $Scale
    $displayH = $BaseCellH * $Scale

    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.Width = $displayW
    $window.Height = $displayH

    $image = New-Object System.Windows.Controls.Image
    $image.Width = $displayW
    $image.Height = $displayH
    $image.Stretch = [System.Windows.Media.Stretch]::Fill
    # 高清图集下这里是等比缩放（1:1 或轻微缩小），HighQuality 既清晰又不吃性能
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $image.Source = $cells[0, 0]
    $window.Content = $image

    $script:work = [System.Windows.SystemParameters]::WorkArea
    $script:floorTop = $script:work.Bottom - $window.Height - 24
    $window.Left = $script:work.Right - $window.Width - 60
    $window.Top = $script:floorTop

    # ── 对话气泡（独立小窗口，贴在她头顶上方）──
    $bubbleText = New-Object System.Windows.Controls.TextBlock
    $bubbleText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bubbleText.FontSize = 14
    $bubbleText.Foreground = [System.Windows.Media.Brushes]::Black
    $bubbleBorder = New-Object System.Windows.Controls.Border
    $bubbleBorder.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $bubbleBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(242, 255, 255, 255))
    $bubbleBorder.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(255, 120, 150, 235))
    $bubbleBorder.BorderThickness = New-Object System.Windows.Thickness(2)
    $bubbleBorder.Padding = New-Object System.Windows.Thickness(10, 8, 10, 8)
    $bubbleBorder.Child = $bubbleText
    $bubbleBorder.MaxWidth = 260

    $bubble = New-Object System.Windows.Window
    $bubble.WindowStyle = [System.Windows.WindowStyle]::None
    $bubble.AllowsTransparency = $true
    $bubble.Background = [System.Windows.Media.Brushes]::Transparent
    $bubble.Topmost = $true
    $bubble.ShowInTaskbar = $false
    $bubble.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $bubble.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $bubble.Content = $bubbleBorder
    $script:bubbleUntil = 0

    function Show-Bubble([string]$Text, [int]$Milliseconds = 6000) {
        $bubbleText.Text = $Text
        $bubble.UpdateLayout()
        $w = if ($bubble.ActualWidth -gt 0) { $bubble.ActualWidth } else { 200 }
        $h = if ($bubble.ActualHeight -gt 0) { $bubble.ActualHeight } else { 60 }
        $left = $window.Left + ($window.Width - $w) / 2
        $top = $window.Top - $h - 8
        if ($top -lt $script:work.Top + 4) { $top = $window.Top + $window.Height + 8 }
        if ($left -lt $script:work.Left + 4) { $left = $script:work.Left + 4 }
        if ($left + $w -gt $script:work.Right - 4) { $left = $script:work.Right - $w - 4 }
        $bubble.Left = $left
        $bubble.Top = $top
        if (-not $bubble.IsVisible) { $bubble.Show() }
        $script:bubbleUntil = [Environment]::TickCount + $Milliseconds
    }

    function Read-UserText() {
        $dlg = New-Object System.Windows.Window
        $dlg.Title = '和爱弥斯说句话'
        $dlg.WindowStyle = [System.Windows.WindowStyle]::ToolWindow
        $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $dlg.Width = 360
        $dlg.Height = 150
        $dlg.Topmost = $true
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen

        $box = New-Object System.Windows.Controls.TextBox
        $box.FontSize = 14
        $box.AcceptsReturn = $false
        $box.Margin = New-Object System.Windows.Thickness(12, 12, 12, 6)
        $ok = New-Object System.Windows.Controls.Button
        $ok.Content = '发送'
        $ok.Width = 80
        $ok.Margin = New-Object System.Windows.Thickness(0, 0, 12, 12)
        $ok.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $ok.IsDefault = $true
        $cancel = New-Object System.Windows.Controls.Button
        $cancel.Content = '取消'
        $cancel.Width = 80
        $cancel.Margin = New-Object System.Windows.Thickness(0, 0, 100, 12)
        $cancel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $cancel.IsCancel = $true

        $panel = New-Object System.Windows.Controls.DockPanel
        $panel.Children.Add($ok) | Out-Null
        $panel.Children.Add($cancel) | Out-Null
        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Children.Add($box) | Out-Null
        $stack.Children.Add($panel) | Out-Null
        $dlg.Content = $stack

        $script:dialogText = $null
        $ok.Add_Click({ $script:dialogText = $box.Text; $dlg.Close() })
        $cancel.Add_Click({ $dlg.Close() })
        $box.Add_KeyDown({ if ($_.Key -eq 'Return') { $script:dialogText = $box.Text; $dlg.Close() } })
        $dlg.Add_ContentRendered({ $box.Focus() | Out-Null })
        $dlg.ShowDialog() | Out-Null
        return $script:dialogText
    }

    # ── 状态 ──
    $script:mode = 'idle'          # idle | look | drag | oneshot | walk
    $script:row = 0
    $script:col = 0
    $script:frameTick = 0
    $script:oneshotUntil = 0
    $script:followMouse = $true
    $script:roam = -not $NoRoam
    $script:dragging = $false
    $script:dragOrigin = $null
    $script:windowOrigin = $null
    $script:movedDuringDrag = $false
    $script:lastRow = -1
    $script:lastCol = -1
    $script:centerCache = $null
    $script:centerAge = 0
    $script:centerKey = ''
    $script:lastMoveMs = 0
    $script:currentIntervalMs = $IdleFrameMs
    $script:sourceAssignments = 0
    $script:centerComputes = 0
    # 自主行为
    $script:idleTicks = 0
    $script:nextDecision = 18
    $script:walkTargetX = $window.Left
    $script:walkDir = 1
    $script:lastUserText = ''
    $script:random = New-Object System.Random

    function Show-Cell([int]$Row, [int]$Col) {
        if ($Row -eq $script:lastRow -and $Col -eq $script:lastCol) { return }
        $script:lastRow = $Row
        $script:lastCol = $Col
        $script:sourceAssignments++
        $image.Source = $cells[$Row, $Col]
    }

    function Set-FrameInterval([int]$Ms) {
        if ($script:currentIntervalMs -ne $Ms) {
            $script:currentIntervalMs = $Ms
            $timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
        }
    }

    function Start-OneShot([int]$Row, [int]$Ticks, [string]$Sound) {
        $script:mode = 'oneshot'
        $script:row = $Row
        $script:col = 0
        $script:frameTick = 0
        $script:oneshotUntil = $Ticks
        if ($Sound) { Play-Sound $Sound }
        Show-Cell $Row 0
    }

    function Get-LookCell([double]$AngleDegrees) {
        $index = [int][Math]::Floor((($AngleDegrees + 11.25) / 22.5)) % 16
        if ($index -lt 0) { $index += 16 }
        if ($index -lt 8) { return @(9, $index) } else { return @(10, ($index - 8)) }
    }

    function Get-PetCenterOnScreen() {
        $key = "$($window.Left)|$($window.Top)"
        if ($null -ne $script:centerCache -and $key -eq $script:centerKey -and $script:centerAge -lt 15) {
            $script:centerAge++
            return $script:centerCache
        }
        $script:centerAge = 0
        $script:centerKey = $key
        $script:centerComputes++
        try {
            $script:centerCache = $window.PointToScreen((New-Object System.Windows.Point(($window.Width / 2), ($window.Height / 2))))
        }
        catch {
            $script:centerCache = (New-Object System.Windows.Point(($window.Left + $window.Width / 2), ($window.Top + $window.Height / 2)))
        }
        return $script:centerCache
    }

    function Start-Walk() {
        $minX = $script:work.Left + 8
        $maxX = $script:work.Right - $window.Width - 8
        if ($maxX -le $minX) { return }
        $distance = $script:random.Next(90, 340)
        $dir = if ($script:random.Next(0, 2) -eq 0) { -1 } else { 1 }
        $target = [Math]::Round($window.Left + $dir * $distance)
        if ($target -lt $minX) { $target = $minX; $dir = 1 }
        if ($target -gt $maxX) { $target = $maxX; $dir = -1 }
        if ([Math]::Abs($target - $window.Left) -lt 40) { return }
        $script:walkTargetX = $target
        $script:walkDir = $dir
        $script:mode = 'walk'
        $script:frameTick = 0
        Play-Sound 'step'
    }

    function Update-Frame() {
        $script:frameTick++

        # AI 请求 / 余额查询轮询 + 气泡自动收起（放在最前面，任何状态下都要生效）
        if ($null -ne $script:httpTask -and $script:httpTask.IsCompleted) {
            if ($script:httpTaskKind -eq 'balance') { Complete-BalanceQuery } else { Complete-AiRequest }
        }
        if ($script:bubbleUntil -gt 0 -and [Environment]::TickCount -gt $script:bubbleUntil) {
            $script:bubbleUntil = 0
            if ($bubble.IsVisible) { $bubble.Hide() }
        }

        if ($script:mode -eq 'drag') {
            Set-FrameInterval $RunFrameMs
            $row = if ($script:dragDirection -ge 0) { $RowRight } else { $RowLeft }
            Show-Cell $row ($script:frameTick % $rowFrames[$row])
            return
        }

        if ($script:mode -eq 'oneshot') {
            Set-FrameInterval $OneShotFrameMs
            if ($script:frameTick % 3 -eq 0) { $script:col++ }
            if ($script:col -ge $rowFrames[$script:row]) {
                $script:mode = 'idle'
                $script:row = $RowIdle
                $script:col = 0
                $script:frameTick = 0
                $script:idleTicks = 0
                $script:nextDecision = $script:random.Next(14, 40)
                return
            }
            Show-Cell $script:row $script:col
            return
        }

        if ($script:mode -eq 'walk') {
            Set-FrameInterval $RunFrameMs
            $row = if ($script:walkDir -ge 0) { $RowRight } else { $RowLeft }
            Show-Cell $row ($script:frameTick % $rowFrames[$row])
            $step = $script:walkDir * $WalkSpeed
            $next = $window.Left + $step
            if (($script:walkDir -gt 0 -and $next -ge $script:walkTargetX) -or
                ($script:walkDir -lt 0 -and $next -le $script:walkTargetX) -or
                $next -lt ($script:work.Left + 8) -or
                $next -gt ($script:work.Right - $window.Width - 8)) {
                $script:mode = 'idle'
                $script:frameTick = 0
                $script:idleTicks = 0
                $script:nextDecision = $script:random.Next(14, 40)
                return
            }
            $window.Left = $next
            return
        }

        # 空闲：先看要不要自己动起来，再看要不要跟随鼠标
        if ($script:roam) {
            $script:idleTicks++
            if ($script:idleTicks -ge $script:nextDecision) {
                $script:idleTicks = 0
                $roll = $script:random.Next(0, 100)
                if ($roll -lt 55) { Start-Walk; return }
                elseif ($roll -lt 72) { Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello'; return }
                elseif ($roll -lt 82) { Start-OneShot $RowJump ($rowFrames[$RowJump] * 3) 'jump'; return }
                elseif ($roll -lt 88) { Start-OneShot $RowReview ($rowFrames[$RowReview] * 3) 'review'; return }
                elseif ($roll -lt 93 -and $script:canEat) { Invoke-Eat; return }
                else { $script:nextDecision = $script:random.Next(14, 40) }
            }
            if ($script:random.Next(0, 1000) -lt 4) { Play-Sound 'chirp' }
        }

        $center = Get-PetCenterOnScreen
        $cursor = [System.Windows.Forms.Cursor]::Position
        $dx = $cursor.X - $center.X
        $dy = $cursor.Y - $center.Y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)

        if ($script:followMouse -and $distance -gt ($displayH * 0.9)) {
            Set-FrameInterval $LookFrameMs
            $angle = [Math]::Atan2($dx, -$dy) * 180.0 / [Math]::PI
            if ($angle -lt 0) { $angle += 360 }
            $cell = Get-LookCell $angle
            Show-Cell $cell[0] $cell[1]
            return
        }

        Set-FrameInterval $IdleFrameMs
        if ($script:frameTick % 6 -eq 0) { $script:col++ }
        if ($script:col -ge $rowFrames[$RowIdle]) { $script:col = 0 }
        Show-Cell $RowIdle $script:col
    }

    # 用带优先级的构造函数：默认 Background 优先级在 UI 线程忙碌时会被推迟，导致节奏不匀。
    $timer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Normal)
    $timer.Interval = [TimeSpan]::FromMilliseconds($IdleFrameMs)
    $timer.Add_Tick({ Update-Frame })

    # ── 鼠标交互 ──
    $window.Add_MouseLeftButtonDown({
        $script:dragging = $true
        $script:movedDuringDrag = $false
        $script:dragOrigin = [System.Windows.Forms.Cursor]::Position
        $script:windowOrigin = New-Object System.Windows.Point($window.Left, $window.Top)
        $window.CaptureMouse() | Out-Null
    })
    $window.Add_MouseMove({
        if (-not $script:dragging) { return }
        # 鼠标移动事件频率极高，而 PowerShell 每次处理都要进解释器；限到约 60fps 并忽略微小位移
        $tick = [Environment]::TickCount
        if (($tick - $script:lastMoveMs) -lt 16) { return }
        $script:lastMoveMs = $tick
        $now = [System.Windows.Forms.Cursor]::Position
        $dx = $now.X - $script:dragOrigin.X
        $dy = $now.Y - $script:dragOrigin.Y
        if (-not $script:movedDuringDrag -and ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3)) {
            $script:movedDuringDrag = $true
        }
        $newLeft = $script:windowOrigin.X + $dx
        $newTop = $script:windowOrigin.Y + $dy
        if ($newLeft -ne $window.Left) { $window.Left = $newLeft }
        if ($newTop -ne $window.Top) { $window.Top = $newTop }
        if ($script:movedDuringDrag) {
            $script:mode = 'drag'
            $script:dragDirection = $dx
        }
    })
    $window.Add_MouseLeftButtonUp({
        $window.ReleaseMouseCapture()
        if ($script:dragging -and -not $script:movedDuringDrag) {
            Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello'
            Say-Something ($lines[$script:random.Next(0, $lines.Count)])
        }
        else {
            $script:mode = 'idle'
            $script:frameTick = 0
            $script:col = 0
            $script:idleTicks = 0
            $script:nextDecision = $script:random.Next(14, 40)
        }
        $script:dragging = $false
    })

    # ── 菜单 ──
    $menu = New-Object System.Windows.Controls.ContextMenu
    function Add-MenuItem([string]$Header, [scriptblock]$Action, [bool]$Checkable = $false, [bool]$Checked = $false) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $Header
        if ($Checkable) { $item.IsCheckable = $true; $item.IsChecked = $Checked }
        $item.Add_Click($Action)
        $menu.Items.Add($item) | Out-Null
        return $item
    }
    Add-MenuItem '挥手' { Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello' } | Out-Null
    Add-MenuItem '跳一下' { Start-OneShot $RowJump ($rowFrames[$RowJump] * 3) 'jump' } | Out-Null
    Add-MenuItem '失败一下' { Start-OneShot $RowFail ($rowFrames[$RowFail] * 3) 'fail' } | Out-Null
    Add-MenuItem '工作一下' { Start-OneShot $RowWork ($rowFrames[$RowWork] * 3) 'work' } | Out-Null
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    Add-MenuItem '自由活动' { $script:roam = $roamItem.IsChecked } $true $script:roam | Out-Null
    $roamItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '声音' { $script:soundOn = $soundItem.IsChecked } $true $script:soundOn | Out-Null
    $soundItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '说话（机器音）' {
        $script:speakOn = $speakItem.IsChecked
        if ($script:speakOn) { Say-Something '你好呀' }
    } $true $false | Out-Null
    $speakItem = $menu.Items[$menu.Items.Count - 1]
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    Add-MenuItem '和她说句话…' {
        $text = Read-UserText
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $script:lastUserText = $text
            Start-AiRequest $text
        }
    } | Out-Null
    Add-MenuItem '测试 AI 连接' {
        if (-not $script:aiReady) { Show-Bubble (Get-AiStatusText) 6000 }
        else {
            $script:lastUserText = '用一句话打个招呼'
            Start-AiRequest '用一句话打个招呼'
        }
    } | Out-Null
    Add-MenuItem 'AI 状态' { Show-Bubble (Get-AiStatusText) 6000 } | Out-Null
    Add-MenuItem '查看用量（tokens）' { Show-Bubble (Get-UsageText) 10000 } | Out-Null
    Add-MenuItem '查询余额' { Start-BalanceQuery } | Out-Null
    Add-MenuItem '打开 AI 配置（记事本）' {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList $configPath } catch { }
        Show-Bubble '改完记得点「重新载入 AI 配置」' 6000
    } | Out-Null
    Add-MenuItem '重新载入 AI 配置' {
        Reload-AiConfig
        Show-Bubble (Get-AiStatusText) 6000
    } | Out-Null
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    Add-MenuItem '偷吃快捷方式' { $script:canEat = $eatItem.IsChecked } $true $script:canEat | Out-Null
    $eatItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '真吃模式（会移动桌面文件）' {
        $script:eatRealMode = $realEatItem.IsChecked
        if ($script:eatRealMode) {
            Show-Bubble '真吃模式已开：只动桌面上的 .lnk，退出时自动还原' 8000
        }
    } $true $script:eatRealMode | Out-Null
    $realEatItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '看看她肚子里有什么' {
        $items = Get-BellyItems
        if ($items.Count -eq 0) { Show-Bubble '肚子里空空的' 4000 }
        else { Show-Bubble ("肚子里有 $($items.Count) 个：" + (($items | ForEach-Object { $_.name }) -join '、')) 8000 }
    } | Out-Null
    Add-MenuItem '吐出肚子里的东西' { Restore-Belly | Out-Null } | Out-Null
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    Add-MenuItem '看向鼠标' { $script:followMouse = -not $script:followMouse } | Out-Null
    Add-MenuItem '回到右下角' { $window.Left = $script:work.Right - $window.Width - 60; $window.Top = $script:floorTop } | Out-Null
    Add-MenuItem '退出' { $window.Close() } | Out-Null
    $window.ContextMenu = $menu

    if ($SelfTest) {
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        Start-OneShot $RowWave 12 'hello'
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        # 走动测试用确定性目标，不依赖随机数，避免自检时好时坏
        $script:roam = $false
        $before = $window.Left
        $script:mode = 'walk'
        $script:walkDir = 1
        $script:walkTargetX = $window.Left + 200
        $script:frameTick = 0
        for ($i = 0; $i -lt 20; $i++) { Update-Frame }
        $moved = [Math]::Round([Math]::Abs($window.Left - $before))
        $script:mode = 'idle'
        # 偷吃功能的自检：只验证函数可用与桌面可读，绝不真的移动文件
        $shortcutCount = (Get-DesktopShortcuts).Count
        $bellyCount = (Get-BellyItems).Count
        "SELFTEST_OK atlas=$(Split-Path $atlasPath -Leaf) cell=${CellWidth}x${CellHeight} cards=$($cells.Length) sounds=$($players.Count) scale=$Scale walk_moved_px=$moved window=$($window.Width)x$($window.Height) ai=$($script:aiReady) bubble_ok=$([bool]$bubbleText) desktop_lnk=$shortcutCount belly=$bellyCount leftover_restored=$($script:leftoverRestored) usage='$((Get-UsageText))'"
        exit 0
    }

    if ($PerfTest -gt 0) {
        $script:roam = $false   # 性能测试时不要让她乱跑
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $PerfTest; $i++) { Update-Frame }
        $sw.Stop()
        $per = [Math]::Round($sw.Elapsed.TotalMilliseconds / $PerfTest, 3)
        "PERFTEST ticks=$PerfTest total_ms=$([Math]::Round($sw.Elapsed.TotalMilliseconds,1)) per_tick_ms=$per source_assignments=$($script:sourceAssignments) center_computes=$($script:centerComputes) intervals(idle/look/run/oneshot)=$IdleFrameMs/$LookFrameMs/$RunFrameMs/$OneShotFrameMs"
        exit 0
    }

    if ($TestAi) {
        "AI 配置文件：$configPath"
        if ($null -eq $script:aiConfig) { "FAILED 配置无法解析"; exit 1 }
        "  enabled = $($script:aiConfig.enabled)"
        "  base_url = $($script:aiConfig.base_url)"
        "  model = $($script:aiConfig.model)"
        "  api_key = $(if ([string]::IsNullOrWhiteSpace($script:aiConfig.api_key)) { '(空)' } else { '已填写（长度 ' + $script:aiConfig.api_key.Length + '）' })"
        "  余额端点（按服务商推断，失败会自动依次重试）= $(Get-BalanceEndpoints -join '  ->  ')"
        if (-not $script:aiReady) { "SKIPPED 未启用或未填 api_key；请先编辑 ai-config.json"; exit 2 }
        $messages = @(
            @{ role = 'system'; content = $script:aiConfig.system_prompt },
            @{ role = 'user'; content = $TestAiPrompt }
        )
        $body = @{ model = $script:aiConfig.model; messages = $messages; max_tokens = [int]$script:aiConfig.max_tokens } | ConvertTo-Json -Depth 6
        try {
            $testClient = New-Object System.Net.Http.HttpClient
            $testClient.Timeout = [TimeSpan]::FromSeconds([int]$script:aiConfig.timeout_seconds)
            $testClient.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiConfig.api_key)
            $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
            $url = $script:aiConfig.base_url.TrimEnd('/') + '/chat/completions'
            $response = $testClient.PostAsync($url, $content).GetAwaiter().GetResult()
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            "HTTP $([int]$response.StatusCode)"
            if ($response.IsSuccessStatusCode) {
                $reply = ($text | ConvertFrom-Json).choices[0].message.content
                "回复：$($reply.Trim())"
                "TESTAI_OK"
                exit 0
            }
            "错误内容：$($text.Substring(0, [Math]::Min(300, $text.Length)))"
            "TESTAI_FAILED"
            exit 1
        }
        catch {
            "请求异常：$($_.Exception.Message)"
            "TESTAI_FAILED"
            exit 1
        }
    }

    Write-Log "started (sounds=$($players.Count) roam=$($script:roam))"
    $window.Add_Closed({
        Write-Log 'closed'
        $timer.Stop()
        # 退出前把肚子里的快捷方式还回去，绝不带走用户的东西
        try { Restore-Belly -Quiet | Out-Null } catch { Write-Log "exit restore failed: $($_.Exception.Message)" }
        try { if ($bubble.IsVisible) { $bubble.Close() } } catch { }
        if ($null -ne $synth) { try { $synth.Dispose() } catch { } }
        if ($null -ne $script:http) { try { $script:http.Dispose() } catch { } }
        [System.Windows.Application]::Current.Shutdown()
    })
    $timer.Start()
    $window.ShowDialog() | Out-Null
    Write-Log 'exited'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if ($SelfTest -or $PerfTest -gt 0) { "FAILED $($_.Exception.Message)"; exit 1 }
    [System.Windows.MessageBox]::Show("爱弥斯启动失败：`n`n$($_.Exception.Message)`n`n详情见 $logPath", '爱弥斯桌宠') | Out-Null
    exit 1
}
