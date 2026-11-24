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
| 长时间不刷新 | 查看状态观察时间与采集进程错误；旧 working 文件不算在线证据 |
| 有待处理但仍工作 | 可能是异步提问；请求角标与执行状态本来就可并存 |
| 部分请求没有提醒 | secret/link 和特殊 shell 派生状态由 [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11) 跟进 |
| 角色不可见或位置不合适 | 使用回到主屏功能；位置和 DPI 的人工验收状态见验证报告 |

不需要修改或修复 T3 数据库。排障时保留最小状态字段，不导出聊天、命令、秘密或整个数据库。

## 开发验证

```powershell
$env:PYTHONPATH = Join-Path $pwd 'src'
& 'D:\Projects\.venv\Scripts\python.exe' -B -m unittest discover -s tests -v
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File scripts/Test-Desktop.ps1
```

Windows smoke 使用合成快照验证协议、资源加载和窗口渲染；真实任务验证另外执行。CI 定义在 `.github/workflows/verify.yml`，不会访问作者机器的 T3 数据。
