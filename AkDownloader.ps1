<#
  AkDownloader.ps1  -  HyperGryph launcher package download accelerator
  ==========================================================================
  这个脚本把之前排障过程中踩到的所有坑都固化了下来：

  1) 连接假死    CDN 经常让连接停住不发数据。只设 --connect-timeout 没用
                 （它只覆盖建连阶段）。必须加传输阶段看门狗：
                 --speed-limit 4096 --speed-time 25
  2) 并发塌陷    每个文件单独开一个 worker 池，文件下到最后只剩几块时并发会
                 塌到个位数，而 CDN 是按连接限速的，总速度随之崩塌。
                 这里改成所有文件的全部小分块进同一个全局队列。
  3) 数据串号    不同文件的字节区间会重叠，分块临时文件必须带目标 tag
                 （{tag}_{start}_{end}.bin），否则 A 文件的数据会被当成 B 文件的。
  4) 大小读不到  Windows 下用 Get-Item 读一个正被写入的文件，返回的是目录项里
                 的陈旧大小（通常是 0）。必须用共享读句柄读 .Length。
  5) 变量名冲突  PowerShell 变量名大小写不敏感，$target 会覆盖 $TARGET。
  6) task not found PowerShell 5.1's Split-Path -LiteralPath parameter set only
                 has LiteralPath/Resolve and rejects -Parent (PS7 allows it),
                 throwing "parameter set cannot be resolved"; the try/catch
                 swallowed it, the task object stayed $null and it looked like
                 "no download task found". Use [System.IO.Path]::GetDirectoryName().

  用法
    .\AkDownloader.ps1                        SDK 模式，自动提取启动器分包地址
    .\AkDownloader.ps1 -Plan                  只显示计划，不下载
    .\AkDownloader.ps1 -Workers 64            调整并发
    .\AkDownloader.ps1 -Url "https://a/b.bin" -OutDir D:\dl     手动地址模式
    .\AkDownloader.ps1 -UrlFile urls.txt      手动地址模式（每行一个 URL）
    .\AkDownloader.ps1 -Force                 不等待启动器关闭
#>
[CmdletBinding()]
param(
    [string]$Config,
    [string]$Url,
    [string]$UrlFile,
    [string]$OutDir,
    [int]$Workers = 0,
    [int]$ChunkMB = 0,
    [int]$Port = -1,
    [switch]$NoBrowser,
    [switch]$AutoLaunch,
    [switch]$Force,
    [switch]$Plan,
    [string]$TaskConfig,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Continue'
$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:Curl = Join-Path $env:WINDIR 'System32\curl.exe'

# ===========================================================================
# helpers
# ===========================================================================
function Resolve-Tpl([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    $rx = [regex]'%([^%]+)%'
    $ms = $rx.Matches($s)
    if ($ms.Count -eq 0) { return $s }
    $sb  = New-Object System.Text.StringBuilder
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
function MB([long]$n) { return [math]::Round($n / 1MB, 1) }

$script:LogRing = New-Object System.Collections.ArrayList
function Log([string]$m, [string]$level = 'INFO') {
    $line = "{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $m
    [void]$script:LogRing.Add($line)
    if ($script:LogRing.Count -gt 400) { $script:LogRing.RemoveAt(0) }
    # 必须用 Write-Host: 用 Write-Output 的话, 函数内打印的日志会混进函数返回值
    Write-Host $line
    if ($script:LogFile) { try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 } catch { } }
}

# 关键修复: 正在被写入的文件, Get-Item 返回陈旧大小, 必须用共享读句柄
function Get-LiveSize([string]$path) {
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { return [long]$fs.Length } finally { $fs.Dispose() }
    } catch {
        try { return [long](Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).Length } catch { return [long]0 }
    }
}
function ChunkPath([string]$tag, [long]$s, [long]$e) {
    Join-Path $script:ChunkDir ("{0}_{1}_{2}.bin" -f $tag, $s, $e)
}

# ===========================================================================
# config
# ===========================================================================
if (-not $Config) { $Config = Join-Path $script:Root 'config.json' }
if (-not (Test-Path -LiteralPath $Config)) { Write-Output "config not found: $Config"; exit 1 }
$Cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json

$script:ChunkDir = Resolve-Tpl $Cfg.workDir
$logDir          = Resolve-Tpl $Cfg.logDir
foreach ($d in @($script:ChunkDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:LogFile = Join-Path $logDir ("akdl_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$Workers = if ($Workers -gt 0) { $Workers } else { [int]$Cfg.workers }
$ChunkMB = if ($ChunkMB -gt 0) { $ChunkMB } else { [int]$Cfg.chunkMB }
$Port    = if ($Port -ge 0) { $Port } else { [int]$Cfg.port }

Log "=============================================================="
Log ("AkDownloader start  pid={0}" -f $PID)
Log ("workers={0}  chunk={1}MB  port={2}" -f $Workers, $ChunkMB, $Port)
Log ("chunk dir : $($script:ChunkDir)")
Log ("log file  : $($script:LogFile)")

if (-not (Test-Path -LiteralPath $script:Curl)) { Log "curl.exe not found: $script:Curl" 'ERROR'; exit 1 }

$busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Launcher|Updater|Patch|Games)$' })
if ($busy.Count -gt 0 -and -not $Force) {
    Log ("launcher/game running: " + (($busy | ForEach-Object { $_.ProcessName }) -join ', ')) 'WARN'
    Write-Output "Close the launcher/game first, then press Enter (Ctrl+C aborts)."
    try { Read-Host | Out-Null } catch { }
}

# ===========================================================================
# build the plan
# ===========================================================================
$parts   = New-Object System.Collections.ArrayList
$mode    = ''
$title   = [string]$Cfg.ui.title
$targets = ''

function New-Part($idx, $tag, $name, $url, $target, $size, $existing, $single) {
    $done = ($size -gt 0 -and $existing -ge $size)
    return [pscustomobject]@{
        Idx = $idx; Tag = $tag; Name = $name; Url = $url; Target = $target
        Size = $size; Existing = $existing; Single = $single
        Reuse = @(); Todo = @(); Pending = 0; Assembled = $done
    }
}

function Read-TaskFile([string]$cfgPath) {
    # 解析单个 download_sdk_config, 返回其中最新的一个任务 (无任务返回 $null)
    $best = $null
    try {
        $c = Get-Item -LiteralPath $cfgPath
        $raw = Get-Content -LiteralPath $c.FullName -Raw -Encoding UTF8
        Log ("  config: {0}  ({1} bytes)" -f $c.FullName, $raw.Length)
        $arr = @($raw | ConvertFrom-Json)
        $first = if (@($arr).Count -gt 0) { $arr[0] } else { $null }
        if ($null -eq $first) {
            Log "  -> EMPTY task list (launcher already finished or cleared this task)" 'WARN'
            return $null
        }
        Log ("  -> {0} task entry(ies)" -f @($arr).Count)
        foreach ($t in $arr) {
            if (-not $t.file_list -or @($t.file_list).Count -eq 0) { continue }
            [long]$upd = 0
            try { $upd = [long]$t.update } catch { }
            $game = 'game'
            $m = [regex]::Match($c.FullName, '\\games\\([^\\]+)\\')
            if ($m.Success) { $game = $m.Groups[1].Value }
            # Note: PS 5.1's Split-Path -LiteralPath parameter set has only
            # LiteralPath/Resolve and does NOT accept -Parent (PS7 does), it throws
            # "parameter set cannot be resolved". Use .NET GetDirectoryName so the
            # path is also treated literally (no glob chars like [ ]).
            $dir = Join-Path ([System.IO.Path]::GetDirectoryName($c.FullName)) ([string]$t.version_id)
            $o = [pscustomobject]@{
                ConfigPath = $c.FullName; Game = $game; Update = $upd
                VersionId = $t.version_id; OutDir = $dir
                TotalSize = [long]$t.total_size
                Files = @($t.file_list | Sort-Object file_id)
            }
            if ($null -eq $best -or $o.Update -gt $best.Update) { $best = $o }
        }
    } catch {
        Log ("  parse failed for {0}: {1}" -f $cfgPath, $_.Exception.Message) 'WARN'
    }
    return $best
}

function Get-SdkTasks([string]$root) {
    # 扫描启动器目录, 返回所有可用的下载任务 (GUI 的任务列表用它)
    $found = New-Object System.Collections.ArrayList
    $gamesDir = Join-Path $root 'games'
    if (-not (Test-Path -LiteralPath $gamesDir)) { $gamesDir = Join-Path $root 'Games' }
    if (Test-Path -LiteralPath $gamesDir) {
        foreach ($g in @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($lt in @(Get-ChildItem -LiteralPath $g.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($h in @(Get-ChildItem -LiteralPath $lt.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $f = Join-Path $h.FullName 'download\download_sdk_config'
                    if ((Test-Path -LiteralPath $f) -and -not $found.Contains($f)) { [void]$found.Add($f) }
                }
            }
        }
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($fn in $found) {
        $t = Read-TaskFile $fn
        if ($t) { [void]$list.Add($t) }
    }
    return @($list | Sort-Object Update -Descending)
}

function Find-SdkTask([string]$root) {
    # 按已知目录结构精确查找, 不要 -Recurse 全盘扫 (游戏目录里有十几 GB 的数据文件)
    # 注意: Get-ChildItem -Filter 对"无扩展名文件"的匹配不可靠, 这里用 -Path 通配
    $found = New-Object System.Collections.ArrayList
    # 注意: Get-ChildItem 只展开"最后一段"的通配符, 中间段通配符是无效的,
    # 所以这里逐层枚举 (games\<game>\launcher_tmp\<hash>\download\download_sdk_config)
    $gamesDir = Join-Path $root 'games'
    if (-not (Test-Path -LiteralPath $gamesDir)) { $gamesDir = Join-Path $root 'Games' }
    if (Test-Path -LiteralPath $gamesDir) {
        foreach ($g in @(Get-ChildItem -LiteralPath $gamesDir -Directory -ErrorAction SilentlyContinue)) {
            foreach ($lt in @(Get-ChildItem -LiteralPath $g.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($h in @(Get-ChildItem -LiteralPath $lt.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $f = Join-Path $h.FullName 'download\download_sdk_config'
                    if ((Test-Path -LiteralPath $f) -and -not $found.Contains($f)) { [void]$found.Add($f) }
                }
            }
        }
    }
    if ($found.Count -eq 0) {
        $gamesDir = Join-Path $root 'games'
        if (Test-Path -LiteralPath $gamesDir) {
            Log "pattern match failed - falling back to depth-4 scan"
            foreach ($c in @(Get-ChildItem -LiteralPath $gamesDir -Recurse -Depth 4 -File -ErrorAction SilentlyContinue)) {
                if ($c.Name -eq 'download_sdk_config' -and -not $found.Contains($c.FullName)) { [void]$found.Add($c.FullName) }
            }
        }
    }
    Log ("candidate config file(s): " + $found.Count)
    $best = $null
    foreach ($fn in $found) {
        $t = Read-TaskFile $fn
        if ($t -and ($null -eq $best -or $t.Update -gt $best.Update)) { $best = $t }
    }
    return $best
}

if ($Url -or $UrlFile) {
    # ---------------- manual URL mode ----------------
    $mode = 'url'
    $urls = New-Object System.Collections.ArrayList
    if ($Url) { [void]$urls.Add($Url) }
    if ($UrlFile) {
        foreach ($l in @(Get-Content -LiteralPath $UrlFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $t = $l.Trim()
            if ($t -and -not $t.StartsWith('#')) { [void]$urls.Add($t) }
        }
    }
    if ($urls.Count -eq 0) { Log "no URL supplied" 'ERROR'; exit 1 }

    if (-not $OutDir) { $OutDir = Resolve-Tpl $Cfg.outDir }
    if (-not $OutDir) { $OutDir = Join-Path $script:Root 'downloads' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $targets = $OutDir
    $title   = "$($Cfg.ui.title) - URL mode"

    $idx = 0
    foreach ($u in $urls) {
        $name = ''
        try { $name = [System.IO.Path]::GetFileName(([uri]$u).AbsolutePath) } catch { }
        if (-not $name) { $name = "file$idx" }
        $dst = Join-Path $OutDir $name
        [long]$existing = 0
        if (Test-Path -LiteralPath $dst) { $existing = Get-LiveSize $dst }

        [long]$size = 0
        [bool]$rangesOk = $false
        $hdrs = @(& $script:Curl -s -S -L --max-time 30 -r 0-0 -D - -o NUL $u 2>$null)
        foreach ($h in $hdrs) {
            if ($h -match '^(?i)content-range:\s*bytes\s+\d+-\d+/(\d+)') { $size = [long]$Matches[1]; $rangesOk = $true }
            elseif ($h -match '^(?i)content-length:\s*(\d+)') { if ($size -le 1) { $size = [long]$Matches[1] } }
        }
        $single = (-not $rangesOk) -or ($size -le 0)
        Log ("url[{0}] {1}  size={2} MB  have={3} MB  ranges={4}" -f $idx, $name, (MB $size), (MB $existing), $rangesOk)
        [void]$parts.Add((New-Part $idx "u$idx" $name $u $dst $size $existing $single))
        $idx++
    }
}
else {
    # ---------------- SDK mode (auto discover) ----------------
    $mode = 'sdk'
    # 注意: 这里千万不要用 $root —— PowerShell 变量名大小写不敏感,
    # $root 和 $script:Root 是同一个变量, 赋值会静默把"脚本所在目录"改成
    # 启动器目录 (同一类坑 README 里的第 5 条已经踩过一次)。
    # 后果: $script:HtmlPath 变成 <启动器目录>\AkDownloader.html -> 找不到,
    # 看板只能给一个占位页, 表现就是"看板拉不起来"。
    $launcherDir = Resolve-Tpl $Cfg.launcherRoot
    if ($TaskConfig) {
        Log ("using task config from command line: $TaskConfig")
        $task = Read-TaskFile $TaskConfig
    } else {
        Log ("discovering launcher task under: $launcherDir")
        $task = Find-SdkTask $launcherDir
    }

    if (-not $task) {
        $def = @($Cfg.defaultUrls)
        if ($def.Count -gt 0 -and $def[0]) {
            Log "no launcher task found; falling back to defaultUrls in config.json" 'WARN'
            $mode = 'url'
            $OutDir = Resolve-Tpl $Cfg.outDir
            if (-not $OutDir) { $OutDir = Join-Path $script:Root 'downloads' }
            if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
            $targets = $OutDir
            $i = 0
            foreach ($u in $def) {
                $n = ''
                try { $n = [System.IO.Path]::GetFileName(([uri]$u).AbsolutePath) } catch { }
                if (-not $n) { $n = "file$i" }
                $dst = Join-Path $OutDir $n
                [long]$ex = 0
                if (Test-Path -LiteralPath $dst) { $ex = Get-LiveSize $dst }
                [void]$parts.Add((New-Part $i "u$i" $n $u $dst 0 $ex $true))
                $i++
            }
        } else {
            Log "no download_sdk_config found. Use -Url / -UrlFile, or run the launcher once so it creates a task." 'ERROR'
            exit 1
        }
    }
    else {
        $targets = $task.OutDir
        $title = "$($Cfg.ui.title) - $($task.Game) $($task.VersionId)"
        Log ("task      : game={0}  version={1}" -f $task.Game, $task.VersionId)
        Log ("config    : $($task.ConfigPath)")
        Log ("target dir: $targets")
        Log ("total     : $(MB $task.TotalSize) MB in $($task.Files.Count) part(s)")
        if (-not (Test-Path -LiteralPath $targets)) { New-Item -ItemType Directory -Path $targets -Force | Out-Null }
        foreach ($f in $task.Files) {
            $dst = Join-Path $targets $f.download_path
            [long]$existing = 0
            if (Test-Path -LiteralPath $dst) { $existing = Get-LiveSize $dst }
            [void]$parts.Add((New-Part ([int]$f.file_id) ("p$($f.file_id)") ([string]$f.download_path) ([string]$f.url) $dst ([long]$f.size) $existing $false))
        }
    }
}

# ===========================================================================
# single-stream fallback (unknown size / no range support)
# ===========================================================================
foreach ($p in $parts) {
    if (-not $p.Single -or $p.Assembled) { continue }
    Log ("single-stream: " + $p.Name)
    & $script:Curl -L --fail -C - -o $p.Target $p.Url
    if (Test-Path -LiteralPath $p.Target) {
        [long]$sz = Get-LiveSize $p.Target
        if ($p.Size -le 0) { $p.Size = $sz }
        if ($sz -eq $p.Size -and $sz -gt 0) { $p.Assembled = $true; Log ("  [done] {0} = {1} MB" -f $p.Name, (MB $sz)) }
        else { Log ("  [WARN] {0}: got {1} bytes" -f $p.Name, $sz) 'WARN' }
    }
}

# ===========================================================================
# resume: reuse complete chunks, split the rest into small pieces
# ===========================================================================
$tmpFiles = @(Get-ChildItem -LiteralPath $script:ChunkDir -Filter '*.bin' -File -ErrorAction SilentlyContinue)
$accepted = New-Object 'System.Collections.Generic.HashSet[string]'
[long]$piece = $ChunkMB * 1MB

# 按 tag 给分块建索引。
# 原来这里是"每个目标 x 每个分块文件"的两重循环: 本工具一次要下 13000+ 个
# 4MB 分块, 实测 54 x 3507 = 18.9 万次迭代就要 4.3 秒, 54 x 13500 = 72.9 万次
# 要十几秒。而看板是在规划之后才启动的 —— 这段时间里点"打开看板"就是连不上。
# 先扫一遍建索引, 之后每个目标只看自己那些分块。
$chunkIndex = @{}
foreach ($tf in $tmpFiles) {
    $seg = $tf.BaseName -split '_'
    if ($seg.Count -lt 3) { continue }
    [long]$cs = 0; [long]$ce = 0
    if (-not [long]::TryParse($seg[-2], [ref]$cs)) { continue }
    if (-not [long]::TryParse($seg[-1], [ref]$ce)) { continue }
    $ctag = $seg[0]
    if (-not $chunkIndex.ContainsKey($ctag)) { $chunkIndex[$ctag] = New-Object System.Collections.ArrayList }
    [void]$chunkIndex[$ctag].Add([pscustomobject]@{ File = $tf; Start = $cs; End = $ce })
}

foreach ($p in $parts) {
    if ($p.Single -or $p.Assembled -or $p.Size -le 0) { continue }

    $reuse = New-Object System.Collections.ArrayList
    $cand = @()
    if ($chunkIndex.ContainsKey($p.Tag)) { $cand = $chunkIndex[$p.Tag] }
    foreach ($c in $cand) {
        if ($c.Start -lt $p.Existing -or $c.End -gt ($p.Size - 1)) { continue }
        if (($c.End - $c.Start + 1) -ne [long]$c.File.Length) { continue }
        [void]$reuse.Add([pscustomobject]@{ Start = $c.Start; End = $c.End })
        [void]$accepted.Add($c.File.FullName)
    }
    $p.Reuse = @($reuse | Sort-Object Start)

    $gaps = New-Object System.Collections.ArrayList
    [long]$cur = $p.Existing
    foreach ($c in $p.Reuse) {
        if ($c.Start -gt $cur) { [void]$gaps.Add([pscustomobject]@{ Start = $cur; End = [math]::Min($p.Size - 1, $c.Start - 1) }) }
        if (($c.End + 1) -gt $cur) { $cur = $c.End + 1 }
    }
    if ($cur -lt $p.Size) { [void]$gaps.Add([pscustomobject]@{ Start = $cur; End = $p.Size - 1 }) }

    $todo = New-Object System.Collections.ArrayList
    foreach ($g in $gaps) {
        [long]$s = $g.Start
        while ($s -le $g.End) {
            [long]$e = [math]::Min($g.End, $s + $piece - 1)
            [void]$todo.Add([pscustomobject]@{ Start = $s; End = $e })
            $s = $e + 1
        }
    }
    $p.Todo = @($todo | Sort-Object Start)
    $p.Pending = $p.Todo.Count
}
# 用 .NET 直接删: PS 5.1 的 Remove-Item 每个文件要好几毫秒, 上万个残留分块
# 累加就是几十秒, 而且同样发生在看板启动之前。
$staleDeleted = 0
foreach ($tf in $tmpFiles) {
    if ($accepted.Contains($tf.FullName)) { continue }
    try { [System.IO.File]::Delete($tf.FullName); $staleDeleted++ } catch { }
}
if ($staleDeleted -gt 0) { Log ("cleaned {0} stale chunk file(s)" -f $staleDeleted) }

[long]$grandTotal = 0
foreach ($p in $parts) { $grandTotal += $p.Size }
$todoCount = 0
foreach ($p in $parts) { $todoCount += $p.Todo.Count }

Log ("plan      : {0} file(s), {1} chunk(s) to fetch" -f $parts.Count, $todoCount)
foreach ($p in $parts) {
    $short = $p.Name -replace '_[0-9]+_[0-9]+$', ''
    if ($p.Assembled) { Log ("  [done] {0,-24} {1} MB" -f $short, (MB $p.Size)); continue }
    [long]$rb = 0; foreach ($r in $p.Reuse) { $rb += ($r.End - $r.Start + 1) }
    [long]$tb = 0; foreach ($t in $p.Todo) { $tb += ($t.End - $t.Start + 1) }
    Log ("  [todo] {0,-24} {1} MB  reuse={2} MB  fetch={3} MB" -f $short, (MB $p.Size), (MB $rb), (MB $tb))
}

function Get-InFlightSizes {
    # 正在下载的那几个分块: 目录项里的长度是陈旧的, 必须用共享读句柄读实时大小
    # (这就是本脚本的坑 #4)。只有 Workers 个文件, 代价可以忽略。
    $map = @{}
    $v = Get-Variable -Name running -Scope Script -ErrorAction SilentlyContinue
    if (-not $v -or -not $v.Value) { return $map }
    foreach ($r in @($v.Value)) {
        try {
            $cp = ChunkPath $r.job.Part.Tag $r.job.Start $r.job.End
            $map[$cp] = Get-LiveSize $cp
        } catch { }
    }
    return $map
}

function Get-ChunkScan {
    # 扫描分块目录, 返回 @{ ByTag = @{tag=bytes}; Bytes = 总字节; Rows = 未完成分块 }
    #
    # 性能关键: 以前这里是 Get-ChildItem | ForEach-Object { Get-LiveSize },
    # 也就是每个分块都 File.Open 一次。分块上万个时实测:
    #   Get-LiveSize 逐个打开 : 3000 个 = 484 ms  -> 13500 个 ≈ 2.3 秒
    #   FileInfo.Length 目录项: 3000 个 =  13 ms  -> 快 37 倍
    # 而 /data 每秒被浏览器+控制台各拉一次, 2 秒的响应会让看板一直转圈、
    # 图形控制台被卡死。所以: 用目录项长度统计, 只对"正在写"的分块读实时大小。
    $byTag = @{}
    $rows = New-Object System.Collections.ArrayList
    [long]$total = 0
    if (-not (Test-Path -LiteralPath $script:ChunkDir)) {
        return [pscustomobject]@{ ByTag = $byTag; Bytes = 0; Rows = $rows }
    }
    $live = Get-InFlightSizes
    try {
        $di = New-Object System.IO.DirectoryInfo($script:ChunkDir)
        foreach ($fi in $di.EnumerateFiles('*.bin')) {
            [long]$len = 0
            if ($live.ContainsKey($fi.FullName)) { $len = [long]$live[$fi.FullName] } else { $len = [long]$fi.Length }
            $total += $len
            $seg = [System.IO.Path]::GetFileNameWithoutExtension($fi.Name) -split '_'
            $tag = $seg[0]
            if ($byTag.ContainsKey($tag)) { $byTag[$tag] += $len } else { $byTag[$tag] = $len }
            [long]$st = 0; [long]$en = 0
            if ($seg.Count -ge 3) {
                [void][long]::TryParse($seg[-2], [ref]$st)
                [void][long]::TryParse($seg[-1], [ref]$en)
            }
            if ($en -gt $st) {
                [long]$exp = $en - $st + 1
                if ($len -lt $exp) {
                    [void]$rows.Add([pscustomobject]@{ tag = $tag; start = $st; size = $len; expect = $exp })
                }
            }
        }
    } catch { }
    return [pscustomobject]@{ ByTag = $byTag; Bytes = $total; Rows = $rows }
}

function Get-LiveTotal {
    [long]$b = 0
    foreach ($p in $parts) { if ($p.Assembled) { $b += $p.Size } else { $b += $p.Existing } }
    $b += (Get-ChunkScan).Bytes
    return $b
}

if ($Plan) {
    Log ("plan only (-Plan). bytes already on disk: $(MB (Get-LiveTotal)) MB / $(MB $grandTotal) MB")
    exit 0
}

# ===========================================================================
# dashboard (served from this same process)
# ===========================================================================
$script:Listener = $null
$script:Done = $false
$script:Samples = New-Object System.Collections.ArrayList

function Get-DashData {
    $rows = New-Object System.Collections.ArrayList
    $scan = Get-ChunkScan
    $byTag = $scan.ByTag
    $chunks = $scan.Rows
    [long]$chunkBytes = $scan.Bytes

    [long]$totalHave = 0
    foreach ($p in $parts) {
        [long]$have = 0
        if (Test-Path -LiteralPath $p.Target) { $have = Get-LiveSize $p.Target }
        if ($byTag.ContainsKey($p.Tag)) { $have += [long]$byTag[$p.Tag] }
        if ($have -gt $p.Size) { $have = $p.Size }
        $totalHave += $have
        [void]$rows.Add([pscustomobject]@{
            idx = $p.Idx
            name = ($p.Name -replace '_[0-9]+_[0-9]+$', '')
            size = $p.Size; have = $have; done = ($p.Size -gt 0 -and $have -ge $p.Size)
        })
    }

    $now = Get-Date
    [void]$script:Samples.Add([pscustomobject]@{ t = $now; b = $totalHave })
    while ($script:Samples.Count -gt 1 -and ($now - $script:Samples[0].t).TotalSeconds -gt 15) { $script:Samples.RemoveAt(0) }
    $speed = 0
    if ($script:Samples.Count -ge 2) {
        $dt = ($now - $script:Samples[0].t).TotalSeconds
        $db = $totalHave - $script:Samples[0].b
        if ($dt -gt 0.5 -and $db -ge 0) { $speed = [long]($db / $dt) }
    }
    $eta = -1
    if ($speed -gt 1024 -and $grandTotal -gt 0) { $eta = [long](($grandTotal - $totalHave) / $speed) }

    $tail = @()
    $n = $script:LogRing.Count
    $from = [math]::Max(0, $n - 16)
    for ($i = $from; $i -lt $n; $i++) { $tail += $script:LogRing[$i] }

    return [pscustomobject]@{
        now = $now.ToString('HH:mm:ss')
        title = $title
        subtitle = [string]$Cfg.ui.subtitle
        mode = $mode
        workers = $Workers
        totalSize = $grandTotal
        totalHave = $totalHave
        inFlight = $chunkBytes
        speed = $speed
        eta = $eta
        procs = @(Get-Process curl -ErrorAction SilentlyContinue).Count
        finished = $script:Done
        targets = $targets
        installHint = [string]$Cfg.ui.installHint
        launcher = Resolve-Tpl $Cfg.launcherExe
        parts = $rows
        chunks = @($chunks | Sort-Object tag, start)
        log = $tail
    }
}

$script:HtmlPath = Join-Path $script:Root 'AkDownloader.html'
function Get-Html {
    if (Test-Path -LiteralPath $script:HtmlPath) {
        return [System.IO.File]::ReadAllText($script:HtmlPath, [System.Text.Encoding]::UTF8)
    }
    return '<!DOCTYPE html><html><body style="background:#0b0f17;color:#eee;font:14px sans-serif;padding:40px"><h2>AkDownloader.html not found</h2><p>Put AkDownloader.html next to AkDownloader.ps1</p></body></html>'
}

function Send-Response($client, [string]$body, [string]$ctype) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $head = "HTTP/1.1 200 OK`r`nContent-Type: $ctype`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $st = $client.GetStream()
    $st.Write($hb, 0, $hb.Length)
    $st.Write($bytes, 0, $bytes.Length)
    $st.Flush()
}

function Serve-Pending {
    if (-not $script:Listener) { return }
    $guard = 0
    while ($script:Listener.Pending() -and $guard -lt 16) {
        $guard++
        $client = $null
        try {
            $client = $script:Listener.AcceptTcpClient()
            $reader = New-Object System.IO.StreamReader($client.GetStream(), [System.Text.Encoding]::ASCII)
            $reqLine = $reader.ReadLine()
            while ($true) { $l = $reader.ReadLine(); if ([string]::IsNullOrEmpty($l)) { break } }
            $path = '/'
            if ($reqLine) { $sp = $reqLine.Split(' '); if ($sp.Count -ge 2) { $path = $sp[1] } }
            if ($path -like '/data*') { Send-Response $client (Get-DashData | ConvertTo-Json -Depth 6 -Compress) 'application/json; charset=utf-8' }
            elseif ($path -eq '/favicon.ico') { Send-Response $client '' 'image/x-icon' }
            else { Send-Response $client (Get-Html) 'text/html; charset=utf-8' }
        } catch {
        } finally {
            if ($client) { $client.Close() }
        }
    }
}

function Wait-Dash([double]$seconds) {
    # 把等待切成 ~120ms 一段, 期间不断地服务看板请求。
    # 以前是 Start-Sleep -Seconds 1 + Serve-Pending 一次: 看板的响应延迟最多
    # 1 秒, 浏览器页面和图形控制台都会表现成"看板拉不起来 / 界面很卡"。
    $end = (Get-Date).AddSeconds($seconds)
    while ($true) {
        Serve-Pending
        $left = ($end - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int][math]::Min(120, $left))
    }
}

if ($Port -gt 0) {
    try {
        $script:Listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $script:Listener.Start()
        Log ("dashboard : http://localhost:$Port/")
        # 页面文件找不到时只能给个占位页, 界面上就是"看板拉不起来", 这里明说
        $pageOk = Test-Path -LiteralPath $script:HtmlPath
        Log ("page      : $($script:HtmlPath)  ($(if ($pageOk) { 'found' } else { 'MISSING - placeholder page will be served' }))")
        if ($Cfg.openBrowser -and -not $NoBrowser) { try { Start-Process "http://localhost:$Port/" } catch { } }
    } catch {
        Log ("cannot start dashboard on port ${Port}: " + $_.Exception.Message) 'WARN'
        $script:Listener = $null
    }
}

# ===========================================================================
# assembly
# ===========================================================================
function Invoke-Assembly($p) {
    if ($p.Assembled) { return $true }
    $all = @(@($p.Reuse) + @($p.Todo)) | Sort-Object Start
    $ok = $true
    [long]$expect = $p.Existing
    foreach ($r in $all) {
        if ($r.Start -ne $expect) { Log ("  [ERROR] {0}: gap at {1}, expected {2}" -f $p.Name, $r.Start, $expect) 'ERROR'; $ok = $false; break }
        $cf = ChunkPath $p.Tag $r.Start $r.End
        if (-not (Test-Path -LiteralPath $cf) -or (Get-LiveSize $cf) -ne ($r.End - $r.Start + 1)) {
            Log ("  [ERROR] {0}: bad chunk {1}-{2}" -f $p.Name, $r.Start, $r.End) 'ERROR'; $ok = $false; break
        }
        $expect = $r.End + 1
    }
    if ($ok -and $expect -ne $p.Size) { Log ("  [ERROR] {0}: coverage {1}/{2}" -f $p.Name, $expect, $p.Size) 'ERROR'; $ok = $false }
    if (-not $ok) { return $false }

    Log ("  assembling {0} from {1} chunk(s)" -f $p.Name, $all.Count)
    try {
        $fs = [System.IO.File]::Open($p.Target, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try {
            foreach ($r in $all) {
                $src = [System.IO.File]::OpenRead((ChunkPath $p.Tag $r.Start $r.End))
                try { $src.CopyTo($fs) } finally { $src.Dispose() }
                # 1 GB 的文件要拼 256 个分块, 这几秒里主线程没空服务看板,
                # 页面会卡在"加载中"——每拼一块顺手服务一次 (无请求时几乎零开销)
                Serve-Pending
            }
        } finally { $fs.Dispose() }
    } catch {
        Log ("  [ERROR] {0}: assemble failed: {1}" -f $p.Name, $_.Exception.Message) 'ERROR'
        return $false
    }

    [long]$final = -1
    try { $final = (Get-Item -LiteralPath $p.Target).Length } catch { }
    if ($final -ne $p.Size) { Log ("  [ERROR] {0}: size {1} != {2}" -f $p.Name, $final, $p.Size) 'ERROR'; return $false }

    foreach ($r in $all) { Remove-Item -LiteralPath (ChunkPath $p.Tag $r.Start $r.End) -Force -ErrorAction SilentlyContinue }
    $p.Assembled = $true
    Log ("  [done] {0} = {1} MB" -f ($p.Name -replace '_[0-9]+_[0-9]+$', ''), (MB $final))
    return $true
}

# ===========================================================================
# global worker pool (all files share one queue -> no tail collapse)
# ===========================================================================
$queue = New-Object System.Collections.Queue
foreach ($p in $parts) {
    if ($p.Assembled) { continue }
    foreach ($t in $p.Todo) { $queue.Enqueue([pscustomobject]@{ Part = $p; Start = $t.Start; End = $t.End }) }
}

[long]$baseline = Get-LiveTotal
Log ("baseline  : $(MB $baseline) MB already on disk")

$running = New-Object System.Collections.ArrayList
$retry = @{}
$stalls = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastLog = -20.0

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Workers -and $queue.Count -gt 0) {
        $job = $queue.Dequeue()
        $jp  = $job.Part
        $of  = ChunkPath $jp.Tag $job.Start $job.End
        $ca = @('-s', '-S', '--fail', '--location',
                '--retry', '2', '--retry-delay', '2',
                '--connect-timeout', ([string]$Cfg.connectTimeoutSec),
                '--speed-limit', ([string]$Cfg.speedLimitBps),
                '--speed-time',  ([string]$Cfg.speedTimeSec),
                '--max-time',    ([string]$Cfg.maxTimeSec),
                '-r', "$($job.Start)-$($job.End)", '-o', $of, $jp.Url)
        try {
            $pr = Start-Process -FilePath $script:Curl -ArgumentList $ca -PassThru -WindowStyle Hidden
            [void]$running.Add([pscustomobject]@{ proc = $pr; job = $job })
        } catch {
            [void]$queue.Enqueue($job)
        }
    }

    # 分段等待 + 持续服务看板 (原来是 sleep 1s 再服务一次, 看板延迟最多 1 秒)
    Wait-Dash 1

    $keep = New-Object System.Collections.ArrayList
    foreach ($r in $running) {
        if ($r.proc.HasExited) {
            $rp = $r.job.Part
            $of = ChunkPath $rp.Tag $r.job.Start $r.job.End
            [long]$got = 0
            if (Test-Path -LiteralPath $of) { $got = Get-LiveSize $of }
            if ($got -ne ($r.job.End - $r.job.Start + 1)) {
                if (Test-Path -LiteralPath $of) { Remove-Item -LiteralPath $of -Force -ErrorAction SilentlyContinue }
                $key = "$($rp.Tag)_$($r.job.Start)"
                if (-not $retry.ContainsKey($key)) { $retry[$key] = 0 }
                $retry[$key]++
                if ($retry[$key] -le [int]$Cfg.maxRetries) { [void]$queue.Enqueue($r.job); $stalls++ }
                else { Log ("  [WARN] give up on {0} {1}-{2} after {3} tries" -f $rp.Name, $r.job.Start, $r.job.End, $retry[$key]) 'WARN' }
            } else { $rp.Pending-- }
        } else { [void]$keep.Add($r) }
    }
    $running = $keep

    foreach ($p in $parts) {
        if ($p.Assembled -or $p.Pending -gt 0 -or $p.Single) { continue }
        [void](Invoke-Assembly $p)
    }

    if (($sw.Elapsed.TotalSeconds - $lastLog) -ge 20) {
        $lastLog = $sw.Elapsed.TotalSeconds
        [long]$live = Get-LiveTotal
        $dt = $sw.Elapsed.TotalSeconds
        $rate = if ($dt -gt 0) { ($live - $baseline) / 1MB / $dt } else { 0 }
        [long]$left = $grandTotal - $live
        $etaMin = -1
        if ($rate -gt 0.05) { $etaMin = [math]::Round($left / 1MB / $rate / 60, 1) }
        $pct = 0
        if ($grandTotal -gt 0) { $pct = [math]::Round($live / $grandTotal * 100, 2) }
        Log ("  active={0} queue={1} stalls={2}  {3}/{4} MB ({5}%)  {6} MB/s  ETA={7} min  elapsed={8} min" -f `
             $running.Count, $queue.Count, $stalls, (MB $live), (MB $grandTotal), $pct, `
             [math]::Round($rate, 2), $etaMin, [math]::Round($dt / 60, 1))
    }
}

Log ("download loop finished in " + [math]::Round($sw.Elapsed.TotalMinutes, 1) + " min")

# ===========================================================================
# final verification
# ===========================================================================
$bad = 0
[long]$verified = 0
foreach ($p in $parts) {
    [long]$sz = -1
    if (Test-Path -LiteralPath $p.Target) { $sz = (Get-Item -LiteralPath $p.Target).Length }
    if ($sz -eq $p.Size -and $p.Size -gt 0) { $verified += $p.Size }
    else { $bad++; Log ("  [FAIL] {0}: {1} != {2}" -f $p.Name, $sz, $p.Size) 'ERROR' }
}
Log ("verify    : $verified / $grandTotal bytes, bad = $bad")

$script:Done = $true
Serve-Pending

if ($bad -eq 0 -and $verified -ge $grandTotal) { Log "ALL FILES COMPLETE AND SIZE-VERIFIED" }
else { Log "INCOMPLETE - rerun this tool to resume" 'WARN' }

# ===========================================================================
# completion notice
# ===========================================================================
function Show-FinishNotice([string]$t, [string]$b) {
    if ($NoNotify) { return }
    try { for ($i = 0; $i -lt 3; $i++) { [console]::beep(900, 180); Start-Sleep -Milliseconds 120 } } catch { }
    if (-not $Cfg.notifyOnFinish) { return }
    try {
        # write a small helper script (UTF-8 with BOM in PS 5.1) to avoid all
        # command-line quoting problems with the message text
        $helper = Join-Path $logDir '_notify.ps1'
        $lines = @(
            'Add-Type -AssemblyName System.Windows.Forms',
            ('[void][System.Windows.Forms.MessageBox]::Show(@"' + [Environment]::NewLine + $b + [Environment]::NewLine + '"@, "' + ($t -replace '"','') + '")')
        )
        Set-Content -LiteralPath $helper -Value $lines -Encoding UTF8
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper) -WindowStyle Hidden
    } catch { }
}

$launcherPath = Resolve-Tpl $Cfg.launcherExe
if ($bad -eq 0) {
    $body = [string]$Cfg.ui.finishedBody
    $body = $body.Replace('{launcher}', $launcherPath).Replace('{targets}', $targets)
    Show-FinishNotice ([string]$Cfg.ui.finishedTitle) $body

    Write-Output ""
    Write-Output "=============================================================="
    Write-Output " DOWNLOAD COMPLETE"
    Write-Output " files : $targets"
    Write-Output " next  : run the launcher to continue installing"
    Write-Output "         $launcherPath"
    Write-Output " note  : do NOT extract the split zip manually and do NOT"
    Write-Output "         delete it before the launcher finishes installing"
    Write-Output "=============================================================="

    if ($Cfg.autoLaunchLauncher -or $AutoLaunch) {
        if (Test-Path -LiteralPath $launcherPath) {
            Log "starting launcher ..."
            try { Start-Process -FilePath $launcherPath } catch { Log ("failed to start launcher: " + $_.Exception.Message) 'WARN' }
        }
    }
}

if ($script:Listener) {
    $keepMin = [int]$Cfg.keepAliveMinutes
    if ($keepMin -gt 0) {
        Log ("dashboard stays alive for $keepMin min (Ctrl+C to stop) : http://localhost:$Port/")
        $deadline = (Get-Date).AddMinutes($keepMin)
        while ((Get-Date) -lt $deadline) { Wait-Dash 1 }
    }
    try { $script:Listener.Stop() } catch { }
}
Log "exit"
