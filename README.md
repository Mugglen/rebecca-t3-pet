# 瑞贝卡 · T3 桌宠

**让瑞贝卡陪你写代码，也替你留意 T3 Code 的运行状态。**

Rebecca T3 Pet 是一个 Windows 桌面伴侣：Q 版瑞贝卡坐在透明悬浮窗口里，任务运行时敲键盘，需要回应、任务完成或连接异常时，通过角色姿势和简短提示告诉你发生了什么。

<p align="center">
  <img src="assets/rebecca-working-typing.gif" width="300" alt="瑞贝卡坐着交替敲击小终端的循环工作动画">
  <br>
  <em>实际使用的工作动画 · 透明 GIF · 6 帧 / 0.84 秒循环</em>
</p>

A chibi Rebecca desktop companion for monitoring local T3 Code activity on Windows.

[快速开始](#快速开始) · [配置与排障](docs/RUNBOOK.md) · [验证记录](docs/VALIDATION.md) · [开发计划](docs/TICKETS.md)

## 能做什么

- **看见工作状态**：显示正在运行的任务数、待处理请求和连接状态；异步提问与任务运行可以同时显示。
- **工作时敲键盘**：工作状态循环播放 GIF；待机使用坐姿，其余状态保留现有图集。新增 A–F 候选只作为素材保留，没有启用。
- **陪在桌面上**：透明无边框窗口，可拖动、缩放、置顶、回到主屏；右键菜单支持暂停动作和退出。
- **连接异常可见**：显示断连、过期或版本不兼容；采集器意外退出时自动重试，收到新快照后恢复状态。
- **本机只读监控**：采集器只读 T3 的必要元数据，不读取聊天或命令正文，不修改 T3 的任务、数据库或审批结果。

这是可运行的 Windows v0.1 项目。状态采集与桌面窗口均已有实现；多屏/DPI、长期运行及其他机器部署仍在完善。

## 快速开始

### 1. 准备环境

| 项目 | 要求 |
| --- | --- |
| 系统 | Windows，支持 Windows PowerShell 5.1 / WPF |
| Python | Python 3.12+，采集器仅使用标准库，无需 `pip install` |
| T3 Code | 真实监控目前适配本机 **0.1.11**；演示模式不需要 T3 |
| 项目位置 | **D 盘**。当前启动器会检查盘符，运行数据、日志和临时文件都保存在项目内 |

桌宠无需模型、API key 或额外 GUI 框架。Python 和 T3 Code 需要自行准备；当前还没有独立安装包。

### 2. 下载并配置

在 PowerShell 中执行；目标目录应当尚不存在：

```powershell
git clone --branch feat/seated-working-pose https://github.com/Mugglen/rebecca-t3-pet.git D:\Projects\rebecca-t3-pet
Set-Location D:\Projects\rebecca-t3-pet
Copy-Item config.example.json config.local.json
notepad config.local.json
```

上面检出包含坐姿与工作 GIF 的当前分支，见 [PR #13](https://github.com/Mugglen/rebecca-t3-pet/pull/13)。

将配置中的两个路径改为你机器上的实际位置；下面是示例，路径不会随仓库下载自动创建：

```json
{
  "python_path": "D:\\Projects\\.venv\\Scripts\\python.exe",
  "t3_home": "D:\\Projects\\tools\\T3CodeData\\Home",
  "poll_seconds": 2,
  "project_ids": [],
  "scale": 1.0,
  "topmost": true
}
```

`python_path` 指向真实的 Python 可执行文件；`t3_home` 指向包含 `userdata` 的 T3 数据目录。`project_ids` 留空表示监控当前适配器范围内的本机项目，填写项目 ID 可限制监控范围。`config.local.json` 不会提交到 Git。

### 3. 启动桌宠

- **真实监控**：先启动 T3 Code，再双击 [Start-Rebecca.cmd](Start-Rebecca.cmd)。
- **先看效果**：双击 [Demo-Rebecca.cmd](Demo-Rebecca.cmd)。仍需有效的 Python 路径，但不连接 T3，界面会明确标注演示。
- **操作与退出**：拖动角色移动位置，右键打开菜单；选择“退出”或按 Esc 关闭，并清理该实例启动的采集进程。

暂停动作时显示静态工作坐姿；GIF 缺失或损坏也会回退到静态图。更换素材后需重启桌宠。更多配置、日志位置和故障处理见 [运行说明](docs/RUNBOOK.md)。

## 如何工作

```text
本机 T3 Code
  ├─ 服务身份与版本核对
  └─ SQLite 元数据（只读）
          ↓
Python 采集器与状态归约
          ↓ 原子写入 JSON 快照
PowerShell 5.1 / WPF 桌宠
          ↓
角色姿势、工作 GIF、状态与请求计数
```

数据源采用显式适配的 T3 私有 schema，**不是稳定的公共状态 API**。升级 T3 后如果版本或结构不匹配，桌宠会显示不兼容；不能通过取消校验来假装正常连接。

本地配置、运行快照、日志、数据库与临时文件均由 `.gitignore` 排除。角色提示只反映采集器已支持的状态，不代替在 T3 中查看和处理请求。

## 当前边界

- 目前只验证本机 T3 0.1.11；远程环境不默认接入。
- secret/link 卡片及部分特殊等待语义尚未完整覆盖，见 [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11)。
- 多屏/DPI、透明区域点击命中和长期资源占用仍需人工验收。
- 工作状态已有逐帧动画；其他状态仍是静态姿势与整体动效。A–F 候选没有接入运行状态。
- 另一台机器上的便携部署尚未完成验证，当前通过源码启动。

已执行的检查与尚未验证的项目分别记录在 [VALIDATION.md](docs/VALIDATION.md)，模拟测试与实机证据分开列出。

## 开发与素材

| 入口 | 内容 |
| --- | --- |
| [完整规格](docs/SPEC.md) / [产品设计](docs/PRODUCT.md) | 功能范围、交互和验收目标 |
| [架构决策](docs/ARCHITECTURE.md) / [状态验证](docs/STATUS-SPIKE.md) | 采集、状态归约与桌面显示的设计依据 |
| [开发 tickets](docs/TICKETS.md) | 工作项和后续计划 |
| [运行与测试](docs/RUNBOOK.md#开发验证) / [审查记录](docs/REVIEW.md) | 本地验证命令、已发现问题与修复记录 |
| [资产生成记录](assets/GENERATION.md) | 当前 PNG/GIF 的完整提示词、来源、哈希与重建方式 |
| [候选素材](assets/candidates/GENERATION.md) | 六张尚未启用的透明候选 PNG；图库 HTML 下载到本机后打开 |
| [参考来源](references/INDEX.md) / [美术规格](docs/ART-DIRECTION.md) | 角色参考与视觉方向；下载的参考原图不随仓库发布 |

实现采用 Python 标准库和 Windows PowerShell/WPF；CI 覆盖状态归约、适配器、桌面与 GIF 播放，以及采集进程的生命周期。开发约定见 [AGENTS.md](AGENTS.md)。

## 项目说明

这是受《赛博朋克：边缘行者》瑞贝卡启发的非官方同人项目，与原作及 T3 Code 官方无隶属关系。运行用角色素材由内置 imagegen 生成，生成过程保存在仓库中；角色及原作相关权利归各自权利人。
