<#
  AkDownloaderGUI.ps1  -  AkDownloader 图形控制台 (WinForms)
  ------------------------------------------------------------------
  控制面板功能:
    * 自动扫描启动器下载任务并下拉选择
    * 手动地址模式 (多行文本框 / 从文件导入)
    * 参数可视化: 并发 / 分块 / 端口 / 提醒开关
    * 一键开始 / 停止 (停止会连带清掉 curl 子进程)
    * 内嵌实时进度: 进度条 / 速度 / ETA / 文件列表 / 日志

  外观功能:
    * 背景图片 + 亮度 + 蒙版浓度 + 字体颜色自动适配
    * 入口: 操作区「外观设置...」

  高分辨率 / 高 DPI:
    * 启动时声明进程 DPI 感知 (PerMonitorV2 -> SystemAware 降级),
      否则在 125%/150% 缩放的屏幕上会被系统位图拉伸, 字发虚
    * 布局缩放 = max(DPI/96,1) x ui.guiScale (默认 1.0)
      只用来换算控件坐标/尺寸, 让界面在高 DPI 下保持同样的物理密度
    * 字号 = 9pt x ui.fontScale (默认 1.0, 单位是磅)
      磅本身就会按屏幕 DPI 换算像素, 所以这里不再乘 DPI 比例;
      实测 216 DPI(225%) 下 9pt 已经是 35px 高
    * 可用 -Scale / -FontScale 命令行覆盖上面两个值
    * 窗口尺寸自动收敛到屏幕工作区内; 控件带 Anchor, 可自由拉伸/最大化

  注意: 本文件含中文, 必须以"带 BOM 的 UTF-8"保存.
        PowerShell 5.1 读无 BOM 的 .ps1 会按系统 ANSI 解码, 中文会破坏语法.
#>
param(
    [switch]$SelfTest,
    [string]$Config,
    [double]$Scale = 0,
    [double]$FontScale = 0
)

# ---------------------------------------------------------------------------
# DPI 感知必须先于任何窗口/Graphics 创建
# ---------------------------------------------------------------------------
$script:DpiMode = 'none'
try {
    Add-Type -Namespace AkNative -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    try { if ([AkNative.Dpi]::SetProcessDpiAwarenessContext([System.IntPtr]::new(-4))) { $script:DpiMode = 'per-monitor-v2' } } catch { }
    if ($script:DpiMode -eq 'none') {
        try { if ([AkNative.Dpi]::SetProcessDPIAware()) { $script:DpiMode = 'system-aware' } } catch { }
    }
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# 缩放系数
# ---------------------------------------------------------------------------
$script:DesignW = 940
$script:DesignH = 700
$script:Dpi = 96.0
try {
    $gg = [System.Drawing.Graphics]::FromHwnd([System.IntPtr]::Zero)
    if ($gg) { $script:Dpi = [double]$gg.DpiX; $gg.Dispose() }
} catch { }
if ($script:Dpi -le 0) { $script:Dpi = 96.0 }

$userScale = 0.0
if ($Scale -gt 0) { $userScale = $Scale }
$userFont = 0.0
if ($FontScale -gt 0) { $userFont = $FontScale }

$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $Config) { $Config = Join-Path $script:Root 'config.json' }
$script:CfgPath = $Config
$script:Cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$script:MainPs1 = Join-Path $script:Root 'AkDownloader.ps1'

function Cfg-Num([string]$name, [double]$fallback) {
    try {
        $p = $script:Cfg.ui.PSObject.Properties[$name]
        if ($p -and $null -ne $p.Value -and [double]$p.Value -gt 0) { return [double]$p.Value }
    } catch { }
    return $fallback
}

if ($userScale -le 0) { $userScale = Cfg-Num 'guiScale' 1.0 }
if ($userFont -le 0) { $userFont = Cfg-Num 'fontScale' 1.0 }

# 布局缩放: 只跟随系统 DPI (这样 125%/150% 屏上不会发虚), 默认不再额外放大
$script:Scale = [math]::Max(1.0, $script:Dpi / 96.0) * $userScale
# 收敛到屏幕工作区内
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    # 边距要算上标题栏/边框, 否则窗口会有一截跑到任务栏下面
    $maxW = [double]($wa.Width - 90)
    $maxH = [double]($wa.Height - 110)
    $lim = [math]::Min($maxW / $script:DesignW, $maxH / $script:DesignH)
    if ($lim -gt 0.5 -and $script:Scale -gt $lim) { $script:Scale = $lim }
} catch { }
if ($script:Scale -lt 1.0) { $script:Scale = 1.0 }

# 字号: GDI+ 的 Font 以"磅"为单位, 本身就会按屏幕 DPI 换算成像素
# (实测 9pt 在 216 DPI 下已是 35px 高), 所以这里绝不能再乘 DPI 比例,
# 否则就是 2.25 x 2.25 的双重放大 —— 那正是"字大得离谱"的原因。
# 只保留一个用户可调的 fontScale, 默认 1.0 表示标准 9pt。
$script:FontScale = $userFont
if ($script:FontScale -lt 0.6) { $script:FontScale = 0.6 }
if ($script:FontScale -gt 2.0) { $script:FontScale = 2.0 }
$script:FontPt = [math]::Max(6.5, 9.0 * $script:FontScale)
$script:MonoPt = [math]::Max(6.0, 8.5 * $script:FontScale)

function SX([double]$v) { return [int][math]::Round($v * $script:Scale) }
function PT([double]$x, [double]$y) { return [System.Drawing.Point]::new((SX $x), (SX $y)) }
function SZ([double]$w, [double]$h) { return [System.Drawing.Size]::new((SX $w), (SX $h)) }

function Resolve-Tpl([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $rx = [regex]'%([^%]+)%'
    $ms = $rx.Matches($s)
    if ($ms.Count -eq 0) { return $s }
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in $ms) {
        [void]$sb.Append($s.Substring($pos, $m.Index - $pos))
        $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if ($v) { [void]$sb.Append($v) } else { [void]$sb.Append($m.Value) }
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($s.Substring($pos))
    return $sb.ToString()
}
function MB2([double]$n) {
    if ($n -ge 1073741824) { return ('{0:N2} GB' -f ($n / 1073741824)) }
    if ($n -ge 1048576) { return ('{0:N1} MB' -f ($n / 1048576)) }
    if ($n -ge 1024) { return ('{0:N0} KB' -f ($n / 1024)) }
    return ('{0:N0} B' -f $n)
}
function Dur([double]$s) {
    if ($s -lt 0 -or -not [double]::IsFinite($s)) { return '--' }
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600)
    $m = [math]::Floor(($s % 3600) / 60); $ss = [math]::Floor($s % 60)
    if ($d -gt 0) { return "$d 天 $h 小时" }
    if ($h -gt 0) { return "$h 时 $m 分" }
    if ($m -gt 0) { return "$m 分 $ss 秒" }
    return "$ss 秒"
}
function Test-PortFree([int]$port) {
    try {
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}
function Get-PortOwner([int]$port) {
    # 返回监听该端口的 PID; 没人监听返回 0
    # 注意: 不能把返回值存进 $pid —— 那是 PowerShell 的自动变量
    try {
        $o = (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop |
              Select-Object -First 1).OwningProcess
        if ($o) { return [int]$o }
    } catch { }
    try {
        foreach ($l in @(netstat -ano -p tcp)) {
            if ($l -match ('^\s*TCP\s+\S+:' + $port + '\s+\S+\s+LISTENING\s+(\d+)')) { return [int]$Matches[1] }
        }
    } catch { }
    return 0
}
function Test-AkProcess([int]$procId) {
    # 只认本工具起的下载进程, 避免误杀别人的程序
    if ($procId -le 0) { return $false }
    try {
        $c = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop).CommandLine
        return ($c -and $c -match 'AkDownloader\.ps1')
    } catch { return $false }
}
function Stop-AkProcess([int]$procId) {
    # /T 连带清掉它拉起的 curl 子进程
    if ($procId -le 0) { return }
    try { & taskkill.exe /PID $procId /T /F 2>$null | Out-Null } catch { }
    Get-Process curl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Quote-Arg([string]$s) {
    # PowerShell 5.1 的 Start-Process -ArgumentList 拿到数组时是直接拼空格的,
    # 元素里的空格不会自动加引号, 结果 "-TaskConfig C:\Program Files\..."
    # 会被切成多个 token 并错位绑到按位置的参数上。这里按 Windows 命令行
    # 规则手动加引号 (内部反斜杠+双引号要转义)。
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    return '"' + ($s -replace '(\\*)"', '$1$1\"') + '"'
}
# --- 看板数据拉取: 必须异步, 不能阻塞 UI 线程 ---------------------------
# 原来这里用 HttpWebRequest.GetResponse() 同步拉, 每个 tick 最多阻塞 2 秒。
# 看板是主脚本单线程服务的, 一个 /data 要扫分块目录 + System.Process, 于是
# 界面大部分时间都在干等 HTTP 响应: 窗口拖不动、按钮像没反应——这就是
# "GUI 很卡"的主因。改成 BeginGetResponse, 下一个 tick 收结果,
# UI 线程永不阻塞。
$script:DashPoll  = $null
$script:DashData  = $null
$script:DashFails = 0

function Reset-DashPoll {
    $script:DashPoll = $null
    $script:DashData = $null
    $script:DashFails = 0
}

function Update-DashPoll {
    $port = [int]$script:Port
    if ($port -le 0) { Reset-DashPoll; return }
    if ($script:DashPoll) {
        if (-not $script:DashPoll.Async.IsCompleted) { return }   # 还没回, 本 tick 先不更新
        try {
            $resp = $script:DashPoll.Req.EndGetResponse($script:DashPoll.Async)
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
            $script:DashData = ($txt | ConvertFrom-Json)
            $script:DashFails = 0
        } catch {
            $script:DashFails++
        }
        $script:DashPoll = $null
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://localhost:$port/data")
        $req.Proxy = $null
        $req.KeepAlive = $false
        $req.Timeout = 5000
        $req.ReadWriteTimeout = 5000
        $script:DashPoll = [pscustomobject]@{ Req = $req; Async = $req.BeginGetResponse($null, $null) }
    } catch {
        $script:DashPoll = $null
        $script:DashFails++
    }
}

$script:LogDir = Resolve-Tpl $script:Cfg.logDir
if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:ChildOut = Join-Path $script:LogDir 'gui_child.out'
$script:ChildErr = Join-Path $script:LogDir 'gui_child.err'
$script:Child = $null
$script:Timer = $null
$script:AppTimer = $null
$script:Port = 0
$script:LvSig = ''

# ===========================================================================
# 外观: 背景设置
# ===========================================================================
$script:BgFile = Join-Path $script:Root 'background.json'
$script:Bg = [pscustomobject]@{
    image        = ''
    brightness   = 15
    overlay      = 45
    overlayColor = 'auto'
    textColor    = 'auto'
}
function Import-Bg($obj) {
    if (-not $obj) { return }
    foreach ($k in @('image', 'brightness', 'overlay', 'overlayColor', 'textColor')) {
        $p = $obj.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) { $script:Bg.$k = $p.Value }
    }
}
if (Test-Path -LiteralPath $script:BgFile) {
    try { Import-Bg (Get-Content -LiteralPath $script:BgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
} elseif ($script:Cfg.background) {
    Import-Bg $script:Cfg.background
}
function Save-Bg {
    try { $script:Bg | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:BgFile -Encoding UTF8 } catch { }
}

function Get-AvgLuma([System.Drawing.Bitmap]$bmp) {
    # 实测(2115x1575 成品图, 10 次平均): 这里的逐点抽样 7.9 ms,
    # "先缩到 96x96 再 LockBits 读"反而要 41.9 ms —— 别再"优化"成缩放了,
    # 真正的开销是上面的双三次缩放绘制(71 ms)和解码原图(20 ms, 已由缓存解决)。
    if (-not $bmp) { return 128.0 }
    $sum = 0.0; $n = 0
    $sx = [math]::Max(1, [int]($bmp.Width / 48))
    $sy = [math]::Max(1, [int]($bmp.Height / 48))
    for ($y = 0; $y -lt $bmp.Height; $y += $sy) {
        for ($x = 0; $x -lt $bmp.Width; $x += $sx) {
            $c = $bmp.GetPixel($x, $y)
            $sum += (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
            $n++
        }
    }
    if ($n -eq 0) { return 128.0 }
    return ($sum / $n)
}

# 背景源图缓存: 之前每次重绘都 Image.FromFile 重新解码一遍磁盘图片,
# 拖窗口/拉亮度滑块时每秒要解码好几次
$script:BgSrcPath = ''
$script:BgSrc = $null
function Get-BgSource([string]$path) {
    if (-not $path) { return $null }
    if ($script:BgSrc -and $script:BgSrcPath -eq $path) { return $script:BgSrc }
    if ($script:BgSrc) { $script:BgSrc.Dispose(); $script:BgSrc = $null }
    $script:BgSrcPath = ''
    try {
        $tmp = [System.Drawing.Image]::FromFile($path)
        $script:BgSrc = New-Object System.Drawing.Bitmap($tmp)
        $tmp.Dispose()
        $script:BgSrcPath = $path
        return $script:BgSrc
    } catch { return $null }
}

function New-BgBitmap([string]$path, [int]$brightness, [int]$overlayPct, [string]$overlayColor, [int]$w, [int]$h) {
    $src = Get-BgSource $path
    if (-not $src) { return $null }

    if ($w -lt 16) { $w = 16 }
    if ($h -lt 16) { $h = 16 }
    $out = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $scaleImg = [math]::Max($w / [double]$src.Width, $h / [double]$src.Height)
    $dw = [int][math]::Ceiling($src.Width * $scaleImg)
    $dh = [int][math]::Ceiling($src.Height * $scaleImg)
    $dx = [int](($w - $dw) / 2)
    $dy = [int](($h - $dh) / 2)
    $dest = [System.Drawing.Rectangle]::new($dx, $dy, $dw, $dh)

    if ($brightness -ne 0) {
        $b = 1.0 + ($brightness / 100.0)
        if ($b -lt 0.05) { $b = 0.05 }
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = $b; $cm.Matrix11 = $b; $cm.Matrix22 = $b
        $cm.Matrix33 = 1.0; $cm.Matrix44 = 1.0
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $g.DrawImage($src, $dest, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $ia.Dispose()
    } else {
        $g.DrawImage($src, $dest, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel)
    }
    # 注意: $src 是缓存的共享位图, 这里不能 Dispose

    $baseLuma = Get-AvgLuma $out

    $isAuto = ($overlayColor -ne 'white' -and $overlayColor -ne 'black')
    $oc = $overlayColor
    if ($isAuto) {
        if ($script:Bg.textColor -eq 'light') { $oc = 'black' } else { $oc = 'white' }
    }

    # 自动模式: 目标亮度 AUTO_TARGET, 不够就补, 已经够就别糊太多蒙版
    # (图本身很亮时再加浓白蒙版只会把画面洗白, 文字本来也看得清)
    $AUTO_TARGET = 150.0
    $FLOOR_KEEP = 0.18
    $a = $overlayPct / 100.0
    if ($oc -eq 'white') {
        if ($baseLuma -ge $AUTO_TARGET) {
            if ($isAuto -and $a -gt $FLOOR_KEEP) { $a = $FLOOR_KEEP }
        } else {
            $need = ($AUTO_TARGET - $baseLuma) / (255.0 - $baseLuma)
            if ($need -gt $a) { $a = $need }
        }
    } elseif ($oc -eq 'black') {
        $darkTarget = 255.0 - $AUTO_TARGET
        if ($baseLuma -le $darkTarget) {
            if ($isAuto -and $a -gt $FLOOR_KEEP) { $a = $FLOOR_KEEP }
        } else {
            $need = ($baseLuma - $darkTarget) / $baseLuma
            if ($need -gt $a) { $a = $need }
        }
    }
    if ($a -gt 0.85) { $a = 0.85 }
    if ($a -lt 0) { $a = 0 }

    if ($a -gt 0.001) {
        $col = [System.Drawing.Color]::White
        if ($oc -eq 'black') { $col = [System.Drawing.Color]::Black }
        $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb([int]($a * 255), $col))
        $g.FillRectangle($br, 0, 0, $w, $h)
        $br.Dispose()
    }
    $g.Dispose()

    return [pscustomobject]@{ Bitmap = $out; Luma = (Get-AvgLuma $out) }
}

$script:Th = $null
function Update-ThemeColors([double]$luma, [bool]$hasImage) {
    $mode = 'light'
    if ($hasImage) {
        $want = [string]$script:Bg.textColor
        if ($want -eq 'light') { $mode = 'dark' }
        elseif ($want -eq 'dark') { $mode = 'light' }
        else { if ($luma -ge 140) { $mode = 'light' } else { $mode = 'dark' } }
    }
    if ($mode -eq 'light') {
        $script:Th = [pscustomobject]@{
            Fg = [System.Drawing.Color]::FromArgb(26, 26, 30)
            Sub = [System.Drawing.Color]::FromArgb(88, 88, 98)
            InputBg = [System.Drawing.Color]::FromArgb(255, 255, 255)
            InputFg = [System.Drawing.Color]::FromArgb(20, 20, 24)
            BtnBg = [System.Drawing.Color]::FromArgb(242, 242, 246)
            BtnFg = [System.Drawing.Color]::FromArgb(26, 26, 30)
            Line = [System.Drawing.Color]::FromArgb(170, 170, 180)
        }
    } else {
        $script:Th = [pscustomobject]@{
            Fg = [System.Drawing.Color]::FromArgb(240, 240, 246)
            Sub = [System.Drawing.Color]::FromArgb(170, 170, 182)
            InputBg = [System.Drawing.Color]::FromArgb(34, 34, 42)
            InputFg = [System.Drawing.Color]::FromArgb(240, 240, 246)
            BtnBg = [System.Drawing.Color]::FromArgb(52, 52, 62)
            BtnFg = [System.Drawing.Color]::FromArgb(240, 240, 246)
            Line = [System.Drawing.Color]::FromArgb(96, 96, 110)
        }
    }
    return $mode
}

function Set-ControlTheme($parent) {
    foreach ($c in $parent.Controls) {
        $tn = $c.GetType().Name
        switch ($tn) {
            'Label'       {
                $c.BackColor = [System.Drawing.Color]::Transparent
                # Tag='hint' 的标签用次要色, 用于参数说明这类辅助文字
                if ($c.Tag -eq 'hint') { $c.ForeColor = $script:Th.Sub } else { $c.ForeColor = $script:Th.Fg }
            }
            'RadioButton' { $c.BackColor = [System.Drawing.Color]::Transparent; $c.ForeColor = $script:Th.Fg }
            'CheckBox'    { $c.BackColor = [System.Drawing.Color]::Transparent; $c.ForeColor = $script:Th.Fg }
            'GroupBox'    { $c.BackColor = [System.Drawing.Color]::Transparent; $c.ForeColor = $script:Th.Fg }
            'Button'      {
                $c.FlatStyle = 'Flat'
                $c.BackColor = $script:Th.BtnBg
                $c.ForeColor = $script:Th.BtnFg
                $c.FlatAppearance.BorderColor = $script:Th.Line
            }
            'TextBox'       { $c.BackColor = $script:Th.InputBg; $c.ForeColor = $script:Th.InputFg }
            'ComboBox'      { $c.BackColor = $script:Th.InputBg; $c.ForeColor = $script:Th.InputFg }
            'NumericUpDown' { $c.BackColor = $script:Th.InputBg; $c.ForeColor = $script:Th.InputFg }
            'ListView'      { $c.BackColor = $script:Th.InputBg; $c.ForeColor = $script:Th.InputFg }
            'TrackBar'      { $c.BackColor = [System.Drawing.Color]::Transparent }
            default         { }
        }
        if ($c.HasChildren -and $tn -ne 'ListView') { Set-ControlTheme $c }
    }
    if ($parent -is [System.Windows.Forms.Form]) { $parent.ForeColor = $script:Th.Fg }
}

$script:LastApplied = [System.Drawing.Size]::new(0, 0)
$script:Resizing = $false

function Request-Appearance {
    # 去抖: 重绘要重新缩放整张背景图, 拖窗口/拉滑块时不能每个事件都做一遍
    if ($script:AppTimer) { $script:AppTimer.Stop(); $script:AppTimer.Start() }
    else { Apply-Appearance }
}

function Apply-Appearance {
    if (-not $script:form) { return }
    if ($script:Resizing) { return }   # 拖动中不重绘, 松手时(ResizeEnd)一次性画好
    $hasImg = $false
    if ($script:Bg.image -and (Test-Path -LiteralPath $script:Bg.image)) {
        $size = $script:form.ClientSize
        $script:LastApplied = $size
        $res = New-BgBitmap $script:Bg.image ([int]$script:Bg.brightness) ([int]$script:Bg.overlay) ([string]$script:Bg.overlayColor) $size.Width $size.Height
        if ($res) {
            if ($script:form.BackgroundImage) { $script:form.BackgroundImage.Dispose() }
            $script:form.BackgroundImage = $res.Bitmap
            $script:form.BackgroundImageLayout = 'None'
            $hasImg = $true
            [void](Update-ThemeColors $res.Luma $true)
        }
    }
    if (-not $hasImg) {
        if ($script:form.BackgroundImage) { $script:form.BackgroundImage.Dispose() }
        $script:form.BackgroundImage = $null
        $script:form.BackColor = [System.Drawing.Color]::FromArgb(246, 246, 249)
        [void](Update-ThemeColors 255 $false)
    }
    Set-ControlTheme $script:form
    # Refresh() 会同步重画整窗口和所有子控件, 拖动时很卡; Invalidate 只标记,
    # 由消息循环异步重画
    $script:form.Invalidate($true)
}

# ===========================================================================
# 主窗口
# ===========================================================================
$font = New-Object System.Drawing.Font('Microsoft YaHei UI', $script:FontPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
$fontMono = New-Object System.Drawing.Font('Consolas', $script:MonoPt, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)

$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'AkDownloader 图形控制台'
$form.AutoScaleMode = 'None'
$form.ClientSize = [System.Drawing.Size]::new((SX $script:DesignW), (SX $script:DesignH))
$form.StartPosition = 'CenterScreen'
$form.Font = $font
# 最小尺寸 = 设计客户区 + 标题栏/边框, 不能用固定数字, 否则窗口会被强制撑大
$bord = $form.Size - $form.ClientSize
$form.MinimumSize = [System.Drawing.Size]::new(
    ((SX $script:DesignW) + $bord.Width),
    ((SX $script:DesignH) + $bord.Height))
try {
    $dp = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($dp) { $dp.SetValue($form, $true, $null) }
} catch { }
$form.WindowState = 'Normal'

# ---- 下载源 ----
$gbSrc = New-Object System.Windows.Forms.GroupBox
$gbSrc.Text = '下载源'
$gbSrc.Location = (PT 12 8)
$gbSrc.Size = (SZ 916 232)
$gbSrc.Anchor = 'Top,Left,Right'
$form.Controls.Add($gbSrc)

$rbAuto = New-Object System.Windows.Forms.RadioButton
$rbAuto.Text = '① 自动提取启动器下载任务'
$rbAuto.Location = (PT 14 20)
$rbAuto.Size = (SZ 320 20)
$rbAuto.Checked = $true
$gbSrc.Controls.Add($rbAuto)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '重新扫描'
$btnScan.Size = (SZ 96 24)
$btnScan.Location = (PT 806 17)
$btnScan.Anchor = 'Top,Right'
$gbSrc.Controls.Add($btnScan)

$cbTask = New-Object System.Windows.Forms.ComboBox
$cbTask.Location = (PT 32 44)
$cbTask.Size = (SZ 870 22)
$cbTask.Anchor = 'Top,Left,Right'
$cbTask.DropDownStyle = 'DropDownList'
$gbSrc.Controls.Add($cbTask)

$lbTaskInfo = New-Object System.Windows.Forms.Label
$lbTaskInfo.Location = (PT 32 72)
$lbTaskInfo.Size = (SZ 870 34)
$lbTaskInfo.Anchor = 'Top,Left,Right'
$gbSrc.Controls.Add($lbTaskInfo)

$rbManual = New-Object System.Windows.Forms.RadioButton
$rbManual.Text = '② 手动输入地址（每行一个，任意 HTTP 链接）'
$rbManual.Location = (PT 14 110)
$rbManual.Size = (SZ 420 20)
$gbSrc.Controls.Add($rbManual)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = '从文件导入'
$btnLoad.Size = (SZ 96 24)
$btnLoad.Location = (PT 806 107)
$btnLoad.Anchor = 'Top,Right'
$gbSrc.Controls.Add($btnLoad)

$tbUrls = New-Object System.Windows.Forms.TextBox
$tbUrls.Location = (PT 32 132)
$tbUrls.Size = (SZ 870 52)
$tbUrls.Anchor = 'Top,Left,Right'
$tbUrls.Multiline = $true
$tbUrls.ScrollBars = 'Vertical'
$gbSrc.Controls.Add($tbUrls)

$lbOut = New-Object System.Windows.Forms.Label
$lbOut.Text = '保存目录'
$lbOut.Location = (PT 32 192)
$lbOut.Size = (SZ 64 20)
$gbSrc.Controls.Add($lbOut)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览...'
$btnBrowse.Size = (SZ 96 24)
$btnBrowse.Location = (PT 806 188)
$btnBrowse.Anchor = 'Top,Right'
$gbSrc.Controls.Add($btnBrowse)

$tbOut = New-Object System.Windows.Forms.TextBox
$tbOut.Location = (PT 100 190)
$tbOut.Size = (SZ 702 22)
$tbOut.Anchor = 'Top,Left,Right'
$gbSrc.Controls.Add($tbOut)

# ---- 参数 ----
$gbPar = New-Object System.Windows.Forms.GroupBox
$gbPar.Text = '参数'
$gbPar.Location = (PT 12 248)
$gbPar.Size = (SZ 916 84)
$gbPar.Anchor = 'Top,Left,Right'
$form.Controls.Add($gbPar)

function New-ParamLabel($text, $x, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = (PT $x 22)
    $l.Size = (SZ $w 20)
    $l.TextAlign = 'MiddleLeft'
    return $l
}
function New-Num($x, $w, $min, $max, $val) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = (PT $x 19)
    $n.Size = (SZ $w 22)
    $n.Minimum = $min
    $n.Maximum = $max
    $n.Value = $val
    return $n
}
$gbPar.Controls.Add((New-ParamLabel '并发连接' 14 60))
$numW = New-Num 78 64 1 256 ([int]$script:Cfg.workers)
$gbPar.Controls.Add($numW)
$gbPar.Controls.Add((New-ParamLabel '分块 (MB)' 168 72))
$numC = New-Num 244 64 1 64 ([int]$script:Cfg.chunkMB)
$gbPar.Controls.Add($numC)
$gbPar.Controls.Add((New-ParamLabel '看板端口' 334 60))
$numP = New-Num 398 72 1024 65535 ([int]$script:Cfg.port)
$gbPar.Controls.Add($numP)

$lbParHint = New-Object System.Windows.Forms.Label
$lbParHint.Text = '并发越高越快，但过高容易被 CDN 判定异常；分块越小进度越平滑，HTTP 开销略大。'
$lbParHint.Location = (PT 490 22)
$lbParHint.Size = (SZ 412 20)
$lbParHint.Anchor = 'Top,Left,Right'
$lbParHint.TextAlign = 'MiddleLeft'
$lbParHint.Tag = 'hint'
$gbPar.Controls.Add($lbParHint)

$chkBrowser = New-Object System.Windows.Forms.CheckBox
$chkBrowser.Text = '自动打开看板'
$chkBrowser.Location = (PT 14 52)
$chkBrowser.Size = (SZ 124 20)
$chkBrowser.Checked = [bool]$script:Cfg.openBrowser
$gbPar.Controls.Add($chkBrowser)

$chkNotify = New-Object System.Windows.Forms.CheckBox
$chkNotify.Text = '完成后弹窗提醒'
$chkNotify.Location = (PT 152 52)
$chkNotify.Size = (SZ 136 20)
$chkNotify.Checked = [bool]$script:Cfg.notifyOnFinish
$gbPar.Controls.Add($chkNotify)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '完成后自动启动启动器'
$chkAuto.Location = (PT 302 52)
$chkAuto.Size = (SZ 190 20)
$chkAuto.Checked = [bool]$script:Cfg.autoLaunchLauncher
$gbPar.Controls.Add($chkAuto)

# ---- 操作按钮 ----
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '开始下载'
$btnStart.Location = (PT 12 340)
$btnStart.Size = (SZ 124 34)
$btnStart.Anchor = 'Top,Left'
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止'
$btnStop.Location = (PT 144 340)
$btnStop.Size = (SZ 84 34)
$btnStop.Anchor = 'Top,Left'
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnDash = New-Object System.Windows.Forms.Button
$btnDash.Text = '打开看板'
$btnDash.Location = (PT 236 340)
$btnDash.Size = (SZ 104 34)
$btnDash.Anchor = 'Top,Left'
$form.Controls.Add($btnDash)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = '日志目录'
$btnLogs.Location = (PT 348 340)
$btnLogs.Size = (SZ 104 34)
$btnLogs.Anchor = 'Top,Left'
$form.Controls.Add($btnLogs)

$btnCfg = New-Object System.Windows.Forms.Button
$btnCfg.Text = '编辑配置'
$btnCfg.Location = (PT 460 340)
$btnCfg.Size = (SZ 104 34)
$btnCfg.Anchor = 'Top,Left'
$form.Controls.Add($btnCfg)

$btnLook = New-Object System.Windows.Forms.Button
$btnLook.Text = '外观设置...'
$btnLook.Location = (PT 572 340)
$btnLook.Size = (SZ 112 34)
$btnLook.Anchor = 'Top,Left'
$form.Controls.Add($btnLook)

$lbStatus = New-Object System.Windows.Forms.Label
$lbStatus.Location = (PT 690 346)
$lbStatus.Size = (SZ 238 22)
$lbStatus.Anchor = 'Top,Left,Right'
$lbStatus.TextAlign = 'MiddleRight'
$lbStatus.Text = '就绪'
$form.Controls.Add($lbStatus)

$pb = New-Object System.Windows.Forms.ProgressBar
$pb.Location = (PT 12 386)
$pb.Size = (SZ 916 20)
$pb.Anchor = 'Top,Left,Right'
$pb.Maximum = 10000
$form.Controls.Add($pb)

$lv = New-Object System.Windows.Forms.ListView
$lv.Location = (PT 12 418)
$lv.Size = (SZ 916 158)
$lv.Anchor = 'Top,Bottom,Left,Right'
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.GridLines = $true
[void]$lv.Columns.Add('文件', (SX 420))
[void]$lv.Columns.Add('大小', (SX 130))
[void]$lv.Columns.Add('已下载', (SX 150))
[void]$lv.Columns.Add('进度', (SX 90))
[void]$lv.Columns.Add('状态', (SX 90))
$form.Controls.Add($lv)

$tbLog = New-Object System.Windows.Forms.TextBox
$tbLog.Location = (PT 12 584)
$tbLog.Size = (SZ 916 104)
$tbLog.Anchor = 'Bottom,Left,Right'
$tbLog.Multiline = $true
$tbLog.ReadOnly = $true
$tbLog.ScrollBars = 'Vertical'
$tbLog.Font = $fontMono
$form.Controls.Add($tbLog)

# ===========================================================================
# 外观设置对话框
# ===========================================================================
$dlg = New-Object System.Windows.Forms.Form
$dlg.Text = '外观设置'
$dlg.AutoScaleMode = 'None'
$dlg.ClientSize = [System.Drawing.Size]::new((SX 720), (SX 490))
$dlg.StartPosition = 'CenterParent'
$dlg.FormBorderStyle = 'FixedDialog'
$dlg.MaximizeBox = $false
$dlg.MinimizeBox = $false
$dlg.Font = $font

# 左列: 预览 + 两个滑杆
$lbPrev = New-Object System.Windows.Forms.Label
$lbPrev.Text = '预览'
$lbPrev.Location = (PT 14 10)
$lbPrev.Size = (SZ 60 18)
$dlg.Controls.Add($lbPrev)

$pbPrev = New-Object System.Windows.Forms.PictureBox
$pbPrev.Location = (PT 14 30)
$pbPrev.Size = (SZ 400 230)
$pbPrev.BorderStyle = 'FixedSingle'
$pbPrev.SizeMode = 'Zoom'
$dlg.Controls.Add($pbPrev)

$lbBgPath = New-Object System.Windows.Forms.Label
$lbBgPath.Location = (PT 14 268)
$lbBgPath.Size = (SZ 400 30)
$dlg.Controls.Add($lbBgPath)

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = '选择图片...'
$btnPick.Location = (PT 14 304)
$btnPick.Size = (SZ 124 30)
$dlg.Controls.Add($btnPick)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清除背景'
$btnClear.Location = (PT 146 304)
$btnClear.Size = (SZ 110 30)
$dlg.Controls.Add($btnClear)

$lbBright = New-Object System.Windows.Forms.Label
$lbBright.Text = '背景亮度'
$lbBright.Location = (PT 14 350)
$lbBright.Size = (SZ 68 20)
$lbBright.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbBright)

# 注意: TrackBar 带刻度时最小高度约 45 (设计单位), 行距必须按 45 排,
# 否则第二行滑杆会和第一行叠在一起
$tbBright = New-Object System.Windows.Forms.TrackBar
$tbBright.Location = (PT 84 338)
$tbBright.Size = (SZ 236 45)
$tbBright.Minimum = -100
$tbBright.Maximum = 100
$tbBright.TickFrequency = 25
$dlg.Controls.Add($tbBright)

$lbBrightVal = New-Object System.Windows.Forms.Label
$lbBrightVal.Location = (PT 324 350)
$lbBrightVal.Size = (SZ 66 20)
$lbBrightVal.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbBrightVal)

$lbOver = New-Object System.Windows.Forms.Label
$lbOver.Text = '蒙版浓度'
$lbOver.Location = (PT 14 398)
$lbOver.Size = (SZ 68 20)
$lbOver.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbOver)

$tbOver = New-Object System.Windows.Forms.TrackBar
$tbOver.Location = (PT 84 386)
$tbOver.Size = (SZ 236 45)
$tbOver.Minimum = 0
$tbOver.Maximum = 90
$tbOver.TickFrequency = 15
$dlg.Controls.Add($tbOver)

$lbOverVal = New-Object System.Windows.Forms.Label
$lbOverVal.Location = (PT 324 398)
$lbOverVal.Size = (SZ 66 20)
$lbOverVal.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbOverVal)

# 右列: 颜色选项 + 说明
$lbOC = New-Object System.Windows.Forms.Label
$lbOC.Text = '蒙版颜色'
$lbOC.Location = (PT 430 30)
$lbOC.Size = (SZ 90 18)
$lbOC.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbOC)

$cbOC = New-Object System.Windows.Forms.ComboBox
$cbOC.Location = (PT 430 50)
$cbOC.Size = (SZ 276 22)
$cbOC.DropDownStyle = 'DropDownList'
[void]$cbOC.Items.AddRange(@('自动（按字体颜色）', '白色（提亮背景）', '黑色（压暗背景）'))
$dlg.Controls.Add($cbOC)

$lbTC = New-Object System.Windows.Forms.Label
$lbTC.Text = '字体颜色'
$lbTC.Location = (PT 430 84)
$lbTC.Size = (SZ 90 18)
$lbTC.TextAlign = 'MiddleLeft'
$dlg.Controls.Add($lbTC)

$cbTC = New-Object System.Windows.Forms.ComboBox
$cbTC.Location = (PT 430 104)
$cbTC.Size = (SZ 276 22)
$cbTC.DropDownStyle = 'DropDownList'
[void]$cbTC.Items.AddRange(@('自动适配背景亮度', '强制深色字（适合亮背景）', '强制浅色字（适合暗背景）'))
$dlg.Controls.Add($cbTC)

$lbInfo = New-Object System.Windows.Forms.Label
$lbInfo.Location = (PT 430 138)
$lbInfo.Size = (SZ 276 44)
$dlg.Controls.Add($lbInfo)

$lbTip = New-Object System.Windows.Forms.Label
$lbTip.Location = (PT 430 190)
$lbTip.Size = (SZ 276 242)
$lbTip.Tag = 'hint'
$lbTip.Text = "提示`r`n· 亮度 / 蒙版 改动后实时预览`r`n· 「自动」按蒙版后的实际亮度切换深 / 浅色字`r`n· 文字看不清时先把蒙版浓度调高`r`n· 外观设置保存在 background.json`r`n`r`n字号觉得偏大 / 偏小`r`n· 只调字号: config.json -> ui.fontScale（默认 1.0）`r`n· 整体界面: config.json -> ui.guiScale（默认 1.0）`r`n  或启动加 -Scale 1.2 / -FontScale 0.9"
$dlg.Controls.Add($lbTip)

$btnOK = New-Object System.Windows.Forms.Button
$btnOK.Text = '确定'
$btnOK.Location = (PT 486 446)
$btnOK.Size = (SZ 100 32)
$dlg.Controls.Add($btnOK)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消'
$btnCancel.Location = (PT 606 446)
$btnCancel.Size = (SZ 100 32)
$dlg.Controls.Add($btnCancel)
$btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$dlg.AcceptButton = $btnOK
$dlg.CancelButton = $btnCancel

$script:DlgBackup = $null
function Dlg-Preview {
    if (-not ($script:Bg.image -and (Test-Path -LiteralPath $script:Bg.image))) {
        $pbPrev.Image = $null
        $lbBgPath.Text = '（未设置背景图，使用默认浅色主题）'
        $lbInfo.Text = ''
        return
    }
    $pw = $pbPrev.ClientSize.Width
    $ph = $pbPrev.ClientSize.Height
    if ($pw -lt 16) { $pw = 400 }
    if ($ph -lt 16) { $ph = 230 }
    $res = New-BgBitmap $script:Bg.image ([int]$script:Bg.brightness) ([int]$script:Bg.overlay) ([string]$script:Bg.overlayColor) $pw $ph
    if ($res) {
        if ($pbPrev.Image) { $pbPrev.Image.Dispose() }
        $pbPrev.Image = $res.Bitmap
        $hl = '深色字'
        if ($res.Luma -lt 140) { $hl = '浅色字' }
        $lbInfo.Text = ("成品亮度 {0:N0}`r`n自动字色: {1}" -f $res.Luma, $hl)
    }
}
function Dlg-ToControls {
    $tbBright.Value = [math]::Max(-100, [math]::Min(100, [int]$script:Bg.brightness))
    $tbOver.Value = [math]::Max(0, [math]::Min(90, [int]$script:Bg.overlay))
    $lbBrightVal.Text = ([string][int]$script:Bg.brightness)
    $lbOverVal.Text = ([string][int]$script:Bg.overlay + '%')
    $i = 0
    if ($script:Bg.overlayColor -eq 'white') { $i = 1 } elseif ($script:Bg.overlayColor -eq 'black') { $i = 2 }
    if ($cbOC.SelectedIndex -lt 0) { $cbOC.SelectedIndex = $i }
    $j = 0
    if ($script:Bg.textColor -eq 'dark') { $j = 1 } elseif ($script:Bg.textColor -eq 'light') { $j = 2 }
    if ($cbTC.SelectedIndex -lt 0) { $cbTC.SelectedIndex = $j }
}

# ===========================================================================
# 状态机
# ===========================================================================
function Set-Running([bool]$running) {
    $btnStart.Enabled = -not $running
    $btnStop.Enabled = $running
    $cbTask.Enabled = -not $running -and $rbAuto.Checked
    $btnScan.Enabled = -not $running
    $rbAuto.Enabled = -not $running
    $rbManual.Enabled = -not $running
    $tbUrls.Enabled = -not $running -and $rbManual.Checked
    $btnLoad.Enabled = -not $running -and $rbManual.Checked
    $numW.Enabled = -not $running
    $numC.Enabled = -not $running
    $numP.Enabled = -not $running
}

function Update-SourceEnabled {
    if ($rbAuto.Checked) {
        $cbTask.Enabled = $true; $btnScan.Enabled = $true
        $tbUrls.Enabled = $false; $btnLoad.Enabled = $false
    } else {
        $cbTask.Enabled = $false; $btnScan.Enabled = $false
        $tbUrls.Enabled = $true; $btnLoad.Enabled = $true
    }
}

$script:Tasks = @()
function Refresh-Tasks {
    $lbTaskInfo.Text = '正在扫描启动器目录…'
    [System.Windows.Forms.Application]::DoEvents()
    $cbTask.Items.Clear()
    $script:Tasks = @()
    $gamesDir = Join-Path (Resolve-Tpl $script:Cfg.launcherRoot) 'games'
    $found = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $gamesDir) {
        foreach ($g in @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($lt in @(Get-ChildItem -LiteralPath $g.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($h in @(Get-ChildItem -LiteralPath $lt.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $f = Join-Path $h.FullName 'download\download_sdk_config'
                    if (Test-Path -LiteralPath $f) { [void]$found.Add($f) }
                }
            }
        }
    }
    foreach ($fn in $found) {
        try {
            $arr = @(Get-Content -LiteralPath $fn -Raw -Encoding UTF8 | ConvertFrom-Json)
            foreach ($t in $arr) {
                if (-not $t.file_list -or @($t.file_list).Count -eq 0) { continue }
                $game = 'game'
                $m = [regex]::Match($fn, '\\games\\([^\\]+)\\')
                if ($m.Success) { $game = $m.Groups[1].Value }
                $o = [pscustomobject]@{
                    Path = $fn; Game = $game; Version = [string]$t.version_id
                    Parts = @($t.file_list).Count; Total = [long]$t.total_size
                }
                $script:Tasks += $o
                [void]$cbTask.Items.Add(("{0}  |  版本 {1}  |  {2} 片  |  {3}" -f $o.Game, $o.Version, $o.Parts, (MB2 $o.Total)))
            }
        } catch { }
    }
    if ($cbTask.Items.Count -gt 0) {
        $cbTask.SelectedIndex = 0
        $lbTaskInfo.Text = '找到 ' + $cbTask.Items.Count + ' 个任务'
    } else {
        $lbTaskInfo.Text = '未找到可下载的任务。请先在启动器里点「下载/更新」建立任务，然后关闭启动器再扫描。'
    }
}

function Show-TaskInfo {
    if ($cbTask.SelectedIndex -lt 0 -or $cbTask.SelectedIndex -ge $script:Tasks.Count) { return }
    $t = $script:Tasks[$cbTask.SelectedIndex]
    # PowerShell 5.1 的 Split-Path -LiteralPath 不支持 -Parent, 用 .NET 取父目录
    $lbTaskInfo.Text = ("目录: {0}`r`n配置: {1}" -f ([System.IO.Path]::GetDirectoryName($t.Path)), $t.Path)
}

function Start-Download {
    if (-not (Test-Path -LiteralPath $script:MainPs1)) {
        [void][System.Windows.Forms.MessageBox]::Show("找不到主脚本:`r`n$script:MainPs1", '错误')
        return
    }
    $port = [int]$numP.Value
    if (-not (Test-PortFree $port)) {
        # 端口被占: 如果是上一次残留的下载/看板进程, 问一下能不能接管
        $owner = Get-PortOwner $port
        if (Test-AkProcess $owner) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "端口 $port 上是上一次残留的下载进程（PID $owner）。`r`n`r`n要结束它并开始新的下载吗？",
                '残留进程', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            Stop-AkProcess $owner
            if (-not (Test-PortFree $port)) {
                [void][System.Windows.Forms.MessageBox]::Show("端口 $port 释放失败，请稍后重试或换一个端口。", '端口占用')
                return
            }
        } else {
            [void][System.Windows.Forms.MessageBox]::Show("端口 $port 已被其它进程占用，请换一个端口。", '端口占用')
            return
        }
    }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MainPs1, '-Config', $script:CfgPath)
    if ($rbAuto.Checked) {
        if ($cbTask.SelectedIndex -lt 0) {
            [void][System.Windows.Forms.MessageBox]::Show('请先扫描并选择一个任务。', '提示')
            return
        }
        $a += @('-TaskConfig', $script:Tasks[$cbTask.SelectedIndex].Path)
    } else {
        $urls = @($tbUrls.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
        if ($urls.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('请输入至少一个下载地址。', '提示')
            return
        }
        $uf = Join-Path $script:LogDir 'gui_urls.txt'
        Set-Content -LiteralPath $uf -Value $urls -Encoding UTF8
        $a += @('-UrlFile', $uf)
        if ($tbOut.Text.Trim()) { $a += @('-OutDir', $tbOut.Text.Trim()) }
    }
    $a += @('-Workers', ([string][int]$numW.Value))
    $a += @('-ChunkMB', ([string][int]$numC.Value))
    $a += @('-Port', ([string]$port))
    $a += @('-Force')
    if (-not $chkBrowser.Checked) { $a += '-NoBrowser' }
    if (-not $chkNotify.Checked) { $a += '-NoNotify' }
    if ($chkAuto.Checked) { $a += '-AutoLaunch' }

    Remove-Item -LiteralPath $script:ChildOut, $script:ChildErr -Force -ErrorAction SilentlyContinue
    # 必须把每个参数单独加引号再拼成一行, 否则含空格的路径 (如
    # "C:\Program Files\GRYPHLINK\games\Arknights Endfield\...") 会在空格处断掉,
    # 碎片还会按位置绑到 $Url / $UrlFile, 把自动模式悄悄变成 URL 模式。
    $argLine = (@($a | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    try {
        $script:Child = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $script:ChildOut -RedirectStandardError $script:ChildErr
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("启动失败:`r`n" + $_.Exception.Message, '错误')
        return
    }
    $script:Port = $port
    Reset-DashPoll
    $script:LvSig = ''
    Set-Running $true
    $lv.Items.Clear()
    $tbLog.Text = ''
    $lbStatus.Text = '已启动，正在连接看板…'
    $script:Timer.Start()
}

function Stop-Download {
    $script:Timer.Stop()
    if ($script:Child) { Stop-Process -Id $script:Child.Id -Force -ErrorAction SilentlyContinue }
    Get-Process curl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # 兜底: 上一次 GUI 会话遗留、仍在看板端口上监听的下载进程也一并收掉,
    # 否则它会占着端口直到 keepAliveMinutes 到期, 再点"开始"只会弹端口占用。
    $owner = Get-PortOwner $script:Port
    if (Test-AkProcess $owner) { Stop-AkProcess $owner }
    $script:Child = $null
    Set-Running $false
    $lbStatus.Text = '已停止'
    $tbLog.AppendText("`r`n[已手动停止]`r`n")
}

$script:LastLog = ''
function Tick {
    Update-DashPoll
    $d = $script:DashData
    # 子进程已退出 且 看板也连着几次拉不到 -> 判定结束
    $dead = ($script:Child -and $script:Child.HasExited -and $script:DashFails -ge 2)
    if (-not $d -or $dead) {
        if ($dead) {
            $script:Timer.Stop()
            Set-Running $false
            $lbStatus.Text = '进程已结束'
            foreach ($f in @($script:ChildOut, $script:ChildErr)) {
                if (Test-Path -LiteralPath $f) { $tbLog.AppendText((Get-Content -LiteralPath $f -Tail 20 | Out-String)) }
            }
        } else {
            $lbStatus.Text = '等待看板响应…'
        }
        return
    }

    $pct = 0
    if ($d.totalSize -gt 0) { $pct = [math]::Round($d.totalHave / $d.totalSize * 100, 2) }
    $pb.Value = [math]::Min(10000, [int]($pct * 100))

    if ($d.finished) {
        $lbStatus.Text = ('完成 {0}%' -f $pct)
    } else {
        $lbStatus.Text = ('{0}% | {1}/s | 剩余 {2} | {3} 连接' -f `
            $pct, (MB2 ([double]$d.speed)), (Dur ([double]$d.eta)), $d.procs)
    }

    # 列表只在数据真的变了才重建 (54 行 x 每秒重建一次也会拖慢界面)
    $sig = ''
    foreach ($p in $d.parts) { $sig += "$($p.name)|$($p.size)|$($p.have)|$($p.done);" }
    if ($sig -ne $script:LvSig) {
        $script:LvSig = $sig
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($p in $d.parts) {
            $q = 0
            if ($p.size -gt 0) { $q = [math]::Round($p.have / $p.size * 100, 1) }
            $st = '下载中'
            if ($p.done) { $st = '完成' }
            elseif ($p.have -le 0) { $st = '等待' }
            $it = New-Object System.Windows.Forms.ListViewItem([string]$p.name)
            [void]$it.SubItems.Add((MB2 $p.size))
            [void]$it.SubItems.Add((MB2 $p.have))
            [void]$it.SubItems.Add(('{0}%' -f $q))
            [void]$it.SubItems.Add($st)
            if ($p.done) { $it.ForeColor = [System.Drawing.Color]::SeaGreen }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
    }

    $txt = ($d.log -join "`r`n")
    if ($txt -ne $script:LastLog) {
        $script:LastLog = $txt
        $tbLog.Text = $txt
        $tbLog.SelectionStart = $tbLog.TextLength
        $tbLog.ScrollToCaret()
    }
}

# ===========================================================================
# 事件
# ===========================================================================
$rbAuto.Add_CheckedChanged({ Update-SourceEnabled })
$rbManual.Add_CheckedChanged({ Update-SourceEnabled })
$cbTask.Add_SelectedIndexChanged({ Show-TaskInfo })
$btnScan.Add_Click({ Refresh-Tasks; Show-TaskInfo })
$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($tbOut.Text.Trim() -and (Test-Path -LiteralPath $tbOut.Text.Trim())) { $fb.SelectedPath = $tbOut.Text.Trim() }
    if ($fb.ShowDialog() -eq 'OK') { $tbOut.Text = $fb.SelectedPath }
})
$btnLoad.Add_Click({
    $of = New-Object System.Windows.Forms.OpenFileDialog
    $of.Filter = '文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*'
    if ($of.ShowDialog() -eq 'OK') { $tbUrls.Text = (Get-Content -LiteralPath $of.FileName -Raw -Encoding UTF8) }
})
$btnStart.Add_Click({ Start-Download })
$btnStop.Add_Click({ Stop-Download })
$btnDash.Add_Click({
    # $script:Port 只在开始下载时才被赋值, 没开始过就用界面上配的端口
    $port = [int]$script:Port
    if ($port -le 0) { $port = [int]$numP.Value }
    if ((Get-PortOwner $port) -le 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "端口 $port 上现在没有看板在运行。`r`n`r`n看板由主脚本提供，点「开始下载」跑起来后它才存在。",
            '看板未启动')
        return
    }
    Start-Process "http://localhost:$port/"
})
$btnLogs.Add_Click({ Start-Process $script:LogDir })
$btnCfg.Add_Click({ Start-Process 'notepad.exe' $script:CfgPath })

$btnLook.Add_Click({
    $dlg.BackColor = $form.BackColor
    $dlg.ForeColor = $script:Th.Fg
    Set-ControlTheme $dlg
    Dlg-ToControls
    Dlg-Preview
    $r = $dlg.ShowDialog($form)
    if ($r -eq 'OK') { Save-Bg } else { Import-Bg $script:DlgBackup; Apply-Appearance }
})
$btnPick.Add_Click({
    $of = New-Object System.Windows.Forms.OpenFileDialog
    $of.Filter = '图片 (*.jpg;*.jpeg;*.png;*.bmp;*.gif)|*.jpg;*.jpeg;*.png;*.bmp;*.gif|所有文件 (*.*)|*.*'
    if ($of.ShowDialog() -eq 'OK') {
        $script:Bg.image = $of.FileName
        Apply-Appearance
        Dlg-Preview
    }
})
$btnClear.Add_Click({
    $script:Bg.image = ''
    Apply-Appearance
    Dlg-Preview
})
$tbBright.Add_Scroll({
    $script:Bg.brightness = $tbBright.Value
    $lbBrightVal.Text = ([string]$tbBright.Value)
    Request-Appearance
    Dlg-Preview
})
$tbOver.Add_Scroll({
    $script:Bg.overlay = $tbOver.Value
    $lbOverVal.Text = ([string]$tbOver.Value + '%')
    Request-Appearance
    Dlg-Preview
})
$cbOC.Add_SelectedIndexChanged({
    $v = 'auto'
    if ($cbOC.SelectedIndex -eq 1) { $v = 'white' } elseif ($cbOC.SelectedIndex -eq 2) { $v = 'black' }
    $script:Bg.overlayColor = $v
    Apply-Appearance
    Dlg-Preview
})
$cbTC.Add_SelectedIndexChanged({
    $v = 'auto'
    if ($cbTC.SelectedIndex -eq 1) { $v = 'dark' } elseif ($cbTC.SelectedIndex -eq 2) { $v = 'light' }
    $script:Bg.textColor = $v
    Apply-Appearance
    Dlg-Preview
})

# ListView 第一列跟随窗口宽度拉伸
$lv.Add_Resize({
    $others = 0
    for ($i = 1; $i -lt $lv.Columns.Count; $i++) { $others += $lv.Columns[$i].Width }
    $w = $lv.ClientSize.Width - $others - (SX 26)
    if ($w -gt (SX 160)) { $lv.Columns[0].Width = $w }
})

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400     # 数据是异步拉的, 刷得勤一点界面更跟手
$script:Timer.Add_Tick({ Tick })

# 外观重绘去抖定时器 (见 Request-Appearance)
$script:AppTimer = New-Object System.Windows.Forms.Timer
$script:AppTimer.Interval = 160
$script:AppTimer.Add_Tick({ $script:AppTimer.Stop(); Apply-Appearance })

$form.Add_ResizeBegin({ $script:Resizing = $true })
$form.Add_ResizeEnd({
    $script:Resizing = $false
    $script:LastApplied = [System.Drawing.Size]::new(0, 0)   # 强制重画一次
    Apply-Appearance
})
$form.Add_Resize({
    if ($script:Resizing) { return }
    if (-not $script:Bg.image) { return }
    $s = $form.ClientSize
    if ([math]::Abs($s.Width - $script:LastApplied.Width) -lt (SX 24) -and `
        [math]::Abs($s.Height - $script:LastApplied.Height) -lt (SX 24)) { return }
    Request-Appearance
})
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Child -and -not $script:Child.HasExited) {
        $r = [System.Windows.Forms.MessageBox]::Show('下载仍在进行，确定要退出吗？（会停止下载）', '确认退出', 'YesNo', 'Question')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Download
    }
})

# ===========================================================================
# 初始化
# ===========================================================================
Update-SourceEnabled
$def = @($script:Cfg.defaultUrls)
if ($def.Count -gt 0 -and $def[0]) { $tbUrls.Text = ($def -join "`r`n") }
$outDefault = Resolve-Tpl $script:Cfg.outDir
if (-not $outDefault) { $outDefault = Join-Path $script:Root 'downloads' }
$tbOut.Text = $outDefault
$script:DlgBackup = $script:Bg.PSObject.Copy()
Apply-Appearance
Refresh-Tasks
Show-TaskInfo

if ($SelfTest) {
    $okImg = 'none'
    if ($script:Bg.image -and (Test-Path -LiteralPath $script:Bg.image)) {
        $r = New-BgBitmap $script:Bg.image ([int]$script:Bg.brightness) ([int]$script:Bg.overlay) ([string]$script:Bg.overlayColor) $form.ClientSize.Width $form.ClientSize.Height
        if ($r) { $okImg = ('luma={0:N0}' -f $r.Luma) }
    }
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    Write-Host ("SELFTEST OK  dpi={0:N0} ({1})  scale={2:N2}  fontScale={3:N2}  font={4:N1}pt  window={5}x{6}  screen={7}x{8}" -f `
            $script:Dpi, $script:DpiMode, $script:Scale, $script:FontScale, $script:FontPt,
        $form.ClientSize.Width, $form.ClientSize.Height,
        $screen.Bounds.Width, $screen.Bounds.Height)
    Write-Host ("              controls={0}  tasks={1}  bg={2}  theme={3}" -f `
            $form.Controls.Count, $script:Tasks.Count, $okImg, `
        $(if ($script:Th.Fg.R -lt 128) { 'dark-text-on-bright-bg' } else { 'light-text-on-dark-bg' }))
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
