# 独立状态采集技术验证

核对日期：2026-11-25。仅开展只读查询与源码核对，未实现生产适配器，未修改 T3 配置或业务数据。

## 决策建议

首版采用 **Python 标准库采集器 → 原子 JSON 快照 → PowerShell/WPF 桌宠**。本机 Python 入口为 `D:\Projects\.venv\Scripts\python.exe`；正式启动器应支持配置，不能只依赖这台机器的路径。

建议首个适配器明确标记为 `sqlite-readonly`，限制已验证的 T3 版本 `0.1.11`，验证数据库字段后读取元数据，并以公开环境描述端点确认服务在线。Python 自带 `sqlite3`、`urllib`、`json`、`unittest`，无需新增依赖；相较 Node 内置 SQLite，不需要处理当前 Node SQLite API 的版本差异。UI 不承担采集、查询或超时等待。

CLI 是受支持的对照入口，但当前 CLI 列表仅支持按项目查询，且不暴露请求明细；`thread show` 同时读取最近消息，不符合桌宠仅采集元数据的目标。高频反复为所有项目启动 CLI 也会增加进程与短时 MCP 会话开销。

私有 SQLite 接入必须在产品说明中明确，不能声称使用稳定公共状态 API。后续新增经过授权的只读 API/订阅适配器时，保持 UI JSON 契约不变。

## 已验证的入口

- CLI：`D:\Projects\tools\T3CodeData\Home\bin\t3.cmd`。
- 运行定位：`D:\Projects\tools\T3CodeData\Home\userdata\server-runtime.json`。
- 身份：同目录 `environment-id`。
- 数据库：同目录 `statev2.sqlite`。
- 公共环境描述：`GET <runtime.origin>/.well-known/t3/environment`。

真实环境描述请求成功，HTTP 200 JSON，包含 `environmentId`、`label`、`platform`、`serverVersion`、`orchestrationProtocolVersion`、`databaseMigration`、`capabilities`。实测版本 `0.1.11`，一次请求耗时约 4 ms。采集器应限制连接到 loopback，禁用代理、不跟随到远程地址的重定向，并比较本地环境 ID、运行时版本与返回值。

**不能使用 `/health` 或 `/api/info` 判断 T3 健康。** 两者在本机返回 HTTP 200 的 HTML SPA 页面，源码里同名健康/信息路由分别属于 relay 或内嵌 OpenCode 协议。`/api/projects` 实测无凭证返回 401；不复制正在运行代理的令牌。

## CLI 查询验证

在进程环境将 `T3CODE_HOME` 指向 D 盘已有目录、`TEMP/TMP` 指向本项目 `tmp/spike` 后执行：

```powershell
& 'D:\Projects\tools\T3CodeData\Home\bin\t3.cmd' thread list `
  --project 'D:\Projects\home' --json
```

已两次返回成功，外部计时约 778 ms 与 381 ms；这是两次样本，不是性能基准。结果是线程 summary 数组，关键字段含 `threadId`、`projectId`、`status`、`latestRunId`、`blockedOnThreadWait`、`pendingBackgroundTasks`、`parentThreadId`、`relationshipToParent`、`settled`、`snoozed`、`updatedAt`。

列表无 pending request 明细。命令会正常创建并撤销短时 MCP 会话；测试未发送消息、改线程、审批请求或编辑配置。

## 元数据 SQL 与一致性

以 SQLite URI `mode=ro` 打开，执行 `PRAGMA query_only=ON`，短事务 `BEGIN` 中完成以下读取，结束立即回滚/关闭连接。**不要给实时 WAL 数据库加 `immutable=1`**，也不要只复制主数据库文件后把它当作实时快照。先验证必要表和字段，所有过滤条件参数化。

```sql
SELECT t.thread_id, t.project_id,
       json_extract(t.payload_json, '$.lineage.parentThreadId') AS parent_id,
       json_extract(t.payload_json, '$.lineage.relationshipToParent') AS relationship,
       json_extract(t.payload_json, '$.settledOverride') AS settled_override,
       r.run_id, r.ordinal, r.status, r.requested_at, r.completed_at
FROM orchestration_v2_projection_threads AS t
LEFT JOIN orchestration_v2_projection_runs AS r
  ON r.run_id = (
    SELECT r2.run_id FROM orchestration_v2_projection_runs AS r2
    WHERE r2.thread_id = t.thread_id ORDER BY r2.ordinal DESC LIMIT 1
  )
WHERE t.archived_at IS NULL AND t.deleted_at IS NULL;

SELECT run_id, thread_id, ordinal, status
FROM orchestration_v2_projection_runs
WHERE status IN ('preparing', 'queued', 'starting', 'running', 'waiting');

SELECT runtime_request_id, thread_id, node_id, kind, status, created_at,
       json_extract(payload_json, '$.responseCapability.type') AS response_type
FROM orchestration_v2_projection_runtime_requests
WHERE status = 'pending';
```

这组三项查询在同一只读事务的单次样本约 9.78 ms。仅输出了计数与状态，未读取聊天正文、答案或凭据。投影元数据表 `orchestration_v2_projection_metadata` 提供 `projection_name/schema_version/last_sequence/updated_at`，可用于诊断序列；无新事件时序列不变并不表示失联。

仅使用最后一个 run 会漏掉同线程更早但仍活动的 run。因此同时读取活动 run，用 thread ID 去重统计忙碌线程，保留 latest run ID 用于完成事件。排除已归档/删除线程；子代理可关联回父任务计数，以免重复计算，但其用户请求仍需向上汇总。独立 fork 不等同于子代理。

## 精确的请求语义

已安装 `server.asar` 内 `apps/server/dist/ManagedEndpointRuntime-DBgt8khC.mjs:128230` 的 `pendingRuntimeRequestSummary` 使用：

```javascript
blocking: request.responseCapability.type !== "message"
```

实际数据库观察到 `responseCapability.type` 为 `live` 或 `message`。因此对已知 schema：

- `message`：异步提问，任务可以继续；增加 pending 提示，不把执行状态改成阻塞。
- `live`：同步运行时请求；还要结合 `kind` 区分需要用户输入/审批、内部动态工具或认证更新。
- `auth_refresh`、`dynamic_tool_call` 不应一概算成用户审批。
- 缺失或未知字段不猜测，返回不兼容或未知请求语义。

同文件 `:128239` 的 `secretRequestAsPendingInput` 将等待中的 `secret_request`、`link_request` 卡片投影为 `blocking=true/userOnly=true`，这些不一定出现在 runtime_requests 表。相应元数据来自 `orchestration_v2_projection_turn_items` 的 `turn_item_id/thread_id/run_id/node_id/type/status/updated_at`，**不能读取其 secret 值或正文**。

卡片需要按当前有效 run、已回复和后续用户输入等规则判定是否仍在等待；仅查所有历史 `waiting` 卡会误报。若首版尚未完整实现，应明确保留这项限制和对应 ticket，不能声称所有待处理请求都已覆盖。T3 的 shell 派生逻辑还会处理 silent run、background wake、usage-limit recovery 等情况；SQLite 适配器的覆盖边界应作为独立验证项。

## Reducer 与故障契约建议

- 首次成功快照只建立 run 基线，不回放历史成功/失败。
- 后续按 `(thread_id, run_id, terminal_status)` 产生事件并去重；读取多个线程时事件不互相覆盖。
- `completed` 为成功，`failed` 为错误，`interrupted/cancelled/rolled_back` 为停止；未知枚举显式不兼容。
- 运行计数与 pending 请求计数分离；多个任务可能同时运行、等待输入和失败。
- descriptor 连接失败、身份不匹配、缺失运行时文件为 offline；未知版本或 SQL schema 不符为 incompatible；数据库临时锁定/查询失败明确反馈，不能变成 idle。
- 断连重连重新建立基线，避免把不可观测期间的历史状态全部当成新通知。若要补报，需要明确时间窗口和持久事件游标。
- UI 必须另行检查 `observed_at`，采集进程死掉后旧 `working` JSON 不能永久冒充实时状态。
- 写 JSON 到同一输出目录临时文件，再原子替换目标；Windows 文件共享冲突需有界重试，绝不写半个快照。
- 轮询建议目标 2 秒，失败有界退避；HTTP/SQL/子进程均有超时，不阻塞 UI。

建议沿用 `docs/SPEC.md` 的 `schema_version/observed_at/mode/state/message/source/counts/event` 契约。模拟测试覆盖状态转换与失败分支，真实 T3 查询另行记录，不能相互代替。

## 验证边界

已经验证真实 CLI 列表、公开环境描述、只读 SQLite schema 和正常状态快照。没有触发真实审批、秘密输入、链接卡、任务失败、服务退出或多 DPI 桌面交互；本报告不将这些场景标为已通过。
