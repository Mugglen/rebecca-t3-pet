# 架构决策与接口

## ADR-001：Windows 轻量桌面原型

采用 Python 3.12+ 标准库采集/归约状态，PowerShell 5.1 + WPF 显示透明桌宠。理由：当前机器已具备这些运行基础，无需下载 Electron 或 Qt；采集可单独测试，UI 不直接访问 T3。所有生成内容、缓存和运行文件位于 D 盘。

模块边界：

- `src/rebecca_pet/adapter.py`：只读元数据快照、服务身份/可达性和 schema 校验。
- `src/rebecca_pet/state.py`：纯状态聚合、事件去重与重连基线。
- `src/rebecca_pet/collector.py`：CLI 参数、轮询调度、原子 JSON 写入、有限错误处理。
- `app/Pet.ps1`：WPF 角色、状态标签、交互和关闭清理。
- `Start-Rebecca.cmd` 与 `scripts/Start-Rebecca.ps1`：配置发现、D 盘临时目录、启动/失败反馈。
- `tests/`：合成 SQLite、状态转换和协议边界；不保存真实 T3 会话内容。

以上是预定接口和布局；文件尚未出现时不要当作已经实现。

## ADR-002：T3 0.1.11 版本适配的只读 SQLite

已执行 bundled CLI 的列表查询：它返回线程摘要，但不含足够的 pending request 详情；详细查询可能包含消息正文。单次 CLI 查询测得约 381–778 ms（仅少量样本，不能代表 p95）。基于这些限制，v0.1 选用只读 SQLite 元数据适配器，并显式支持当前验证的 `0.1.11`；其他版本默认显示不兼容，待验证后放行。

这属于 T3 私有 schema 兼容层，不包装成官方公共 API。未来存在可用的最小权限状态订阅时，可替换适配器而不改变 UI 协议。

读取约束：URI `mode=ro`、`PRAGMA query_only=ON`、短只读事务、连接超时。只选必要标量字段；不 `SELECT *` 或导出整行 payload。禁止读取消息表、提示词、命令文本、凭证、密钥及请求正文。

必须验证表与字段，异常返回 `incompatible` 或 `offline`，不能输出“0 个任务”掩盖问题。监控过滤必须在一致事务内应用到线程、run 和请求，避免跨范围计数。

## ADR-003：服务健康不能由残留文件或 HTTP 200 推断

每次采集重新读取 `server-runtime.json` 的 host、port、pid、startedAt 和版本，限制为本机 loopback。通过 `/.well-known/t3/environment` 获取无凭证环境描述，比较本地 `environment-id`、运行时版本和返回版本；禁用代理和重定向，限制响应大小与时间。结合 schema 和查询结果；失败即不可用。

本机 `/.well-known/t3/environment` 已返回匹配身份的 JSON，单次样本约 4 ms；`/health`、`/api/info` 返回 SPA HTML，不能据此宣称服务健康。运行时 startedAt 变化需要重新建立事件基线。状态文件观察时间属于采集进程时钟，不等同于 T3 任务更新时间。

## ADR-004：请求语义与执行分离

0.1.11 服务实现的 request summary 以 `responseCapability.type !== "message"` 推导 blocking；SQLite 可仅用 JSON 标量提取该类型，避免读取内容。缺失/未知字段采取保守未知判断。secret/link 等 UI 卡片若使用不同投影，应单独核对和测试；尚未覆盖的来源在报告中明确标注，不假称所有请求均支持。

状态机接受统一线程列表（thread_id、project_id、run_id、status、更新时间、request 元数据）和服务启动标识，产出 [SPEC.md](SPEC.md) 的显示快照。UI 不依赖 SQLite 或 T3 provider 类型。

## ADR-005：单向文件协议与生命周期

采集器通过临时 sibling 文件 + 原子替换更新 `data/status.json`。WPF 只读取规定的 schema，执行长度、类型、版本与时间新鲜度校验。无 IPC 控制任务接口，不支持审批或注入提示。

启动器启动拥有的采集进程，窗口关闭时仅关闭本实例的进程。重复启动由单实例互斥量或锁处理；不能靠枚举全部 Python/PowerShell 杀进程。配置和进程标记含本机信息，默认不入 Git。

## ADR-006：美术来源与资产分离

`references/originals` 为本地研究库；仓库跟踪来源 URL、哈希、尺寸和使用笔记。它不参与 app 加载。应用使用 `assets/` 下明确归属本项目的生成/绘制资产，记录提示与版本，保留透明度。

v0.1 可使用正式立绘加 WPF 呼吸、摇摆与状态标记；逐状态逐帧动作属于后续美术 ticket。实际实现必须写明是哪种动画。

## 演进与回退

适配失败时保留可退出的 UI，并显示来源不可用。可用 demo 模式检验窗口和美术，但不得作为 live 验收。升级适配器时先加 fixture、验证实际版本，再更改支持范围。所有未知场景保留证据边界。
