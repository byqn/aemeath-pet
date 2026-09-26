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
    [string]$TestAiPrompt = '用一句话打个招呼',
    # 命令行拉取当前提供方的模型列表（等价于点界面里的「获取可用模型」）
    [switch]$ListModels,
    # 命令行验证 Provider ID 规则（调用界面同一套校验函数）
    [string]$ValidateProviderId = '',
    # 命令行查询余额（与界面同一条代码路径）
    [switch]$TestBalance
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
        $shortcuts = @(Get-DesktopShortcuts)
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

    # ── AI 对话（可自定义提供方）──
    # 配置结构（v2）：
    #   providers 里按 Provider ID 存每个提供方，ID 同时用于派生凭据名；
    #   active_provider 指向当前使用的那一个。密钥只存在本机，程序不打印、不外传。
    $configPath = Join-Path $scriptRoot 'ai-config.json'
    $defaultSystemPrompt = '你是《鸣潮》爱弥斯风格的桌面宠物，Q版、粉发、金色星形瞳孔。说话简短可爱、口语化，一般不超过 30 个字，不要用 markdown，不要自称 AI 或语言模型。'

    function New-ConfigSkeleton {
        return [ordered]@{
            version         = 2
            enabled         = $false
            active_provider = ''
            providers       = [ordered]@{}
            max_tokens      = 120
            timeout_seconds = 30
            system_prompt   = $defaultSystemPrompt
        }
    }

    function Get-ProviderIdFromUrl([string]$Url) {
        # 老版扁平配置迁移时，用主机名派生一个合法的 Provider ID
        try {
            $host_ = ([Uri]$Url).Host.ToLower()
            $id = ($host_ -replace '[^a-z0-9]+', '-').Trim('-')
            if ($id -notmatch '^[a-z]') { $id = "p-$id" }
            if ([string]::IsNullOrWhiteSpace($id)) { $id = 'default' }
            return $id
        }
        catch { return 'default' }
    }

    function Test-ProviderId([string]$Id) {
        # 以小写字母开头，只含小写字母、数字、连字符。
        # 注意必须用 -cmatch：PowerShell 的 -match 默认不区分大小写，会把 'Acme' 放过。
        return ($Id -cmatch '^[a-z][a-z0-9-]*$')
    }

    function Save-AiConfig([object]$Config) {
        $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Save-AiConfig (New-ConfigSkeleton)
        Write-Log 'created ai-config.json'
    }

    $script:aiConfig = $null
    $script:aiProvider = $null
    $script:aiReady = $false

    function Reload-AiConfig() {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $script:aiConfig = $null
            $script:aiProvider = $null
            $script:aiReady = $false
            Write-Log "ai-config.json 解析失败：$($_.Exception.Message)"
            return
        }
        # 老版扁平配置（enabled/base_url/api_key/model）自动迁移成 v2
        if ($null -eq $raw.providers) {
            $migrated = New-ConfigSkeleton
            $migrated.enabled = [bool]$raw.enabled
            if ($raw.max_tokens) { $migrated.max_tokens = [int]$raw.max_tokens }
            if ($raw.timeout_seconds) { $migrated.timeout_seconds = [int]$raw.timeout_seconds }
            if ($raw.system_prompt) { $migrated.system_prompt = [string]$raw.system_prompt }
            if (-not [string]::IsNullOrWhiteSpace($raw.base_url)) {
                $id = Get-ProviderIdFromUrl $raw.base_url
                $migrated.providers[$id] = [ordered]@{
                    display_name = $id
                    base_url     = [string]$raw.base_url
                    protocol     = 'openai-completions'
                    api_key      = if ($raw.api_key) { [string]$raw.api_key } else { '' }
                    model        = if ($raw.model) { [string]$raw.model } else { 'gpt-4o-mini' }
                    models       = @()
                }
                $migrated.active_provider = $id
            }
            Save-AiConfig $migrated
            Write-Log 'ai-config.json 已从旧版迁移到 v2（多提供方）'
            $script:aiConfig = $migrated | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        }
        else {
            $script:aiConfig = $raw
        }

        $script:aiProvider = $null
        $activeId = [string]$script:aiConfig.active_provider
        if (-not [string]::IsNullOrWhiteSpace($activeId) -and $script:aiConfig.providers.PSObject.Properties[$activeId]) {
            $script:aiProvider = $script:aiConfig.providers.$activeId
            $script:aiProvider | Add-Member -NotePropertyName '_id' -NotePropertyValue $activeId -Force
        }
        $script:aiReady = (-not $NoAi) -and $script:aiConfig.enabled -and $null -ne $script:aiProvider -and
                          (-not [string]::IsNullOrWhiteSpace($script:aiProvider.api_key)) -and
                          (-not [string]::IsNullOrWhiteSpace($script:aiProvider.base_url))
    }
    Reload-AiConfig

    function Get-ActiveProviderSummary {
        if ($null -eq $script:aiProvider) { return '（未选择提供方）' }
        $p = $script:aiProvider
        return "$($p._id) / $($p.display_name) / $($p.protocol) / $($p.model)"
    }

    function New-AiHttpClient {
        # 按当前提供方的代理设置构建客户端；留空表示跟随系统代理
        $handler = New-Object System.Net.Http.HttpClientHandler
        $proxyUrl = ''
        if ($script:aiProvider -and $script:aiProvider.PSObject.Properties['proxy']) { $proxyUrl = [string]$script:aiProvider.proxy }
        if ([string]::IsNullOrWhiteSpace($proxyUrl) -and $script:aiConfig -and $script:aiConfig.PSObject.Properties['proxy']) {
            $proxyUrl = [string]$script:aiConfig.proxy
        }
        if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($proxyUrl.Trim(), $true)
        }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $timeout = 30
        if ($script:aiConfig -and $script:aiConfig.timeout_seconds) { $timeout = [int]$script:aiConfig.timeout_seconds }
        $client.Timeout = [TimeSpan]::FromSeconds($timeout)
        return $client
    }

    function Get-AiErrorHint([int]$Status, [string]$RawMessage) {
        switch ($Status) {
            401 { return '密钥无效或没填' }
            403 { return '密钥没权限，或余额不足' }
            404 { return '地址不对：要填到 /v1 这一层' }
            405 { return '地址不对：接口不支持这个路径' }
            429 { return '触发频率或额度限制' }
            default {
                if ($RawMessage -match '(?i)timed?\s*out|超时') { return '连接超时，可能需要填代理' }
                if ($RawMessage -match '(?i)name resolution|无法解析|no such host') { return '域名解析失败，检查地址拼写' }
                if ($RawMessage -match '(?i)connect|refused|unreachable') { return '连不上，可能需要填代理' }
                return $RawMessage
            }
        }
    }

    function Invoke-ModelsFetch([string]$BaseUrl, [string]$ApiKey, [string]$Protocol) {
        # 拉取可用模型列表；返回 @{ ok=...; models=@(); message=... }
        $result = @{ ok = $false; models = @(); message = '' }
        $url = $BaseUrl.TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($ApiKey)) {
            $result.message = '还没填 API 密钥（本地服务也要随便填几个字符）'
            return $result
        }
        $endpoint = "$url/models"
        try {
            $headers = @{ Authorization = "Bearer $ApiKey" }
            $proxyUrl = ''
            if ($script:aiProvider -and $script:aiProvider.PSObject.Properties['proxy']) { $proxyUrl = [string]$script:aiProvider.proxy }
            $params = @{ Uri = $endpoint; Headers = $headers; Method = 'Get'; TimeoutSec = 15 }
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) { $params['Proxy'] = $proxyUrl.Trim() }
            $response = Invoke-RestMethod @params
            $ids = @($response.data | ForEach-Object { $_.id } | Where-Object { $_ }) | Sort-Object -Unique
            if ($ids.Count -eq 0) {
                $result.message = '接口有响应，但返回里没有模型列表（格式不是 OpenAI 的 data[] 结构）'
                return $result
            }
            $result.ok = $true
            $result.models = $ids
            return $result
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            $raw = $_.Exception.Message
            $result.message = if ($status) { "HTTP $status — $(Get-AiErrorHint $status $raw)" } else { Get-AiErrorHint 0 $raw }
            return $result
        }
    }

    function Show-ApiSettings {
        $dlg = New-Object System.Windows.Window
        $dlg.Title = 'API 设置 — 自定义提供方'
        $dlg.Width = 560
        $dlg.Height = 640
        $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
        $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $dlg.Topmost = $true

        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = New-Object System.Windows.Thickness(16)

        function Add-Field([string]$Label, [string]$Hint, [object]$Control) {
            $lb = New-Object System.Windows.Controls.TextBlock
            $lb.Text = $Label
            $lb.FontWeight = [System.Windows.FontWeights]::Bold
            $lb.Margin = New-Object System.Windows.Thickness(0, 8, 0, 2)
            $panel.Children.Add($lb) | Out-Null
            if ($Hint) {
                $hb = New-Object System.Windows.Controls.TextBlock
                $hb.Text = $Hint
                $hb.FontSize = 11
                $hb.Foreground = [System.Windows.Media.Brushes]::Gray
                $hb.TextWrapping = [System.Windows.TextWrapping]::Wrap
                $hb.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
                $panel.Children.Add($hb) | Out-Null
            }
            $Control.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
            $panel.Children.Add($Control) | Out-Null
        }

        # 已有提供方下拉
        $providerCombo = New-Object System.Windows.Controls.ComboBox
        $existingIds = @()
        if ($script:aiConfig -and $script:aiConfig.providers) {
            $existingIds = @($script:aiConfig.providers.PSObject.Properties.Name)
        }
        foreach ($id in $existingIds) { [void]$providerCombo.Items.Add($id) }
        $providerCombo.IsEditable = $true
        if ($script:aiProvider) { $providerCombo.Text = $script:aiProvider._id }
        Add-Field '选择或新建提供方' '从下拉里选一个已有的，或直接输入新的 Provider ID' $providerCombo

        $idBox = New-Object System.Windows.Controls.TextBox
        Add-Field 'Provider ID' '以小写字母开头，只能含小写字母、数字、连字符；用于标识该提供方并派生凭据名' $idBox

        $nameBox = New-Object System.Windows.Controls.TextBox
        Add-Field '显示名称' '给自己看的名字，随意填' $nameBox

        $urlBox = New-Object System.Windows.Controls.TextBox
        Add-Field 'API 地址' '例如 https://gateway.example/v1' $urlBox

        $protocolCombo = New-Object System.Windows.Controls.ComboBox
        [void]$protocolCombo.Items.Add('openai-completions')
        [void]$protocolCombo.Items.Add('openai-responses')
        $protocolCombo.SelectedIndex = 0
        Add-Field 'API 协议' '目前实际走 /chat/completions 的是 openai-completions' $protocolCombo

        $keyBox = New-Object System.Windows.Controls.PasswordBox
        Add-Field 'API 密钥' '只保存在本机 ai-config.json，不会上传到任何地方' $keyBox

        $showKey = New-Object System.Windows.Controls.CheckBox
        $showKey.Content = '显示密钥'
        $panel.Children.Add($showKey) | Out-Null
        $keyPlain = New-Object System.Windows.Controls.TextBox
        $keyPlain.Visibility = [System.Windows.Visibility]::Collapsed
        $panel.Children.Add($keyPlain) | Out-Null

        $proxyBox = New-Object System.Windows.Controls.TextBox
        Add-Field '代理（可选）' '访问国外接口连不上时填，例如 http://127.0.0.1:7892；留空表示跟随系统代理' $proxyBox

        # 模型目录
        $modelRow = New-Object System.Windows.Controls.DockPanel
        $fetchBtn = New-Object System.Windows.Controls.Button
        $fetchBtn.Content = '获取可用模型'
        $fetchBtn.Width = 130
        $fetchBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        [System.Windows.Controls.DockPanel]::SetDock($fetchBtn, [System.Windows.Controls.Dock]::Right)
        $modelCombo = New-Object System.Windows.Controls.ComboBox
        $modelCombo.IsEditable = $true
        $modelRow.Children.Add($fetchBtn) | Out-Null
        $modelRow.Children.Add($modelCombo) | Out-Null
        Add-Field '模型目录' '点右侧按钮拉取列表，也可以直接手输模型名' $modelRow

        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $statusText.Foreground = [System.Windows.Media.Brushes]::DimGray
        $statusText.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
        $panel.Children.Add($statusText) | Out-Null

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $buttons.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $saveBtn = New-Object System.Windows.Controls.Button
        $saveBtn.Content = '保存并启用'
        $saveBtn.Width = 110
        $saveBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $cancelBtn = New-Object System.Windows.Controls.Button
        $cancelBtn.Content = '取消'
        $cancelBtn.Width = 80
        $buttons.Children.Add($saveBtn) | Out-Null
        $buttons.Children.Add($cancelBtn) | Out-Null
        $panel.Children.Add($buttons) | Out-Null
        $dlg.Content = $panel

        $loadProvider = {
            $id = $providerCombo.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($id) -or $null -eq $script:aiConfig -or $null -eq $script:aiConfig.providers) { return }
            $prop = $script:aiConfig.providers.PSObject.Properties[$id]
            if (-not $prop) { return }
            $p = $prop.Value
            $idBox.Text = $id
            $nameBox.Text = [string]$p.display_name
            $urlBox.Text = [string]$p.base_url
            if ($p.protocol) { $protocolCombo.SelectedItem = [string]$p.protocol }
            $keyBox.Password = [string]$p.api_key
            $keyPlain.Text = [string]$p.api_key
            $proxyBox.Text = if ($p.PSObject.Properties['proxy']) { [string]$p.proxy } else { '' }
            $modelCombo.Text = [string]$p.model
            $modelCombo.Items.Clear()
            foreach ($m in @($p.models)) { [void]$modelCombo.Items.Add($m) }
            $statusText.Text = "已载入提供方 $id"
        }
        $providerCombo.Add_SelectionChanged({ & $loadProvider })
        $providerCombo.Add_LostFocus({ & $loadProvider })

        $showKey.Add_Click({
            if ($showKey.IsChecked) {
                $keyPlain.Text = $keyBox.Password
                $keyPlain.Visibility = [System.Windows.Visibility]::Visible
                $keyBox.Visibility = [System.Windows.Visibility]::Collapsed
            }
            else {
                $keyBox.Password = $keyPlain.Text
                $keyPlain.Visibility = [System.Windows.Visibility]::Collapsed
                $keyBox.Visibility = [System.Windows.Visibility]::Visible
            }
        })
        $keyPlain.Add_TextChanged({ $keyBox.Password = $keyPlain.Text })

        $fetchBtn.Add_Click({
            $url = $urlBox.Text.Trim()
            $key = if ($keyBox.Visibility -eq [System.Windows.Visibility]::Visible) { $keyBox.Password } else { $keyPlain.Text }
            if ([string]::IsNullOrWhiteSpace($url)) { $statusText.Text = '先填 API 地址'; return }
            if ([string]::IsNullOrWhiteSpace($key)) { $statusText.Text = '先填 API 密钥——没密钥的请求会被服务商拒绝（401）'; return }
            $statusText.Text = '正在拉取模型列表…'
            $dlg.Cursor = [System.Windows.Input.Cursors]::Wait
            try {
                # 让拉取也用上当前面板里填的代理，而不是等保存之后
                $savedProvider = $script:aiProvider
                $script:aiProvider = [pscustomobject]@{ base_url = $url; api_key = $key; proxy = $proxyBox.Text.Trim() }
                try {
                    $r = Invoke-ModelsFetch $url $key ([string]$protocolCombo.SelectedItem)
                }
                finally { $script:aiProvider = $savedProvider }
                if ($r.ok) {
                    $modelCombo.Items.Clear()
                    foreach ($m in $r.models) { [void]$modelCombo.Items.Add($m) }
                    if ([string]::IsNullOrWhiteSpace($modelCombo.Text) -and $r.models.Count -gt 0) { $modelCombo.Text = $r.models[0] }
                    $statusText.Text = "拉到 $($r.models.Count) 个模型，从下拉里挑一个"
                    Write-Log "models fetched from $url : $($r.models.Count)"
                }
                else {
                    $statusText.Text = "拉取失败：$($r.message)"
                    Write-Log "models fetch failed from $url : $($r.message)"
                }
            }
            finally { $dlg.Cursor = [System.Windows.Input.Cursors]::Arrow }
        })

        $saveBtn.Add_Click({
            # 统一转小写，避免用户输入大写后与规则冲突（规则见 Test-ProviderId）
            $id = $idBox.Text.Trim().ToLower()
            if (-not (Test-ProviderId $id)) { $statusText.Text = 'Provider ID 不合规：要以小写字母开头，只能含小写字母、数字、连字符'; return }
            $url = $urlBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https?://') { $statusText.Text = 'API 地址要以 http:// 或 https:// 开头'; return }
            $key = if ($keyBox.Visibility -eq [System.Windows.Visibility]::Visible) { $keyBox.Password } else { $keyPlain.Text }
            if ([string]::IsNullOrWhiteSpace($key)) { $statusText.Text = 'API 密钥不能为空（本地服务随便填几个字符）'; return }
            $model = $modelCombo.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($model)) { $statusText.Text = '还没选模型：点「获取可用模型」或直接手输'; return }

            $models = @()
            foreach ($item in $modelCombo.Items) { $models += [string]$item }
            $display = if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { $id } else { $nameBox.Text.Trim() }

            $cfg = $script:aiConfig
            if ($null -eq $cfg) { $cfg = New-ConfigSkeleton | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
            if ($null -eq $cfg.providers) { $cfg | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force }
            $entry = [ordered]@{
                display_name = $display
                base_url     = $url
                protocol     = [string]$protocolCombo.SelectedItem
                api_key      = $key
                model        = $model
                models       = $models
                proxy        = $proxyBox.Text.Trim()
            }
            $cfg.providers | Add-Member -NotePropertyName $id -NotePropertyValue ($entry | ConvertTo-Json -Depth 6 | ConvertFrom-Json) -Force
            $cfg.active_provider = $id
            $cfg.enabled = $true
            if (-not $cfg.version) { $cfg | Add-Member -NotePropertyName version -NotePropertyValue 2 -Force }
            if (-not $cfg.max_tokens) { $cfg | Add-Member -NotePropertyName max_tokens -NotePropertyValue 120 -Force }
            if (-not $cfg.timeout_seconds) { $cfg | Add-Member -NotePropertyName timeout_seconds -NotePropertyValue 30 -Force }
            if (-not $cfg.system_prompt) { $cfg | Add-Member -NotePropertyName system_prompt -NotePropertyValue $defaultSystemPrompt -Force }
            Save-AiConfig $cfg
            Write-Log "provider saved: $id ($url, model=$model)"
            $dlg.Close()
        })
        $cancelBtn.Add_Click({ $dlg.Close() })

        # 打开时预填当前提供方
        if ($script:aiProvider) { & $loadProvider }
        elseif ($script:aiConfig -and $script:aiConfig.providers) {
            $first = @($script:aiConfig.providers.PSObject.Properties.Name) | Select-Object -First 1
            if ($first) { $providerCombo.Text = $first; & $loadProvider }
        }

        $dlg.ShowDialog() | Out-Null
        Reload-AiConfig
        Show-Bubble (Get-AiStatusText) 8000
    }

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
    # 点击她时显示的状态；余额有 60 秒缓存，避免连点就狂发请求
    $script:clickShowsStatus = $true
    $script:lastBalance = ''
    $script:balanceFetchedAt = [DateTime]::MinValue
    $script:balancePending = ''   # 必须是空字符串：布尔 $false 会被当成“有值”而显示成 False

    function Get-UsageText {
        if ($script:usage.calls -eq 0) { return '本次会话还没调用过' }
        $u = $script:usage
        $lastText = ''
        if ($null -ne $u.last) {
            $lastText = "  上次：入 $($u.last.prompt) / 出 $($u.last.completion)"
        }
        return "调用 $($u.calls) 次；输入 $($u.prompt) tokens，输出 $($u.completion) tokens，合计 $($u.total)$lastText"
    }

    function Get-UsageShort {
        $u = $script:usage
        if ($u.calls -eq 0) { return '还没聊过' }
        return "$($u.calls) 次 · 入 $($u.prompt) / 出 $($u.completion) · 共 $($u.total) tokens"
    }

    function Get-BalanceShort {
        if (-not [string]::IsNullOrWhiteSpace($script:balancePending)) { return $script:balancePending }
        if ([string]::IsNullOrWhiteSpace($script:lastBalance)) {
            if ($null -eq $script:aiProvider) { return '未配置提供方' }
            return '未查询'
        }
        $age = [int]((Get-Date) - $script:balanceFetchedAt).TotalSeconds
        return "$($script:lastBalance)（$age 秒前）"
    }

    function Show-PetStatus {
        # 点击她时调用：用量立刻显示，余额异步查询或走缓存
        if ($null -eq $script:aiProvider) {
            Show-Bubble "用量：$(Get-UsageShort)`n余额：未配置提供方（右键 → API 设置）" 9000
            return
        }
        $fresh = ((Get-Date) - $script:balanceFetchedAt).TotalSeconds -lt 60
        if ($fresh -and -not [string]::IsNullOrWhiteSpace($script:lastBalance)) {
            Show-Bubble "用量：$(Get-UsageShort)`n余额：$(Get-BalanceShort)" 10000
            return
        }
        $script:balancePending = '查询中…'
        Show-Bubble "用量：$(Get-UsageShort)`n余额：查询中…" 15000
        Start-BalanceQuery
    }

    # ── 余额查询：不同服务商接口不同，按 base_url 猜，猜不到就依次试 ──
    function Get-BalanceEndpoints {
        if ($null -eq $script:aiProvider) { return @() }
        $base = ([string]$script:aiProvider.base_url).TrimEnd('/')
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
        if ($script:httpBusy) {
            # 原来这里静默返回，气泡会一直停在“查询中…”，看起来像失败
            Show-Bubble '上一个请求还没结束，稍等一下再点' 5000
            return
        }
        $script:httpBusy = $true
        $script:httpTask = $null
        $script:balanceTried = @()
        try {
            $script:http = New-AiHttpClient
            $script:http.Timeout = [TimeSpan]::FromSeconds(15)
            $script:http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiProvider.api_key)
            $endpoints = @(Get-BalanceEndpoints)
            $script:balanceTried = @($endpoints)
            # 注意 @()：函数返回单元素数组会被 PowerShell 解包成字符串，
            # 那样 $endpoints[0] 取到的是第一个字符而不是第一个元素。
            $script:httpTask = $script:http.GetAsync($endpoints[0])
            $script:httpTaskKind = 'balance'
            $script:httpTaskQueue = @($endpoints | Select-Object -Skip 1)
            Show-Bubble '查询余额…' 20000
        }
        catch {
            $script:httpBusy = $false
            $script:balancePending = ''
            Write-Log "balance request failed: $($_.Exception.Message)"
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
                $script:balancePending = ''
                Show-Bubble "用量：$(Get-UsageShort)`n余额：该接口没有可用的余额端点" 9000
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
                $summary = $text.Substring(0, [Math]::Min(120, $text.Length))
            }
            $script:lastBalance = $summary
            $script:balanceFetchedAt = Get-Date
            $script:balancePending = ''
            Show-Bubble "用量：$(Get-UsageShort)`n余额：$summary" 12000
            Write-Log "balance ok: $text"
        }
        catch {
            $script:httpBusy = $false
            $script:balancePending = ''
            Show-Bubble "用量：$(Get-UsageShort)`n余额：解析失败" 9000
            Write-Log "balance parse failed: $($_.Exception.Message)"
        }
    }

    # ── 写代码 / 接 Agent ──
    # 三种引擎：对话模型（只写给你看）、Codex CLI（只读沙箱）、Codex/Claude CLI（可写）
    # 明确不使用 codex 的 --dangerously-bypass-approvals-and-sandbox
    $script:codeWindow = $null
    $script:codeOutputBox = $null
    $script:codeStatusText = $null
    $script:codePromptBox = $null
    $script:codeDirBox = $null
    $script:codeEngineCombo = $null
    $script:codeProc = $null
    $script:codeOutFile = ''
    $script:codeErrFile = ''
    $script:codeRunning = $false

    function Get-AgentExecutable([string]$Name) {
        $c = Get-Command $Name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        return $null
    }

    function Get-CodeEngines {
        $list = New-Object System.Collections.ArrayList
        [void]$list.Add('对话模型（只写代码，不改文件）')
        $codex = Get-AgentExecutable 'codex'
        if ($codex) {
            [void]$list.Add('Codex CLI（只读沙箱，不改文件）')
            [void]$list.Add('Codex CLI（可写工作目录，会改文件）')
        }
        $claude = Get-AgentExecutable 'claude'
        if ($claude) { [void]$list.Add('Claude CLI（print 模式）') }
        return $list.ToArray()
    }

    function Get-AgentWorkspace {
        $dir = Join-Path $scriptRoot 'agent-workspace'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        return $dir
    }

    function Show-CodeWindow {
        if ($null -ne $script:codeWindow) {
            $script:codeWindow.Show()
            $script:codeWindow.Activate()
            return
        }
        $win = New-Object System.Windows.Window
        $win.Title = '写代码 / 接 Agent'
        $win.Width = 720
        $win.Height = 620
        $win.Topmost = $false
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen

        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = New-Object System.Windows.Thickness(14)

        $lb1 = New-Object System.Windows.Controls.TextBlock
        $lb1.Text = '要写什么代码？（一句话说清需求）'
        $lb1.FontWeight = [System.Windows.FontWeights]::Bold
        $panel.Children.Add($lb1) | Out-Null
        $promptBox = New-Object System.Windows.Controls.TextBox
        $promptBox.AcceptsReturn = $true
        $promptBox.Height = 64
        $promptBox.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $promptBox.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $promptBox.Margin = New-Object System.Windows.Thickness(0, 4, 0, 8)
        $panel.Children.Add($promptBox) | Out-Null

        $row2 = New-Object System.Windows.Controls.DockPanel
        $engineCombo = New-Object System.Windows.Controls.ComboBox
        $engineCombo.Width = 320
        foreach ($e in Get-CodeEngines) { [void]$engineCombo.Items.Add($e) }
        $engineCombo.SelectedIndex = 0
        $engineLabel = New-Object System.Windows.Controls.TextBlock
        $engineLabel.Text = '引擎：'
        $engineLabel.VerticalAlignment = [System.Windows.HorizontalAlignment]::Center
        [System.Windows.Controls.DockPanel]::SetDock($engineLabel, [System.Windows.Controls.Dock]::Left)
        $row2.Children.Add($engineLabel) | Out-Null
        $row2.Children.Add($engineCombo) | Out-Null
        $panel.Children.Add($row2) | Out-Null

        $lb2 = New-Object System.Windows.Controls.TextBlock
        $lb2.Text = '工作目录（仅 CLI 引擎用到）'
        $lb2.Margin = New-Object System.Windows.Thickness(0, 8, 0, 2)
        $panel.Children.Add($lb2) | Out-Null
        $dirBox = New-Object System.Windows.Controls.TextBox
        $dirBox.Text = Get-AgentWorkspace
        $panel.Children.Add($dirBox) | Out-Null

        $runRow = New-Object System.Windows.Controls.StackPanel
        $runRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $runRow.Margin = New-Object System.Windows.Thickness(0, 10, 0, 6)
        $runBtn = New-Object System.Windows.Controls.Button
        $runBtn.Content = '开始'
        $runBtn.Width = 90
        $runBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $copyBtn = New-Object System.Windows.Controls.Button
        $copyBtn.Content = '复制结果'
        $copyBtn.Width = 90
        $copyBtn.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        $saveBtn = New-Object System.Windows.Controls.Button
        $saveBtn.Content = '保存为文件'
        $saveBtn.Width = 100
        $runRow.Children.Add($runBtn) | Out-Null
        $runRow.Children.Add($copyBtn) | Out-Null
        $runRow.Children.Add($saveBtn) | Out-Null
        $panel.Children.Add($runRow) | Out-Null

        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $statusText.Foreground = [System.Windows.Media.Brushes]::DimGray
        $statusText.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
        $panel.Children.Add($statusText) | Out-Null

        $outBox = New-Object System.Windows.Controls.TextBox
        $outBox.IsReadOnly = $true
        $outBox.AcceptsReturn = $true
        $outBox.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Cascadia Mono, monospace')
        $outBox.FontSize = 12
        $outBox.TextWrapping = [System.Windows.TextWrapping]::NoWrap
        $outBox.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $outBox.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $outBox.Height = 300
        $panel.Children.Add($outBox) | Out-Null

        $win.Content = $panel

        $copyBtn.Add_Click({
            if (-not [string]::IsNullOrWhiteSpace($outBox.Text)) {
                try { [System.Windows.Clipboard]::SetText($outBox.Text); $statusText.Text = '已复制到剪贴板' } catch { }
            }
        })
        $saveBtn.Add_Click({
            if ([string]::IsNullOrWhiteSpace($outBox.Text)) { return }
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.FileName = 'code.txt'
            $dlg.Filter = '文本 (*.txt)|*.txt|所有文件 (*.*)|*.*'
            if ($dlg.ShowDialog() -eq $true) {
                Set-Content -LiteralPath $dlg.FileName -Value $outBox.Text -Encoding UTF8
                $statusText.Text = "已保存：$($dlg.FileName)"
            }
        })
        $runBtn.Add_Click({ Start-CodeRun })

        $script:codeWindow = $win
        $script:codeOutputBox = $outBox
        $script:codeStatusText = $statusText
        $script:codePromptBox = $promptBox
        $script:codeDirBox = $dirBox
        $script:codeEngineCombo = $engineCombo
        $win.Add_Closed({ $script:codeWindow = $null; $script:codeOutputBox = $null })
        $win.Show() | Out-Null
    }

    function Start-CodeRun {
        if ($script:codeRunning) { return }
        $prompt = $script:codePromptBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($prompt)) { $script:codeStatusText.Text = '先写下需求'; return }
        $engine = [string]$script:codeEngineCombo.SelectedItem
        $dir = $script:codeDirBox.Text.Trim()
        $script:codeOutputBox.Text = ''
        $script:codeRunning = $true

        if ($engine -like '对话模型*') {
            if (-not $script:aiReady) { $script:codeStatusText.Text = (Get-AiStatusText); $script:codeRunning = $false; return }
            $script:codeStatusText.Text = "正在请求对话模型（$($script:aiProvider.model)）…"
            $sys = '你是一个严谨的程序员。只输出可直接使用的代码，必要时用一行文字说明用法。代码要完整可运行，不要省略。'
            $body = @{
                model      = $script:aiProvider.model
                messages   = @(
                    @{ role = 'system'; content = $sys },
                    @{ role = 'user'; content = $prompt }
                )
                max_tokens = 2000
            } | ConvertTo-Json -Depth 6
            try {
                $script:http = New-AiHttpClient
                $script:http.DefaultRequestHeaders.Authorization =
                    New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiProvider.api_key)
                $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
                $url = ([string]$script:aiProvider.base_url).TrimEnd('/') + '/chat/completions'
                $script:httpTask = $script:http.PostAsync($url, $content)
                $script:httpTaskKind = 'code'
            }
            catch {
                $script:codeStatusText.Text = "请求失败：$($_.Exception.Message)"
                $script:codeRunning = $false
            }
            return
        }

        # CLI 引擎
        $exe = $null; $args = @()
        if ($engine -like 'Codex CLI（只读*') {
            $exe = Get-AgentExecutable 'codex'
            $args = @('exec', '-C', $dir, '-s', 'read-only', '--skip-git-repo-check', $prompt)
        }
        elseif ($engine -like 'Codex CLI（可写*') {
            $exe = Get-AgentExecutable 'codex'
            $args = @('exec', '-C', $dir, '-s', 'workspace-write', '--skip-git-repo-check', $prompt)
        }
        elseif ($engine -like 'Claude CLI*') {
            $exe = Get-AgentExecutable 'claude'
            $args = @('-p', $prompt)
        }
        if (-not $exe) { $script:codeStatusText.Text = '找不到该引擎的可执行文件'; $script:codeRunning = $false; return }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { }
        }

        $stamp = [DateTime]::Now.ToString('HHmmss')
        $script:codeOutFile = Join-Path $env:TEMP "aemeath-agent-$stamp.out.txt"
        $script:codeErrFile = Join-Path $env:TEMP "aemeath-agent-$stamp.err.txt"
        $script:codeStatusText.Text = "正在运行：$([IO.Path]::GetFileName($exe)) $($args -join ' ')`n（agent 可能要跑一会儿，完成后结果会自动出现）"
        try {
            $script:codeProc = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $dir `
                -RedirectStandardOutput $script:codeOutFile -RedirectStandardError $script:codeErrFile `
                -NoNewWindow -PassThru
        }
        catch {
            $script:codeStatusText.Text = "启动失败：$($_.Exception.Message)"
            $script:codeRunning = $false
        }
    }

    function Complete-CodeRun {
        # 只负责 CLI 引擎；对话模型那条走 Complete-CodeChat
        $proc = $script:codeProc
        if ($null -eq $proc) { return }
        if (-not $proc.HasExited) {
            if ($null -ne $script:codeStatusText) { $script:codeStatusText.Text = '运行中…' }
            return
        }
        $script:codeRunning = $false
        $script:codeProc = $null
        $out = if (Test-Path -LiteralPath $script:codeOutFile) { Get-Content -LiteralPath $script:codeOutFile -Raw -Encoding UTF8 } else { '' }
        $err = if (Test-Path -LiteralPath $script:codeErrFile) { Get-Content -LiteralPath $script:codeErrFile -Raw -Encoding UTF8 } else { '' }
        $text = $out
        if (-not [string]::IsNullOrWhiteSpace($err)) { $text = "$out`n--- stderr ---`n$err" }
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "（没有输出；退出码 $($proc.ExitCode)）" }
        if ($null -ne $script:codeOutputBox) { $script:codeOutputBox.Text = $text }
        if ($null -ne $script:codeStatusText) { $script:codeStatusText.Text = "完成（退出码 $($proc.ExitCode)）" }
        Write-Log "agent finished exit=$($proc.ExitCode) out=$($script:codeOutFile)"
    }

    function Complete-CodeChat {
        if ($null -eq $script:httpTask) { return }
        if (-not $script:httpTask.IsCompleted) { return }
        $task = $script:httpTask
        $script:httpTask = $null
        $script:codeRunning = $false
        try {
            $response = $task.Result
            $text = $response.Content.ReadAsStringAsync().Result
            if (-not $response.IsSuccessStatusCode) {
                $script:codeStatusText.Text = "HTTP $([int]$response.StatusCode) — $(Get-AiErrorHint ([int]$response.StatusCode) $text)"
                if ($null -ne $script:codeOutputBox) { $script:codeOutputBox.Text = $text }
                return
            }
            $parsed = $text | ConvertFrom-Json
            $reply = [string]$parsed.choices[0].message.content
            if ($parsed.usage) {
                $p = [int]$parsed.usage.prompt_tokens
                $c = [int]$parsed.usage.completion_tokens
                $t = if ($parsed.usage.total_tokens) { [int]$parsed.usage.total_tokens } else { $p + $c }
                $script:usage.calls++; $script:usage.prompt += $p; $script:usage.completion += $c; $script:usage.total += $t
                $script:usage.last = [ordered]@{ prompt = $p; completion = $c; total = $t }
            }
            if ($null -ne $script:codeOutputBox) { $script:codeOutputBox.Text = $reply.Trim() }
            $script:codeStatusText.Text = "完成（$(Get-UsageShort)）"
        }
        catch {
            $script:codeStatusText.Text = "解析失败：$($_.Exception.Message)"
        }
    }
    function Get-AiStatusText() {
        if ($null -eq $script:aiConfig) { return 'AI：配置文件坏了' }
        if ($null -eq $script:aiProvider) { return 'AI：还没配置提供方（右键 → API 设置）' }
        if (-not $script:aiConfig.enabled) { return "AI：已配置 $($script:aiProvider._id) 但未启用" }
        if ([string]::IsNullOrWhiteSpace($script:aiProvider.api_key)) { return "AI：$($script:aiProvider._id) 还没填密钥" }
        return "AI：$($script:aiProvider.display_name)（$($script:aiProvider.model)）"
    }

    function Start-AiRequest([string]$UserText) {
        if (-not $script:aiReady) {
            Show-Bubble (Get-AiStatusText) 6000
            return
        }
        if ($script:httpBusy) {
            Show-Bubble '上一个请求还没结束，稍等一下' 5000
            return
        }
        $script:httpBusy = $true
        $script:httpTask = $null

        $messages = New-Object System.Collections.ArrayList
        [void]$messages.Add(@{ role = 'system'; content = $script:aiConfig.system_prompt })
        foreach ($turn in $script:history) { [void]$messages.Add($turn) }
        [void]$messages.Add(@{ role = 'user'; content = $UserText })

        $body = @{
            model      = $script:aiProvider.model
            messages   = $messages.ToArray()
            max_tokens = [int]$script:aiConfig.max_tokens
        } | ConvertTo-Json -Depth 6

        try {
            $script:http = New-AiHttpClient
            $script:http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiProvider.api_key)
            $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
            $url = ([string]$script:aiProvider.base_url).TrimEnd('/') + '/chat/completions'
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
    # 显示尺寸按交付格式的 192x208 乘以缩放；高清图集在这个尺寸下接近 1:1，所以清晰
    # 用 script 作用域，运行时的缩放功能才能改到它们
    $script:scale = $Scale
    $script:displayW = $BaseCellW * $script:scale
    $script:displayH = $BaseCellH * $script:scale
    $displayW = $script:displayW
    $displayH = $script:displayH

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

    # ── 电子幽灵模式：用运行时效果实现，不需要新素材 ──
    $script:ghostMode = $false
    $script:ghostPhase = 0.0
    $script:ghostFlicker = 0
    $script:ghostGlow = $null
    $script:ghostTransform = $null

    function Set-GhostMode([bool]$On) {
        $script:ghostMode = $On
        if ($null -eq $script:ghostTransform) {
            $script:ghostTransform = New-Object System.Windows.Media.TranslateTransform
            $image.RenderTransform = $script:ghostTransform
        }
        if ($On) {
            # 青色辉光：ShadowDepth=0 的投影就相当于外发光
            $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
            $glow.Color = [System.Windows.Media.Color]::FromRgb(90, 230, 255)
            $glow.BlurRadius = 26
            $glow.ShadowDepth = 0
            $glow.Opacity = 0.95
            $script:ghostGlow = $glow
            $image.Effect = $glow
            $image.Opacity = 0.78
            Play-Sound 'ghost'
            Show-Bubble '电子幽灵形态…' 5000
        }
        else {
            $image.Effect = $null
            $image.Opacity = 1.0
            $script:ghostTransform.X = 0
            $script:ghostTransform.Y = 0
            $script:ghostGlow = $null
        }
        Write-Log "ghost mode = $On"
    }

    function Update-GhostEffect {
        if (-not $script:ghostMode) { return }
        $script:ghostPhase += 0.16
        # 上下漂浮
        $script:ghostTransform.Y = [Math]::Sin($script:ghostPhase) * 5
        $script:ghostTransform.X = [Math]::Sin($script:ghostPhase * 0.6) * 2
        # 呼吸式明暗
        $base = 0.72 + 0.16 * [Math]::Sin($script:ghostPhase * 0.5)
        # 偶发闪烁
        if ($script:ghostFlicker -gt 0) {
            $script:ghostFlicker--
            $base = 0.28
        }
        elseif ($script:random.Next(0, 220) -lt 1) {
            $script:ghostFlicker = 2
        }
        $image.Opacity = [Math]::Max(0.2, [Math]::Min(0.95, $base))
    }
    # ── 表情编排：用已有的帧组合出新动作，不需要重新生成素材 ──
    $script:emoteQueue = @()
    $script:emoteIndex = 0
    $script:emoteTicks = 0
    $script:emoteName = ''
    $script:sleeping = $false
    $script:cuteLines = @(
        '在的呀～', '（眨眨眼）', '今天也要加油哦', '嗯…在想事情',
        '你忙你的，我看着', '（晃了晃发梢）', '呜…有点困', '要不要休息一下？'
    )

    function Start-Emote([string]$Name) {
        $steps = New-Object System.Collections.ArrayList
        switch ($Name) {
            'nod' {
                # 点头：低头抬头交替
                foreach ($i in 1..3) {
                    [void]$steps.Add(@{ row = 10; col = 0; ticks = 2 })
                    [void]$steps.Add(@{ row = 9; col = 0; ticks = 2 })
                }
            }
            'shake' {
                # 摇头：左右交替
                foreach ($i in 1..3) {
                    [void]$steps.Add(@{ row = 9; col = 4; ticks = 2 })
                    [void]$steps.Add(@{ row = 10; col = 4; ticks = 2 })
                }
            }
            'spin' {
                # 转圈：把 16 个方向快速走一遍，再晕一下
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 9; col = $c; ticks = 1 }) }
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 10; col = $c; ticks = 1 }) }
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 5; col = $c; ticks = 2 }) }
            }
            'cute' {
                # 卖萌：跳一下再挥手
                foreach ($c in 0..4) { [void]$steps.Add(@{ row = 4; col = $c; ticks = 3 }) }
                foreach ($c in 0..3) { [void]$steps.Add(@{ row = 3; col = $c; ticks = 3 }) }
            }
            'dance' {
                # 跳舞：左右摆动 + 挥手 + 跳
                foreach ($i in 1..2) {
                    [void]$steps.Add(@{ row = 9; col = 4; ticks = 2 })
                    [void]$steps.Add(@{ row = 3; col = 0; ticks = 2 })
                    [void]$steps.Add(@{ row = 10; col = 4; ticks = 2 })
                    [void]$steps.Add(@{ row = 3; col = 2; ticks = 2 })
                    [void]$steps.Add(@{ row = 4; col = 1; ticks = 2 })
                    [void]$steps.Add(@{ row = 4; col = 3; ticks = 2 })
                }
            }
            'stretch' {
                # 伸懒腰：慢慢转一圈再回到正面
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 9; col = $c; ticks = 2 }) }
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 10; col = $c; ticks = 2 }) }
            }
            'haunt' {
                # 幽灵飘：目光缓慢扫过一圈，配合幽灵模式的漂浮与辉光
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 9; col = $c; ticks = 3 }) }
                foreach ($c in 0..7) { [void]$steps.Add(@{ row = 10; col = $c; ticks = 3 }) }
            }
            'glitch' {
                # 数据抖动：在几个方向之间快速跳
                foreach ($i in 1..6) {
                    [void]$steps.Add(@{ row = 9; col = $script:random.Next(0, 8); ticks = 1 })
                    [void]$steps.Add(@{ row = 10; col = $script:random.Next(0, 8); ticks = 1 })
                }
            }
            default { return }
        }
        $script:emoteQueue = $steps.ToArray()
        $script:emoteIndex = 0
        $script:emoteTicks = 0
        $script:emoteName = $Name
        $script:mode = 'emote'
        $script:sleeping = $false
        switch ($Name) {
            'nod' { Play-Sound 'step' }
            'shake' { Play-Sound 'step' }
            'spin' { Play-Sound 'review' }
            'cute' { Play-Sound 'hello' }
            'dance' { Play-Sound 'jump' }
            'stretch' { Play-Sound 'chirp' }
            'haunt' { Play-Sound 'ghost' }
            'glitch' { Play-Sound 'ghost' }
        }
    }

    function Start-Sleep2 {
        $script:sleeping = $true
        $script:mode = 'sleep'
        $script:frameTick = 0
        Show-Bubble 'Zzz…' 4000
        Play-Sound 'chirp'
    }

    function Wake-Up {
        if (-not $script:sleeping) { return }
        $script:sleeping = $false
        $script:mode = 'idle'
        $script:frameTick = 0
        $script:col = 0
        $script:idleTicks = 0
        $script:nextDecision = $script:random.Next(14, 40)
        Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello'
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

        # AI 请求 / 余额查询 / 写代码 轮询 + 气泡自动收起（放在最前面，任何状态下都要生效）
        if ($null -ne $script:httpTask -and $script:httpTask.IsCompleted) {
            if ($script:httpTaskKind -eq 'balance') { Complete-BalanceQuery }
            elseif ($script:httpTaskKind -eq 'code') { Complete-CodeChat }
            else { Complete-AiRequest }
        }
        if ($script:codeRunning) { Complete-CodeRun }

        # 幽灵模式的漂浮、辉光呼吸与偶发闪烁
        if ($script:ghostMode) { Update-GhostEffect }
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

        if ($script:mode -eq 'emote') {
            Set-FrameInterval $OneShotFrameMs
            if ($script:emoteIndex -ge $script:emoteQueue.Count) {
                $script:mode = 'idle'
                $script:frameTick = 0
                $script:col = 0
                $script:idleTicks = 0
                $script:nextDecision = $script:random.Next(14, 40)
                return
            }
            $step = $script:emoteQueue[$script:emoteIndex]
            Show-Cell $step.row $step.col
            $script:emoteTicks++
            if ($script:emoteTicks -ge $step.ticks) {
                $script:emoteTicks = 0
                $script:emoteIndex++
            }
            return
        }

        if ($script:mode -eq 'sleep') {
            # 睡觉：停在闭眼那一帧，偶尔冒个 Zzz；点她或拖她就会醒
            Set-FrameInterval 400
            Show-Cell $RowIdle 1
            if ($script:frameTick % 10 -eq 0) { Show-Bubble 'Zzz…' 2500 }
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
                if ($roll -lt 45) { Start-Walk; return }
                elseif ($roll -lt 58) { Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello'; return }
                elseif ($roll -lt 66) { Start-OneShot $RowJump ($rowFrames[$RowJump] * 3) 'jump'; return }
                elseif ($roll -lt 71) { Start-OneShot $RowReview ($rowFrames[$RowReview] * 3) 'review'; return }
                elseif ($roll -lt 76) { Start-Emote 'nod'; return }
                elseif ($roll -lt 80) { Start-Emote 'shake'; return }
                elseif ($roll -lt 84) { Start-Emote 'cute'; return }
                elseif ($roll -lt 87) { Start-Emote 'dance'; return }
                elseif ($roll -lt 89) { Start-Emote 'stretch'; return }
                elseif ($roll -lt 91) { Start-Emote 'spin'; return }
                elseif ($roll -lt 92 -and $script:canEat) { Invoke-Eat; return }
                elseif ($roll -lt 95) {
                    # 偶尔冒一句可爱的话
                    Show-Bubble ($script:cuteLines[$script:random.Next(0, $script:cuteLines.Count)]) 5000
                    $script:nextDecision = $script:random.Next(14, 40)
                }
                else { $script:nextDecision = $script:random.Next(14, 40) }
            }
            if ($script:random.Next(0, 1000) -lt 4) { Play-Sound 'chirp' }
        }

        $center = Get-PetCenterOnScreen
        $cursor = [System.Windows.Forms.Cursor]::Position
        $dx = $cursor.X - $center.X
        $dy = $cursor.Y - $center.Y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)

        if ($script:followMouse -and $distance -gt ($script:displayH * 0.9)) {
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
        if ($script:sleeping) { Wake-Up }
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
            if ($script:sleeping) {
                Wake-Up
            }
            else {
                Start-OneShot $RowWave ($rowFrames[$RowWave] * 3) 'hello'
                if ($script:clickShowsStatus) { Show-PetStatus }
                else { Say-Something ($lines[$script:random.Next(0, $lines.Count)]) }
            }
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

    # ── 设置持久化与运行时缩放 ──
    $script:settingsPath = Join-Path $scriptRoot 'pet-settings.json'

    function Get-PetSettings {
        if (-not (Test-Path -LiteralPath $script:settingsPath -PathType Leaf)) { return $null }
        try { return Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Log "settings 解析失败：$($_.Exception.Message)"; return $null }
    }

    function Save-PetSettings {
        try {
            [ordered]@{
                scale            = $script:scale
                roam             = [bool]$script:roam
                sound            = [bool]$script:soundOn
                speak            = [bool]$script:speakOn
                clickShowsStatus = [bool]$script:clickShowsStatus
                ghostMode        = [bool]$script:ghostMode
                canEat           = [bool]$script:canEat
                eatRealMode      = [bool]$script:eatRealMode
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
        }
        catch { Write-Log "settings 保存失败：$($_.Exception.Message)" }
    }

    function Apply-Scale([double]$NewScale, [switch]$Quiet) {
        # 夹在 0.5 ~ 4 倍之间，并保持底部中心不动，缩放时她不会“跳”走
        $s = [Math]::Round([Math]::Max(0.5, [Math]::Min(4.0, $NewScale)), 2)
        if ([Math]::Abs($s - $script:scale) -lt 0.001) {
            if (-not $Quiet) { Show-Bubble "已经是 $s 倍（范围 0.5 ~ 4）" 3000 }
            return
        }
        $bottom = $window.Top + $window.Height
        $centerX = $window.Left + $window.Width / 2
        $script:scale = $s
        $script:displayW = $BaseCellW * $s
        $script:displayH = $BaseCellH * $s
        $window.Width = $script:displayW
        $window.Height = $script:displayH
        $image.Width = $script:displayW
        $image.Height = $script:displayH
        $window.Left = $centerX - $script:displayW / 2
        $window.Top = $bottom - $script:displayH
        $script:centerCache = $null      # 跟随鼠标的距离阈值要按新尺寸重算
        if (-not $Quiet) { Show-Bubble "大小：$s 倍" 3000 }
        Save-PetSettings
    }

    function Step-Scale([double]$Factor) {
        Apply-Scale ($script:scale * $Factor)
    }

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
    Add-MenuItem '写代码 / 接 Agent…' { Show-CodeWindow } | Out-Null
    Add-MenuItem 'API 设置…（自定义提供方）' { Show-ApiSettings } | Out-Null
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
    Add-MenuItem '诊断：直接测余额' {
        # 绕开界面状态，直接测一次，并把原始返回写进日志
        if ($null -eq $script:aiProvider) { Show-Bubble '未配置提供方' 5000; return }
        Show-Bubble '正在直接查询余额…' 15000
        try {
            $url = @(Get-BalanceEndpoints)[0]
            $r = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $($script:aiProvider.api_key)" } -Method Get -TimeoutSec 20
            $sum = ''
            if ($r.balance_infos) { $sum = ($r.balance_infos | ForEach-Object { "$($_.total_balance) $($_.currency)" }) -join ' / ' }
            elseif ($r.balance) { $sum = "$($r.balance)" }
            if ([string]::IsNullOrWhiteSpace($sum)) { $sum = ($r | ConvertTo-Json -Depth 4 -Compress) }
            Write-Log "balance direct ok: $url -> $sum"
            Show-Bubble "余额：$sum" 12000
        }
        catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            Write-Log "balance direct failed: $url $code $($_.Exception.Message)"
            Show-Bubble "查询失败：$(Get-AiErrorHint $code $_.Exception.Message)" 9000
        }
    } | Out-Null
    Add-MenuItem '点击显示用量与余额' { $script:clickShowsStatus = $clickStatusItem.IsChecked } $true $script:clickShowsStatus | Out-Null
    $clickStatusItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '打开 AI 配置（记事本）' {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList $configPath } catch { }
        Show-Bubble '改完记得点「重新载入 AI 配置」' 6000
    } | Out-Null
    Add-MenuItem '重新载入 AI 配置' {
        Reload-AiConfig
        Show-Bubble (Get-AiStatusText) 6000
    } | Out-Null
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    Add-MenuItem '点点头' { Start-Emote 'nod' } | Out-Null
    Add-MenuItem '摇摇头' { Start-Emote 'shake' } | Out-Null
    Add-MenuItem '转圈圈（然后晕）' { Start-Emote 'spin' } | Out-Null
    Add-MenuItem '卖个萌' { Start-Emote 'cute' } | Out-Null
    Add-MenuItem '跳支舞' { Start-Emote 'dance' } | Out-Null
    Add-MenuItem '伸个懒腰' { Start-Emote 'stretch' } | Out-Null
    Add-MenuItem '幽灵飘一圈' { Start-Emote 'haunt' } | Out-Null
    Add-MenuItem '数据抖动' { Start-Emote 'glitch' } | Out-Null
    Add-MenuItem '电子幽灵模式' {
        Set-GhostMode $ghostItem.IsChecked
    } $true $script:ghostMode | Out-Null
    $ghostItem = $menu.Items[$menu.Items.Count - 1]
    Add-MenuItem '去睡觉（点她唤醒）' { Start-Sleep2 } | Out-Null
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
    Add-MenuItem '放大（滚轮上）' { Step-Scale 1.25 } | Out-Null
    Add-MenuItem '缩小（滚轮下）' { Step-Scale 0.8 } | Out-Null
    Add-MenuItem '恢复默认大小' { Apply-Scale 2.0 } | Out-Null
    Add-MenuItem '退出' { $window.Close() } | Out-Null
    $window.ContextMenu = $menu

    # 滚轮缩放：鼠标在她身上滚即可（窗口获得焦点时生效）
    $window.Add_MouseWheel({
        if ($_.Delta -gt 0) { Step-Scale 1.25 } else { Step-Scale 0.8 }
        $_.Handled = $true
    })

    # ── 载入上次保存的设置 ──
    $saved = Get-PetSettings
    if ($null -ne $saved) {
        if ($saved.PSObject.Properties['sound'] -and -not $Mute) {
            $script:soundOn = [bool]$saved.sound
            $soundItem.IsChecked = $script:soundOn
        }
        if ($saved.PSObject.Properties['speak']) {
            $script:speakOn = [bool]$saved.speak
            $speakItem.IsChecked = $script:speakOn
        }
        if ($saved.PSObject.Properties['roam'] -and -not $NoRoam) {
            $script:roam = [bool]$saved.roam
            $roamItem.IsChecked = $script:roam
        }
        if ($saved.PSObject.Properties['clickShowsStatus']) {
            $script:clickShowsStatus = [bool]$saved.clickShowsStatus
            $clickStatusItem.IsChecked = $script:clickShowsStatus
        }
        if ($saved.PSObject.Properties['ghostMode'] -and [bool]$saved.ghostMode) {
            $ghostItem.IsChecked = $true
            Set-GhostMode $true
        }
        if ($saved.PSObject.Properties['canEat']) {
            $script:canEat = [bool]$saved.canEat
            $eatItem.IsChecked = $script:canEat
        }
        if ($saved.PSObject.Properties['eatRealMode']) {
            $script:eatRealMode = [bool]$saved.eatRealMode
            $realEatItem.IsChecked = $script:eatRealMode
        }
        if ($saved.PSObject.Properties['scale']) { Apply-Scale ([double]$saved.scale) -Quiet }
        Write-Log "settings loaded: scale=$($script:scale) roam=$($script:roam) sound=$($script:soundOn)"
    }

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
        # 表情编排自检：每种都排一遍，确认步数与用到的帧都在图集范围内
        $emoteReport = @()
        foreach ($name in @('nod', 'shake', 'spin', 'cute', 'dance', 'stretch', 'haunt', 'glitch')) {
            Start-Emote $name
            $bad = @($script:emoteQueue | Where-Object { $_.row -lt 0 -or $_.row -gt 10 -or $_.col -lt 0 -or $_.col -gt 7 })
            $emoteReport += "$name=$($script:emoteQueue.Count)步$(if ($bad.Count -gt 0) { '(越界!)' } else { '' })"
        }
        $script:mode = 'idle'
        Start-Sleep2
        $sleepOk = $script:sleeping
        Wake-Up
        $wakeOk = -not $script:sleeping
        $script:mode = 'idle'
        # 写代码 / Agent 自检：只列出可用引擎与工作目录，不启动任何 agent
        $engines = Get-CodeEngines
        $workspace = Get-AgentWorkspace
        $codeReport = "engines=$($engines.Count)[$($engines -join ' | ')] workspace_exists=$(Test-Path $workspace)"
        "SELFTEST_OK atlas=$(Split-Path $atlasPath -Leaf) cell=${CellWidth}x${CellHeight} cards=$($cells.Length) sounds=$($players.Count) scale=$($script:scale) disp=$($script:displayW)x$($script:displayH) walk_moved_px=$moved window=$($window.Width)x$($window.Height) ai=$($script:aiReady) bubble_ok=$([bool]$bubbleText) desktop_lnk=$shortcutCount belly=$bellyCount leftover_restored=$($script:leftoverRestored) usage='$(Get-UsageShort)' balance='$(Get-BalanceShort)' click_status=$($script:clickShowsStatus) emotes=[$($emoteReport -join ' ')] sleep_wake=$($sleepOk -and $wakeOk) code=$codeReport"
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

    if ($ValidateProviderId -ne '') {
        "规则：以小写字母开头，只能含小写字母、数字、连字符  ^[a-z][a-z0-9-]*$"
        foreach ($sample in @($ValidateProviderId, 'acme-gateway', 'Acme', '1abc', 'my_relay', 'a')) {
            $ok = Test-ProviderId $sample
            "  '{0}' -> {1}" -f $sample, $(if ($ok) { '通过' } else { '拒绝' })
        }
        exit 0
    }

    if ($ListModels) {
        if ($null -eq $script:aiProvider) { 'FAILED 还没配置提供方（右键 → API 设置）'; exit 2 }
        "提供方：$($script:aiProvider._id)  $($script:aiProvider.base_url)"
        if ([string]::IsNullOrWhiteSpace($script:aiProvider.api_key)) { 'FAILED 未填密钥'; exit 2 }
        $r = Invoke-ModelsFetch $script:aiProvider.base_url $script:aiProvider.api_key $script:aiProvider.protocol
        if ($r.ok) {
            "拉到 $($r.models.Count) 个模型："
            $r.models | ForEach-Object { "  $_" }
            'LISTMODELS_OK'
            exit 0
        }
        "拉取失败：$($r.message)"
        'LISTMODELS_FAILED'
        exit 1
    }

    if ($TestBalance) {
        if ($null -eq $script:aiProvider) { 'FAILED 还没配置提供方'; exit 2 }
        # @() 必须加：单元素数组会被解包成字符串，直接取 [0] 会拿到第一个字符
        $endpoints = @(Get-BalanceEndpoints)
        "提供方：$($script:aiProvider._id)  $($script:aiProvider.base_url)"
        "端点候选（$($endpoints.Count) 个）：$($endpoints -join '  ,  ')"
        foreach ($ep in $endpoints) {
            "尝试：$ep"
            try {
                $r = Invoke-RestMethod -Uri $ep -Headers @{ Authorization = "Bearer $($script:aiProvider.api_key)" } -Method Get -TimeoutSec 20
                $sum = ''
                if ($r.balance_infos) { $sum = ($r.balance_infos | ForEach-Object { "$($_.total_balance) $($_.currency)" }) -join ' / ' }
                elseif ($r.balance) { $sum = "$($r.balance)" }
                elseif ($r.data -and $r.data.balance) { $sum = "$($r.data.balance)" }
                if ([string]::IsNullOrWhiteSpace($sum)) { $sum = ($r | ConvertTo-Json -Depth 4 -Compress) }
                "余额：$sum"
                'TESTBALANCE_OK'
                exit 0
            }
            catch {
                $code = 0
                try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                "  失败：$(Get-AiErrorHint $code $_.Exception.Message)"
            }
        }
        'TESTBALANCE_FAILED'
        exit 1
    }

    if ($TestAi) {
        "AI 配置文件：$configPath"
        if ($null -eq $script:aiConfig) { "FAILED 配置无法解析"; exit 1 }
        "  enabled = $($script:aiConfig.enabled)"
        "  提供方数量 = $(@($script:aiConfig.providers.PSObject.Properties.Name).Count)"
        "  当前提供方 = $(if ($script:aiProvider) { $script:aiProvider._id } else { '(无)' })"
        if ($script:aiProvider) {
            "    display_name = $($script:aiProvider.display_name)"
            "    protocol = $($script:aiProvider.protocol)"
            "    base_url = $($script:aiProvider.base_url)"
            "    model = $($script:aiProvider.model)"
            "    api_key = $(if ([string]::IsNullOrWhiteSpace($script:aiProvider.api_key)) { '(空)' } else { '已填写（长度 ' + $script:aiProvider.api_key.Length + '）' })"
            "    proxy = $(if ($script:aiProvider.PSObject.Properties['proxy'] -and -not [string]::IsNullOrWhiteSpace($script:aiProvider.proxy)) { $script:aiProvider.proxy } else { '(跟随系统)' })"
        }
        "  余额端点（按服务商推断，失败会自动依次重试）= $(Get-BalanceEndpoints -join '  ->  ')"
        if (-not $script:aiReady) { "SKIPPED 未启用或未选提供方或未填密钥；右键 → API 设置"; exit 2 }
        $messages = @(
            @{ role = 'system'; content = $script:aiConfig.system_prompt },
            @{ role = 'user'; content = $TestAiPrompt }
        )
        $body = @{ model = $script:aiProvider.model; messages = $messages; max_tokens = [int]$script:aiConfig.max_tokens } | ConvertTo-Json -Depth 6
        try {
            $testClient = New-AiHttpClient
            $testClient.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:aiProvider.api_key)
            $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
            $url = ([string]$script:aiProvider.base_url).TrimEnd('/') + '/chat/completions'
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
        try { Save-PetSettings } catch { }
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
