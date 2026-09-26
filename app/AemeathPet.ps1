# 爱弥斯 v2 桌面宠 —— 双击即用，零安装（依赖 Windows 自带的 WPF）
#
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File AemeathPet.ps1
#   或直接双击「启动爱弥斯.vbs」（无控制台闪窗）
#
# 交互：
#   拖动        移动位置，并播放朝左/朝右的跑动
#   双击        挥手
#   右键        菜单：挥手 / 跳一下 / 失败一下 / 工作一下 / 看向鼠标开关 / 退出
#   鼠标移动    她会用 16 个方向里的对应方向看向你的鼠标

[CmdletBinding()]
param(
    [double]$Scale = 2.0,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$atlasPath = Join-Path $scriptRoot 'spritesheet.png'
$logPath = Join-Path $scriptRoot 'aemeath-pet.log'

function Write-Log([string]$Message) {
    try { "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8 } catch { }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

    if (-not (Test-Path -LiteralPath $atlasPath -PathType Leaf)) { throw "找不到图集：$atlasPath" }

    $CellWidth = 192
    $CellHeight = 208

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.UriSource = New-Object System.Uri($atlasPath)
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.EndInit()
    $bitmap.Freeze()

    if ($bitmap.PixelWidth -ne ($CellWidth * 8) -or $bitmap.PixelHeight -ne ($CellHeight * 11)) {
        throw "图集尺寸异常：$($bitmap.PixelWidth)x$($bitmap.PixelHeight)，期望 1536x2288"
    }

    # 预先把 11x8 个格子都裁好，切换时零开销
    $cells = New-Object 'object[,]' 11, 8
    for ($r = 0; $r -lt 11; $r++) {
        for ($c = 0; $c -lt 8; $c++) {
            $rect = New-Object System.Windows.Int32Rect(($c * $CellWidth), ($r * $CellHeight), $CellWidth, $CellHeight)
            $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($bitmap, $rect)
            $crop.Freeze()
            $cells[$r, $c] = $crop
        }
    }

    # 行 -> 帧数
    $rowFrames = @{ 0 = 6; 1 = 8; 2 = 8; 3 = 4; 4 = 5; 5 = 8; 6 = 6; 7 = 6; 8 = 6; 9 = 8; 10 = 8 }

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
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $image.Source = $cells[0, 0]
    $window.Content = $image

    $work = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $work.Right - $window.Width - 40
    $window.Top = $work.Bottom - $window.Height - 60

    # 状态机
    $script:mode = 'idle'        # idle | look | oneshot | drag
    $script:row = 0
    $script:col = 0
    $script:frameTick = 0
    $script:oneshotLeft = 0
    $script:followMouse = $true
    $script:dragging = $false
    $script:dragOrigin = $null
    $script:windowOrigin = $null
    $script:movedDuringDrag = $false

    function Show-Cell([int]$Row, [int]$Col) {
        $image.Source = $cells[$Row, $Col]
    }

    function Start-OneShot([int]$Row, [int]$Ticks) {
        $script:mode = 'oneshot'
        $script:row = $Row
        $script:col = 0
        $script:frameTick = 0
        $script:oneshotLeft = $Ticks
        Show-Cell $Row 0
    }

    function Get-LookCell([double]$AngleDegrees) {
        # 0 度 = 正上方，顺时针；16 个方向按 22.5 度一档
        $index = [int][Math]::Floor((($AngleDegrees + 11.25) / 22.5)) % 16
        if ($index -lt 0) { $index += 16 }
        if ($index -lt 8) { return @(9, $index) } else { return @(10, ($index - 8)) }
    }

    function Get-PetCenterOnScreen() {
        # 窗口已显示时用 PointToScreen（正确处理 DPI 缩放）；未显示时回退到 Left/Top 推算。
        try {
            return $window.PointToScreen((New-Object System.Windows.Point(($window.Width / 2), ($window.Height / 2))))
        }
        catch {
            return (New-Object System.Windows.Point(($window.Left + $window.Width / 2), ($window.Top + $window.Height / 2)))
        }
    }

    function Update-Frame() {
        $script:frameTick++

        if ($script:mode -eq 'drag') {
            $row = if ($script:dragDirection -ge 0) { 1 } else { 2 }
            $frames = $rowFrames[$row]
            $script:col = ($script:frameTick % $frames)
            Show-Cell $row $script:col
            return
        }

        if ($script:mode -eq 'oneshot') {
            if ($script:frameTick % 3 -eq 0) { $script:col++ }
            if ($script:col -ge $rowFrames[$script:row]) {
                $script:mode = 'idle'
                $script:row = 0
                $script:col = 0
                $script:frameTick = 0
                return
            }
            Show-Cell $script:row $script:col
            return
        }

        # 空闲：近处做待机动画，远处用 16 方向看向鼠标
        $center = Get-PetCenterOnScreen
        $cursor = [System.Windows.Forms.Cursor]::Position
        $dx = $cursor.X - $center.X
        $dy = $cursor.Y - $center.Y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)

        if ($script:followMouse -and $distance -gt ($CellHeight * $Scale * 0.9)) {
            $angle = [Math]::Atan2($dx, -$dy) * 180.0 / [Math]::PI
            if ($angle -lt 0) { $angle += 360 }
            $cell = Get-LookCell $angle
            Show-Cell $cell[0] $cell[1]
            return
        }

        if ($script:frameTick % 6 -eq 0) { $script:col++ }
        if ($script:col -ge $rowFrames[0]) { $script:col = 0 }
        Show-Cell 0 $script:col
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(130)
    $timer.Add_Tick({ Update-Frame })

    # 拖动
    $window.Add_MouseLeftButtonDown({
        $script:dragging = $true
        $script:movedDuringDrag = $false
        $script:dragOrigin = [System.Windows.Forms.Cursor]::Position
        $script:windowOrigin = New-Object System.Windows.Point($window.Left, $window.Top)
        $window.CaptureMouse() | Out-Null
    })
    $window.Add_MouseMove({
        if (-not $script:dragging) { return }
        $now = [System.Windows.Forms.Cursor]::Position
        $dx = $now.X - $script:dragOrigin.X
        $dy = $now.Y - $script:dragOrigin.Y
        if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) { $script:movedDuringDrag = $true }
        $window.Left = $script:windowOrigin.X + $dx
        $window.Top = $script:windowOrigin.Y + $dy
        if ($script:movedDuringDrag) {
            $script:mode = 'drag'
            $script:dragDirection = $dx
        }
    })
    $window.Add_MouseLeftButtonUp({
        $window.ReleaseMouseCapture()
        if ($script:dragging -and -not $script:movedDuringDrag) {
            Start-OneShot 3 ($rowFrames[3] * 3)   # 单击 = 挥手
        }
        else {
            $script:mode = 'idle'
            $script:frameTick = 0
            $script:col = 0
        }
        $script:dragging = $false
    })

    $menu = New-Object System.Windows.Controls.ContextMenu
    function Add-MenuItem([string]$Header, [scriptblock]$Action) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = $Header
        $item.Add_Click($Action)
        $menu.Items.Add($item) | Out-Null
    }
    Add-MenuItem '挥手'      { Start-OneShot 3 ($rowFrames[3] * 3) }
    Add-MenuItem '跳一下'    { Start-OneShot 4 ($rowFrames[4] * 3) }
    Add-MenuItem '失败一下'  { Start-OneShot 5 ($rowFrames[5] * 3) }
    Add-MenuItem '工作一下'  { Start-OneShot 7 ($rowFrames[7] * 3) }
    Add-MenuItem '看向鼠标'  { $script:followMouse = -not $script:followMouse }
    Add-MenuItem '退出'      { $window.Close() }
    $window.ContextMenu = $menu

    if ($SelfTest) {
        # 不显示窗口，跑几帧确认整条链路可用
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        Start-OneShot 3 12
        for ($i = 0; $i -lt 12; $i++) { Update-Frame }
        "SELFTEST_OK cells=$($cells.Length) scale=$Scale window=$($window.Width)x$($window.Height)"
        exit 0
    }

    Write-Log 'started'
    $window.Add_Closed({ Write-Log 'closed'; $timer.Stop(); [System.Windows.Application]::Current.Shutdown() })
    $timer.Start()
    $window.ShowDialog() | Out-Null
    Write-Log 'exited'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    if ($SelfTest) { "SELFTEST_FAILED $($_.Exception.Message)"; exit 1 }
    [System.Windows.MessageBox]::Show("爱弥斯启动失败：`n`n$($_.Exception.Message)`n`n详情见 $logPath", '爱弥斯桌宠') | Out-Null
    exit 1
}
