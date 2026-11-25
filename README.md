# 瑞贝卡 · T3 桌宠

一个以《赛博朋克：边缘行者》瑞贝卡为角色的 **Q 版动漫风 T3 Code 状态桌宠**。

让用户不用一直盯着 T3 Code 窗口，也能从角色的动作和简短提示了解：任务正在运行、需要回应、刚刚完成，或者出现异常。

## 当前进度

当前分支已实现 Windows v0.1：真实 T3 状态采集、六个 Q 版姿势、透明悬浮窗口、状态提示、拖动与右键菜单。已验证真实状态读取及启动/自动退出；完整证据和未测项见 [验证记录](docs/VALIDATION.md)。

[Mugglen 私有仓库](https://github.com/Mugglen/rebecca-t3-pet) · [11 个开发 tickets](docs/TICKETS.md)

## 启动

在本机双击 [Start-Rebecca.cmd](Start-Rebecca.cmd) 运行真实监控，或 [Demo-Rebecca.cmd](Demo-Rebecca.cmd) 演示状态。T3 项目也配置了“启动瑞贝卡”“演示角色状态”“桌面验证”入口。

需要 Windows PowerShell 5.1 和 Python 3.12+，项目须位于 D 盘。当前环境的 Python/T3 路径可自动发现；其他机器按 [运行说明](docs/RUNBOOK.md) 使用 `config.local.json` 配置。采集器仅使用标准库，不需要模型、API key 或 GUI 依赖安装。

右键菜单可暂停动作、调整缩放/置顶、回到主屏和退出。退出会清理本实例的采集进程。角色采用六张静态姿势切换加整体动效，逐帧动作仍在后续美术 ticket。

状态文件被短暂占用时会自动重试；采集器意外退出后会自动重新连接，并等待新快照。故障提示与精简日志位置见 [故障处理](docs/RUNBOOK.md#故障定位)。

## 状态接入边界

只读采集本机 T3 **0.1.11** 的 SQLite 元数据，并通过公开环境描述端点核对服务身份；这是显式版本适配的私有 schema，不是稳定公共状态 API。升级 T3 后若版本/结构不同会显示不兼容。

不读取聊天、命令正文或凭证。运行与待回复分开显示；secret/link 卡片及部分特殊等待尚未完整覆盖，需回 T3 检查，见 [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11)。多屏/DPI、点击命中和长时间性能仍待人工验收。

## 已确认的需求

- 角色：瑞贝卡。
- 画风：Q 版动漫风。
- 用途：监控 T3 Code 运行状态；用户以 Codex 桌宠作为体验参考。
- 工程目录：`D:\Projects\rebecca-t3-pet`；素材、临时文件、缓存、日志和构建产物均放在 D 盘。

## 继续开发从这里开始

1. [完整规格](docs/SPEC.md) 与 [架构决策](docs/ARCHITECTURE.md)：范围、协议、交互和验收。
2. [开发 tickets](docs/TICKETS.md)：GitHub 工作项及依赖。
3. [官方参考库](references/INDEX.md) 与 [美术规格](docs/ART-DIRECTION.md)：原作形象、Q 版比例与动作。
4. [状态技术验证](docs/STATUS-SPIKE.md)：实际独立查询、SQL 与健康入口；[早期调研](docs/STATUS-INTEGRATION.md) 为历史记录。
5. [项目工作规则](AGENTS.md)：后续开发和验证约定。

参考库已收集 38 张视觉参考和一份 9 页官方指南；原图留在本机，仓库保存来源清单。运行时仅使用 `assets/` 下本项目生成的角色图集。

## 开发路线

- [x] 创建独立项目，并注册到 T3 Code。
- [x] 记录用户确认的需求与第一版设计建议。
- [x] 完成独立进程可用的只读状态接入与状态转换实现。
- [x] 制作 Q 版瑞贝卡六姿势图集与整体动效。
- [x] 实现透明悬浮窗口、拖动、状态提示和退出入口。
- [x] 验证真实 T3 读取和窗口生命周期，提供启动器。
- [ ] 补齐特殊请求语义、完整动作与多屏/DPI/长期运行验收。
- [ ] 完成另一台机器可复现的便携发布包。

实现采用 Python 标准库采集器 → 原子 JSON → Windows PowerShell 5.1/WPF。测试命令、配置与故障处理见 [RUNBOOK.md](docs/RUNBOOK.md)。
