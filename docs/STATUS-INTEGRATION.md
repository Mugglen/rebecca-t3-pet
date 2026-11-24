# 状态接入调研

核对时间：2026-11-25（Asia/Shanghai）。此文记录初始化阶段证据，不代表独立桌宠已接通或通过端到端测试。

## 已核实的本机环境

- T3 环境：`HND2288`，Windows x64，服务版本 `0.1.11`；由 `t3_environment_read` 实时返回。
- 主程序：`D:\Programs\T3Code\T3 Code (Beta).exe`。
- CLI：`D:\Projects\tools\T3CodeData\Home\bin\t3.cmd`。
- 数据目录：`D:\Projects\tools\T3CodeData\Home`。
- 服务定位文件：`D:\Projects\tools\T3CodeData\Home\userdata\server-runtime.json`。
- 私有数据库：`D:\Projects\tools\T3CodeData\Home\userdata\statev2.sqlite`。

运行时文件含 `serverVersion`、`host`、`port`、`pid`、`startedAt` 和 `origin`。启动监控时重新发现服务，不硬编码端口。文件存在或数据库中残留 `running` 不能证明服务还在线。

## 优先接入 T3 自带查询能力

本轮已成功调用 T3 MCP 的 `t3_thread_list`，以 `allProjects=true`、`includeSubagents=false` 读取了真实线程状态元数据，并观察到 `running`、`completed`、`idle`。这证明本会话的工具连接可用，尚不能证明桌宠独立进程已具备同样连接。

本机 CLI 的 `thread list --help` 已执行成功。它支持 `--project`、`--json`、`--base-dir`；打包代码确认列表命令调用 `t3_thread_list`。下面是后续独立接入的候选命令，**实际 CLI 列表查询尚未执行**：

```powershell
$env:T3CODE_HOME = 'D:\Projects\tools\T3CodeData\Home'
& 'D:\Projects\tools\T3CodeData\Home\bin\t3.cmd' thread list `
  --project 'D:\Projects\rebecca-t3-pet' --json
```

此命令仅举例查询指定项目；正式产品需要实现明确的监控范围和分页，不应只观察桌宠项目自身。

实现证据位于已安装的 `D:\Programs\T3Code\resources\server.asar` 内：`apps/server/dist/binCli-D6jCraqb.mjs:10635` 定义命令，`:10249` 附近处理短时 MCP 会话的创建与撤销。该文件名和行号随版本变化。

当前 CLI 内部为命令签发短时 full-access 会话，结束后撤销；这是正常 CLI 行为。桌宠只调用读取能力，后续评估是否有更合适的最小权限长期订阅入口。不得把当前代理会话的临时凭证复制到桌宠。

## 状态语义

列表提供的状态枚举：

`idle`、`preparing`、`queued`、`starting`、`running`、`waiting`、`completed`、`interrupted`、`failed`、`cancelled`、`rolled_back`。

另有 `blockedOnThreadWait`、`pendingBackgroundTasks`；线程详情提供 `pendingRequestCount`。

- `waiting` 可能是等待子任务，不应直接译为“等用户”。
- `pendingRequestCount > 0` 只说明有待处理请求，不一定阻塞执行。
- 已安装 schema 的 `pendingRuntimeRequest` 含可选 `blocking` 和 `userOnly`。`blocking=false` 允许异步提问期间继续工作。
- “运行中”与“有待回复”可以并存。只有明确知道请求阻塞且需要用户操作，才显示“等待你处理”的停工动作；字段未知时保守显示“有待处理请求”。
- 按最新 `runId` 及其状态转换识别完成，启动时建立基线，避免回放历史完成记录。
- 失败、中断、取消和回滚分别保留原因，不映射成成功。
- 服务不可达、查询失败、数据过期和未知状态需要明确反馈。不能静默落入空闲。

## SQLite 备用来源

使用只读连接检查过下列表结构、键名和状态聚合，未读取聊天正文，也未修改数据库：

| 表 | 相关字段 |
| --- | --- |
| `orchestration_v2_projection_runs` | `thread_id`、`run_id`、`ordinal`、`status`、`requested_at`、`completed_at` |
| `orchestration_v2_projection_runtime_requests` | `thread_id`、`node_id`、`kind`、`status`、`created_at`、`resolved_at` |
| `orchestration_v2_projection_provider_sessions` | `status`、`updated_at`、`payload_json.lastError` |
| `orchestration_v2_projection_threads` | `project_id`、`archived_at`、`deleted_at` |

检查使用 SQLite URI `mode=ro` 与 `PRAGMA query_only=ON`。实际观察过运行记录 `completed/running/interrupted`，请求类型 `command/user_input` 和请求状态 `resolved`；schema 还定义 `pending/expired/cancelled`。

**这些表属于 T3 私有实现，不是公开 API。** 若必须采用此来源，需要版本探测、明确的字段校验、只读事务和不兼容提示，并配合独立的服务存活检查。不得修改 T3 表结构或依赖聊天内容猜测状态。

## 桌面技术候选

本机 Windows PowerShell `5.1.19041.6456` 可加载 `PresentationFramework`、`PresentationCore` 和 `WindowsBase`；已构造并关闭未显示的 WPF 透明窗口，尚未实测桌面效果。

WPF 的透明无边框窗口使用 `AllowsTransparency=True`、`WindowStyle=None`，见 [Microsoft 文档](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.allowstransparency?view=netframework-4.8.1)。它适合作为免额外安装依赖的首版候选。

需验证 DPI、透明区域命中、拖动阈值、多显示器坐标、退出清理和采集线程隔离。含中文脚本按 Windows PowerShell 5.1 的编码要求保存。依赖、编译临时文件和运行输出必须落在 D 盘。

## 下一步验证

1. 验证独立进程的 CLI/API 查询、分页与超时，决定订阅或低频轮询方式。
2. 设计并测试统一状态模型，保留“任务执行状态”和“待处理请求”两个维度。
3. 在真实运行、异步问题、阻塞请求、完成、失败和断连场景下验证；仅模拟覆盖不能标注实机通过。
4. 完成适配层后再接入角色动画，测量状态延迟和资源占用。

本轮没有触发真实审批、错误或断连场景，没有开发状态适配器或桌宠窗口。
