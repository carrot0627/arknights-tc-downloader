# AkDownloader

主要台服下载太慢了遂找ai搓了个这玩意）

第一次玩vibecoding 搓出来的屎比较大请见谅捏



鹰角（HyperGryph）启动器游戏包 **多线程下载加速器 / 通用多线程下载器**（其实是台服hyperlink哈）

把前面排障过程中踩到的所有坑都固化了下来。实测把台服《明日方舟》17.4 GB 的下载从
**0.21 MB/s（预计 6 天）** 提升到 **3.0+ MB/s（约 80 分钟）**，约 **13~15 倍**。

---

## 快速开始

### 方式一：图形控制台（推荐）

```
双击 GUI.cmd
```

打开一个 WinForms 控制台窗口，包含：

| 区域 | 功能 |
|---|---|
| **下载源** | ①「自动提取启动器下载任务」：扫描并下拉选择任务（显示游戏名 / 版本 / 分片数 / 总量）<br>②「手动输入地址」：多行文本框，每行一个 URL，支持「从文件导入」 |
| **参数** | 并发连接数、分块大小(MB)、看板端口、自动打开看板 / 完成后弹窗提醒 / 完成后自动启动启动器 |
| **操作** | 开始下载、停止（会连带清掉 curl 子进程）、打开看板、打开日志目录、编辑配置 |
| **实时状态** | 进度条 + `完成率 / 速度 / 剩余时间 / 连接数 / 在途字节` |
| **文件列表** | 每个文件的 大小 / 已下载 / 进度 / 状态（完成的显示绿色） |
| **日志** | 主脚本的实时日志（末尾 16 条） |

控制台本身不下载，它是**控制面板**：在pc端点击「开始下载」后会在后台以隐藏窗口启动
#####此时在pc端先点击停止下载，然后在控制台选择“导入任务”，再在控制台点击开始下载。
#####下载结束后关闭操作台，打开pc端点击“开始安装”即可
`AkDownloader.ps1`（传入你选的参数），然后通过看板的 `/data` 接口每秒刷新界面。
关窗时会询问是否停止下载。

#### 外观设置（背景图片）

点操作区的 **「外观设置...」** 打开对话框：

| 项目 | 说明 |
|---|---|
| **选择图片...** | 支持 jpg / png / bmp / gif，自动**等比裁切填满**窗口（不变形） |
| **背景亮度** | `-100 ~ +100`，正数更亮。改变后**实时预览** |
| **蒙版浓度** | `0 ~ 90%`，在图片上叠一层纯色。浓度越高文字越清晰 |
| **蒙版颜色** | `自动`（按字体颜色选：深色字用白蒙版提亮、浅色字用黑蒙版压暗）/ `白色` / `黑色` |
| **字体颜色** | `自动适配背景亮度` / `强制深色字` / `强制浅色字` |
| **确定 / 取消** | 取消会完整回滚到打开对话框前的状态 |

**自动适配原理**：把图片缩放绘制 → 套用亮度矩阵 → 叠加蒙版 → **采样整张成品图的平均亮度**，
再决定用深色字还是浅色字（阈值 140）。当蒙版颜色为「自动」且目标是深色字时，
如果叠完蒙版亮度还不到 150，会**自动把蒙版浓度提到刚好够**（上限 85%），保证文字一定看得清。

设置保存在脚本同目录的 **`background.json`**：

```json
{
  "image": "C:\\path\\to\\your.jpg",
  "brightness": 15,
  "overlay": 45,
  "overlayColor": "auto",
  "textColor": "auto"
}
```

`image` 留空 `""` 就回到默认的浅灰主题。也附带了一张 `sample-bg.png` 示例图。

> 实现细节：窗体开了双缓冲减少闪烁；`Label / GroupBox / RadioButton / CheckBox` 用
> `BackColor = Transparent` 让背景图透出来；`TextBox / ComboBox / ListView / NumericUpDown`
> 这类原生控件不支持真透明，所以给它们配了同主题的实色底以保证可读性。
> 拖动窗口改变大小时会重绘背景，但尺寸变化小于 24px 时跳过，避免拖拽卡顿。

#### 界面缩放与字号

高 DPI 屏幕上最容易踩的坑是**字号被重复放大**：

* GDI+ 的 `Font` 单位是**磅**，本身就会按屏幕 DPI 换算像素
  （实测 216 DPI / 225% 下，9pt 已经是 35px 高）。
* 所以布局的像素坐标要乘 `DPI/96`，**字号不能再乘**，否则就是 `2.25 × 2.25`
  的四倍放大，字会大得离谱、还会把控件撑爆。

| 配置项 | 位置 | 作用 | 默认 |
|---|---|---|---|
| `ui.guiScale` | `config.json` | 缩放整套界面（坐标 + 控件尺寸） | `1.0` |
| `ui.fontScale` | `config.json` | **只**缩放字号，布局不变 | `1.0`（= 9pt） |

也可以临时覆盖，不用改配置文件：

```
AkDownloaderGUI.ps1 -Scale 1.15      # 界面整体放大 15%
AkDownloaderGUI.ps1 -FontScale 0.85  # 字号 9pt -> 7.65pt
AkDownloaderGUI.ps1 -SelfTest        # 只打印 DPI/缩放/字号, 不开窗口
```

`-SelfTest` 会输出类似下面这行，排查缩放问题很方便：

```
SELFTEST OK  dpi=216 (per-monitor-v2)  scale=2.25  fontScale=1.00  font=9.0pt  window=2115x1575  screen=3072x1920
```

> GUI 脚本用「带 BOM 的 UTF-8」保存，这样 PowerShell 5.1 才会正确识别其中的中文
> （PS 5.1 读取无 BOM 的 .ps1 会按系统 ANSI 解码，中文会破坏语法）。

### 方式二：命令行

```
双击 start.cmd
```

默认就是 **SDK 模式**：自动扫描启动器的下载任务，提取全部分包地址，然后多线程加速下载，
下完弹窗提醒你启动启动器继续安装。

### 命令行用法

```powershell
.\AkDownloader.ps1                              # 自动模式
.\AkDownloader.ps1 -Plan                        # 只看计划，不下载
.\AkDownloader.ps1 -Workers 64                  # 改并发数
.\AkDownloader.ps1 -Force                       # 不等待启动器关闭
.\AkDownloader.ps1 -TaskConfig "C:\...\download_sdk_config"   # 指定任务（GUI 用它）
.\AkDownloader.ps1 -Url "https://a.com/b.bin" -OutDir D:\dl    # 手动地址
.\AkDownloader.ps1 -UrlFile urls.txt            # 手动地址列表（每行一个）
.\AkDownloader.ps1 -NoBrowser -NoNotify         # 不自动开浏览器 / 不弹窗提醒
.\AkDownloader.ps1 -AutoLaunch                  # 下完自动拉起启动器
```

### 手动地址模式

`-Url` / `-UrlFile` 会切到通用下载模式：

* 自动用 `curl -r 0-0 -D -` 探测文件大小和是否支持 Range
* 支持 Range → 走多线程分块下载
* 不支持 Range（或拿不到大小）→ 自动退回单流下载，仍然支持 `-C -` 断点续传
* 目标文件名从 URL 末段推导，保存到 `-OutDir`

---

## 界面

启动后自动打开 `http://localhost:8777/`（端口可在 config.json 改）：

| 区域 | 内容 |
|---|---|
| 顶部指标 | 总进度 / 已下载 / 实时速度 / 预计剩余 |
| 总进度条 | 全部文件整体完成度 |
| 文件进度 | 每个文件的进度条（绿=完成） |
| 在途分块 | 每个格子 = 一条连接正在下的 4 MB 分块，填充百分比实时刷新 |
| 日志 | 最近 16 条日志；完整日志在 `%TEMP%\AkDownloader\logs\` |

下载完成后页面顶部会出现绿色横幅，提示下一步启动启动器。

---

## 这个工具修掉的 9 个坑

| # | 问题 | 表现 | 修复 |
|---|---|---|---|
| 1 | **连接假死** | CDN 让连接停住不发数据，只设 `--connect-timeout` 没用（它只管建连阶段），worker 被永久占死 | 加传输阶段看门狗 `--speed-limit 4096 --speed-time 25` + `--max-time 300` |
| 2 | **并发塌陷** | 每个文件单独开一个 worker 池，某文件下到最后只剩几块时并发塌到个位数；而 CDN 是**按连接限速**的，总速度随之崩塌（实测 32→2 连接时速度从 2 MB/s 掉到 0.25 MB/s） | 所有文件的全部小分块进**同一个全局队列**，worker 下完一块立刻领下一块 |
| 3 | **数据串号** | 不同文件的字节区间会重叠，分块临时文件若不带 tag，A 文件的数据会被当成 B 文件的用 → 安装包静默损坏 | 分块名带目标 tag：`{tag}_{start}_{end}.bin`，并删除不匹配当前任务的分块 |
| 4 | **大小读不到** | Windows 下 `Get-Item` 读一个正被写入的文件，返回的是目录项里的**陈旧大小（通常 0）**，导致界面看着"不动" | 用共享读句柄打开后读 `.Length` |
| 5 | **变量名冲突** | PowerShell 变量名**大小写不敏感**，`$target` 会覆盖 `$TARGET`，导致路径被拼成嵌套路径 | 常量改名 `$OUTDIR`，配置项实例另用 `$dst` |
| 6 | **任务整体"识别不到"** | 日志里 `download_sdk_config` 明明找到了、也报 `1 task entry(ies)`，紧接着却 `parse failed ... 无法使用指定的命名参数解析参数集`，最后报 `no download_sdk_config found` | 见下方说明 |
| 7 | **点"开始下载"没反应** | GUI 里点下去看着启动了，实际却去下一个不存在的地址（日志里是 `url[0] file0`、`curl: (3) URL rejected: Bad hostname`），秒失败后看板还占着端口 30 分钟 | `Start-Process -ArgumentList` 的元素逐个加引号 |
| 8 | **看板打得开，但是空白占位页** | 浏览器能连上 `http://localhost:8777/`，却只显示 `AkDownloader.html not found`（响应体正好 202 字节） | 见下方说明 |
| 9 | **看板秒级不更新 / 图形控制台很卡** | `/data` 要好几秒才回，浏览器页面一直转圈，GUI 窗口拖不动、按钮像没反应 | 见下方说明 |

> 第 6 个坑：**PowerShell 5.1 的 `Split-Path -LiteralPath` 参数集里只有 `LiteralPath` / `Resolve`，不能配 `-Parent`**
> （`Get-Command Split-Path` 的 `LiteralPathSet` 可查证；PowerShell 7 才放宽）。
> 而这段代码被 `try/catch` 包着只记一条 WARN，异常被吞掉、任务对象为 `$null`，
> 界面上就表现为「扫描不到任何下载任务 / 未能识别下载文件」。
> 改用 `[System.IO.Path]::GetDirectoryName($path)` 按字面量取父目录即可，
> 顺带也不怕路径里出现 `[` `]` 这类通配符字符。

> 第 7 个坑：**PowerShell 5.1 的 `Start-Process -ArgumentList` 拿到数组时只是用空格拼起来，
> 不会给含空格的元素加引号。** 于是
> `-TaskConfig "C:\Program Files\GRYPHLINK\games\Arknights Endfield\...\download_sdk_config"`
> 被空格切碎，碎片还按**位置**绑到了 `$Url` / `$UrlFile` 上（实测 `-TaskConfig` 只剩 `C:\Program`），
> `$Url` 一非空主脚本就切进 URL 模式，去下一个叫 `Files\GRYPHLINK\games\Arknights` 的"地址"。
> 修法：每个参数先过 `Quote-Arg` 单独加引号再拼成一行传给 `-ArgumentList`；
> 同时点"开始"发现端口被占时，会认出那是本工具残留的进程并询问是否结束它，
> 不再只能干看着（旧版本会一直占着端口到 `keepAliveMinutes` 到期）。

> 第 8 个坑：又是**变量名大小写不敏感**（和第 5 条同源）。SDK 分支里的
> `$root = Resolve-Tpl $Cfg.launcherRoot` 实际写的是 `$script:Root` —— 把"脚本所在目录"
> 静默改成了 "`C:\Program Files\GRYPHLINK`"。而 `$script:HtmlPath` 是
> `Join-Path $script:Root 'AkDownloader.html'`，于是页面路径变成
> `C:\Program Files\GRYPHLINK\AkDownloader.html` → 找不到 → `Get-Html` 只能返回那个
> 202 字节的占位页。**看板进程是活的、端口也能连，但页面永远是 blank。**
> 修法：局部变量改名 `$launcherDir`，并把解析出来的页面路径写进日志，一行就能看出问题：
>
> ```
> dashboard : http://localhost:8777/
> page      : C:\Program Files\GRYPHLINK\AkDownloader.html  (MISSING - placeholder page will be served)
> ```

> 第 9 个坑：看板是**主脚本自己单线程服务**的（`Serve-Pending` + 自写 HTTP），所以任何
> 主线程变慢都会直接变成"看板拉不起来 + GUI 很卡"。三处叠加：
>
> 1. `/data` 对分块目录里的**每个**分块 `File.Open` 一次。本工具一次要下 13500+ 个 4MB 分块，
>    而全局队列的设计让 54 个文件并行推进，于是分块会堆到上万个。实测：
>
>    | 扫描方式 | 3000 个 | 推算 13500 个 |
>    |---|---|---|
>    | `Get-LiveSize`（逐个开文件） | 484 ms | **≈ 2.3 秒** |
>    | `FileInfo.Length`（只读目录项） | 13 ms | ≈ 60 ms |
>
>    改成读目录项，只对"正在写"的那几十个分块用共享句柄读实时大小（保留坑 #4 的修复）。
> 2. 规划阶段是 `目标数 × 分块数` 的两重循环，而且残留分块用一个一个 `Remove-Item` 删。
>    实测 54 × 3507 = 18.9 万次迭代就要 4.3 秒；54 × 13500 约 16 秒，再加土万个 `Remove-Item`
>    又是几十秒。**而看板是在规划之后才启动的**，那整段时间点"打开看板"就是连不上。
>    改成按 tag 建索引（一遍扫完）+ `[System.IO.File]::Delete` 批量删。
> 3. GUI 每 tick 用 `HttpWebRequest.GetResponse()` **同步**拉 `/data`，超时 2 秒，
>    也就是 UI 线程每隔一秒就干等一次 HTTP，窗口自然拖不动。改成 `BeginGetResponse`
>    异步拉，UI 线程永不阻塞；顺便把 ListView 改成数据真变了才重建。
>
> 另外把"等 1 秒 + 服务一次看板"改成每 ~120ms 服务一次（响应延迟从最多 1 秒降到 ~100ms），
> 拼接大文件时也穿插服务看板。
>
> 外观重绘也顺带优化了（拖窗口/拉亮度滑块时原来每个事件都重绘一遍）：
> 源图缓存（省下每次 ~20 ms 的解码）+ 重绘去抖 + 拖动期间不重绘（松手一次画完）
> + `Invalidate` 代替同步 `Refresh`。实测各环节（2115×1575）：
> 双三次缩放绘制 71 ms、解码原图 20 ms、亮度采样 8 ms —— 所以亮度采样没动它
> （曾经改成"缩到 96×96 再采样"，实测 42 ms，反而是负优化，已经回退）。

---

## 配置文件 `config.json`

| 键 | 默认 | 说明 |
|---|---|---|
| `launcherRoot` | `C:\Program Files\GRYPHLINK` | 扫描 `download_sdk_config` 的起点 |
| `launcherExe` | `...\Launcher.exe` | 完成后提示/自动拉起的启动器 |
| `outDir` | 空 | 留空：SDK 模式用启动器任务目录；URL 模式用脚本同级 `downloads\` |
| `workDir` | `%TEMP%\AkDownloader\chunks` | 分块临时目录（断点续传凭据，别删） |
| `logDir` | `%TEMP%\AkDownloader\logs` | 日志目录 |
| `workers` | `48` | 并发连接数。实测 8/16/32/48 ≈ 0.3/0.9/1.2/3.0 MB/s |
| `chunkMB` | `4` | 分块大小。越小尾部越平滑，越大 HTTP 开销越低 |
| `port` | `8777` | 看板端口，`0` 关闭看板 |
| `openBrowser` | `true` | 启动后自动开浏览器 |
| `speedLimitBps` / `speedTimeSec` | `4096` / `25` | **假死看门狗，别删** |
| `maxTimeSec` | `300` | 单分块硬上限 |
| `connectTimeoutSec` | `20` | 建连超时 |
| `maxRetries` | `8` | 单分块最大重试次数 |
| `notifyOnFinish` | `true` | 完成后弹窗 + 提示音 |
| `autoLaunchLauncher` | `false` | 完成后自动启动启动器 |
| `keepAliveMinutes` | `30` | 下载完成后看板继续存活分钟数 |
| `defaultUrls` | `[]` | 自动提取失败时的兜底地址 |
| `ui.*` | — | 界面文案（UTF-8 中文都放这里，脚本本身是纯 ASCII，避免 PowerShell 5.1 按 ANSI 读取导致语法崩坏） |

---

## 工作流程

```
                 ┌─ SDK 模式 ────────────────────────────────────────┐
                 │ 递归扫描 launcherRoot                            │
显式 -Url ? ─否─→│ 找 download_sdk_config，解析 file_list           │
        │        │ 自动得到 url / size / download_path / 目标目录     │
        └─是─┐   └──────────────────────────────────────────────────┘
             │
             ↓  -Url / -UrlFile → 探测 Content-Length + Range 支持
        ┌──────────────────────────────────────┐
        │ 规划：复用已下满的分块，其余切成 4MB  │
        │      全部塞进一个全局队列            │
        └──────────────────────────────────────┘
                        ↓
        ┌──────────────────────────────────────┐
        │ 48 个 worker 循环领活 → curl 分块下载 │
        │ 每块校验字节长度，失败立即回队重试     │
        │ 某文件分块凑齐 → 立即按序拼接 + 校验   │
        └──────────────────────────────────────┘
                        ↓
        逐文件校验最终大小 → 弹窗提醒 → 提示启动启动器
```

**断点续传**：中断后重跑，已下满的分块会被复用（校验区间 + 字节长度），半成品直接丢弃重下。
拼接是幂等的：只有文件大小精确匹配才会被标记完成。

---

## 常见问题

**Q: 提示 `launcher/game running` 然后等回车？**
A: 启动器在跑，它的 SDK 和本工具会抢同一批文件。先关掉启动器，或加 `-Force` 跳过。

**Q: 看板里的分块格子不动？**
A: 已修复（见"坑 4"）。如果你自己改过代码读文件大小，记得用共享读句柄。

**Q: 下完了但启动器还是从头下载？**
A: 把 `download_sdk_config` 里的 18 个 `url` 改成 `http://127.0.0.1:端口/文件名`，
   起一个静态 HTTP 服务指向目标目录，让启动器从 localhost "下载"，几秒走完。

**Q: 怎么换更快/更稳的源？**
A: 没有更快的官方源。该 CDN 实测 11 个边缘节点全部只有 11~72 KB/s 单连接，
   靠的是多连接并行。若你有可用代理，用 TUN/透明代理模式（SDK 本身不支持代理设置）。

**Q: 日志和临时文件在哪？**
A: `%TEMP%\AkDownloader\logs\` 与 `%TEMP%\AkDownloader\chunks\`。

---

## 环境要求

* Windows 10 / 11
* PowerShell 5.1（系统自带）
* `curl.exe`（Windows 10 1803+ 自带，路径 `<windir>\System32\curl.exe`）
* 无需管理员权限（但**不要把本工具放进 `C:\Program Files`**，那里新建目录需要提权）
