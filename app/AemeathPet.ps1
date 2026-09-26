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
    [switch]$SelfTest,
    [int]$PerfTest = 0
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$atlasPath = Join-Path $scriptRoot 'spritesheet.png'
$soundDir = Join-Path $scriptRoot 'sounds'
$logPath = Join-Path $scriptRoot 'aemeath-pet.log'

function Write-Log([string]$Message) {
    try { "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8 } catch { }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

    if (-not (Test-Path -LiteralPath $atlasPath -PathType Leaf)) { throw "找不到图集：$atlasPath" }

    $CellWidth = 192
    $CellHeight = 208
    $RowIdle = 0; $RowRight = 1; $RowLeft = 2; $RowWave = 3; $RowJump = 4
    $RowFail = 5; $RowWait = 6; $RowWork = 7; $RowReview = 8

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = New-Object System.Uri($atlasPath)
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()
    if ($bitmap.PixelWidth -ne ($CellWidth * 8) -or $bitmap.PixelHeight -ne ($CellHeight * 11)) {
        throw "图集尺寸异常：$($bitmap.PixelWidth)x$($bitmap.PixelHeight)，期望 1536x2288"
    }

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

    # ── 窗口 ──
    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.Width = $CellWidth * $Scale
    $window.Height = $CellHeight * $Scale

    $image = New-Object System.Windows.Controls.Image
    $image.Width = $CellWidth * $Scale
    $image.Height = $CellHeight * $Scale
    $image.Stretch = [System.Windows.Media.Stretch]::Fill
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::LowQuality)
    $image.Source = $cells[0, 0]
    $window.Content = $image

    $script:work = [System.Windows.SystemParameters]::WorkArea
    $script:floorTop = $script:work.Bottom - $window.Height - 24
    $window.Left = $script:work.Right - $window.Width - 60
    $window.Top = $script:floorTop

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
                else { $script:nextDecision = $script:random.Next(14, 40) }
            }
            if ($script:random.Next(0, 1000) -lt 4) { Play-Sound 'chirp' }
        }

        $center = Get-PetCenterOnScreen
        $cursor = [System.Windows.Forms.Cursor]::Position
        $dx = $cursor.X - $center.X
        $dy = $cursor.Y - $center.Y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)

        if ($script:followMouse -and $distance -gt ($CellHeight * $Scale * 0.9)) {
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
    Add-MenuItem '看向鼠标' { $script:followMouse = -not $script:followMouse } | Out-Null
    Add-MenuItem '回到右下角' { $window.Left = $script:work.Right - $window.Width - 60; $window.Top = $script:floorTop } | Out-Null
    Add-MenuItem '退出' { $window.Close() } | Out-Null
    $window.ContextMenu = $menu

    if ($SelfTest) {
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        Start-OneShot $RowWave 12 'hello'
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        $script:roam = $false
        $before = $window.Left
        $script:roam = $true
        Start-Walk
        for ($i = 0; $i -lt 20; $i++) { Update-Frame }
        $moved = [Math]::Abs($window.Left - $before)
        "SELFTEST_OK cells=$($cells.Length) sounds=$($players.Count) scale=$Scale walk_moved_px=$moved window=$($window.Width)x$($window.Height)"
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

    Write-Log "started (sounds=$($players.Count) roam=$($script:roam))"
    $window.Add_Closed({
        Write-Log 'closed'
        $timer.Stop()
        if ($null -ne $synth) { try { $synth.Dispose() } catch { } }
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
