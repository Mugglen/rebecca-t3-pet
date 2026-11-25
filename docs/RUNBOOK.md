# 启动、配置与故障处理

本文对应 Windows 首版实现；最终测试结果见 [VALIDATION.md](VALIDATION.md)。规格和未来功能见 [SPEC.md](SPEC.md)。

## 依赖与首次配置

使用 Windows PowerShell 5.1（STA/WPF）和 Python 3.12+。应用采集器只依赖 Python 标准库，参考图库重建用的 Pillow/PyMuPDF 不属于桌宠运行依赖。

将 `config.example.json` 复制为 `config.local.json` 并按机器填写：

- `python_path`：Python 可执行文件；本机已验证入口是 `D:\Projects\.venv\Scripts\python.exe`。
- `t3_home`：T3 数据根目录，包含 `userdata`；本机为 `D:\Projects\tools\T3CodeData\Home`。
- `poll_seconds`：采集周期，默认 2 秒。
- `project_ids`：空列表表示当前本机适配器范围内的全部项目；非空时按 T3 项目 ID 过滤。
- `scale`、`topmost`：角色缩放与是否置顶。

项目保存在 D 盘。配置、本机状态、日志和临时文件默认忽略，不推到 GitHub。不要复制 T3 凭证或当前代理的令牌。

## 启动与退出

双击根目录 `Start-Rebecca.cmd` 启动真实监控；`Demo-Rebecca.cmd` 用于演示状态，界面始终标识演示。演示不连接 T3，不能证明真实状态接入已通过。

拖动角色调整位置，右键打开菜单；菜单支持退出，窗口响应 Esc。退出应停止该桌宠实例启动的采集器。无需关闭 T3，也不注册开机自启。

“始终置顶”保存的是你的选择。开启后，窗口定时检查会独立于任务状态校验实际置顶标志：只有标志丢失时才恢复，不改变前台焦点、位置或大小。待机、暂停动作及采集器重连期间也会检查；手动取消置顶后不会自动重新开启。隐藏或最小化的窗口不会被强行显示，已有置顶窗口之间也不会每次轮询重新排序。

工作状态默认播放 `assets/rebecca-working-typing.gif`。右键“暂停动作”可停止 GIF 并显示静态工作坐姿；离开工作状态也会停止播放。GIF 缺失、损坏或使用非完整画布增量帧时回退静态图，不影响状态监控。更换资产后需重启桌宠。

采集器写状态文件时若遇到短暂占用，会保留旧文件并退避重试；超过新鲜度阈值时，界面明确显示过期。采集进程异常退出后，窗口显示重新连接，并按 2、4、8、16、30 秒重启，连续运行满 30 秒后重置退避。重启后必须收到本次启动产生的新快照才会恢复状态显示。

## 只验证采集

在项目目录执行：

```powershell
$env:PYTHONPATH = Join-Path $pwd 'src'
$env:TEMP = Join-Path $pwd 'tmp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
& 'D:\Projects\.venv\Scripts\python.exe' -B -m rebecca_pet.collector `
  --t3-home 'D:\Projects\tools\T3CodeData\Home' `
  --output 'D:\Projects\rebecca-t3-pet\data\status.json' --once
```

检查输出的 `mode`、`source.health`、`source.version`、`observed_at`、`state` 与 `counts`。不要用状态文件“存在”替代新鲜度和健康检查。

## 故障定位

| 表现 | 检查 |
| --- | --- |
| 启动时报 Python 不存在 | 在本机配置中填写实际 Python 路径；不要使用 Windows Store 占位命令 |
| T3 离线 | 确认 T3 正在运行、t3_home 正确、运行定位文件和 environment-id 存在 |
| 版本不兼容 | 当前适配仅对 0.1.11 核对；升级后重新验证 schema/fixture，不能直接取消版本校验 |
| 显示正在重新连接 | 等待自动重试；记录提示的退出码并查看下述日志，无需重启 T3 |
| 长时间不刷新 | 检查状态观察时间、输出目录可写性与日志；旧 working 文件不算在线证据 |
| 有待处理但仍工作 | 可能是异步提问；请求角标与执行状态本来就可并存 |
| 部分请求没有提醒 | secret/link 和特殊 shell 派生状态由 [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11) 跟进 |
| 角色不可见或位置不合适 | 使用回到主屏功能；位置和 DPI 的人工验收状态见验证报告 |
| 开启置顶后被普通窗口挡住 | 窗口会自动恢复丢失的置顶标志；若仍复现，记录遮挡程序以及是否经过显示桌面、全屏或锁屏。其他同样置顶的窗口可能位于她上方 |

不需要修改或修复 T3 数据库。排障时保留最小状态字段，不导出聊天、命令、秘密或整个数据库。

真实模式日志在 `data/status-live.log`（采集事件、异常类型和错误码；64 KiB，最多一份 `.log.1` 备份）与 `data/collector-live.lifecycle.log`（启动、退出和退出码；上限 64 KiB）。演示模式文件名中的 `live` 改为 `demo`。日志不包含原始异常正文、聊天或命令；日志无法写入也不会终止采集。

## 开发验证

```powershell
$env:PYTHONPATH = Join-Path $pwd 'src'
& 'D:\Projects\.venv\Scripts\python.exe' -B -m unittest discover -s tests -v
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts/Test-Desktop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Test-CollectorLifecycle.ps1
```

Windows smoke 使用合成快照验证协议、资源加载和窗口渲染；真实任务验证另外执行。CI 定义在 `.github/workflows/verify.yml`，不会访问作者机器的 T3 数据。

桌面 smoke 同时调用 `Test-Animation.ps1` 验证 GIF 换帧、暂停、状态切换与清理。需要重新封装已生成的动画 sheet 时执行 `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts/Build-TypingGif.ps1 -Force`；此命令仅替换本项目 GIF，默认不覆盖已有文件时可省略 `-Force` 并指定新的 `-OutputPath`。

桌面 smoke 还调用 `Test-Topmost.ps1`，对独立测试窗口人为撤销 native 置顶标志，验证相同待机状态下的恢复、用户关闭置顶的保存/恢复、前台焦点与 GIF 不变、健康窗口不重复重排，以及隐藏/最小化/关闭时不强制显示。这是故障注入验证，不代替长时间待机后的现场复现。
