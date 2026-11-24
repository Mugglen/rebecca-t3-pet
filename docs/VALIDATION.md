# 验证记录

日期：2026-11-25；本机 Windows，T3 0.1.11。此报告区分真实读取、合成测试和人工未验收项；不将规划目标写成测量结果。

## 参考与资产

- 31 张官方网页图，另有 CDPR 官方 9 页指南与逐页渲染；合计 38 张视觉参考和 2 张文档页。
- 40 个图像可解码、40 个唯一 SHA-256，清单与文件匹配；精选图库 9 个本地引用存在且渲染无控制台错误。
- 正式角色图集由内置 imagegen 生成，1536×1024 RGBA、3×2 网格；六个姿势已目视核对。角落与格间透明度采样为 0。完整提示和 SHA-256 见 `assets/GENERATION.md`。
- 本版是六张静态姿势切换加 WPF 整体动效；没有宣称完成逐帧或骨骼动画。

## 自动与真实验证

- **Windows 合成 smoke：28 项通过**，覆盖协议、坏 JSON、超大/错误编码、模式混用、过去/未来时间、健康矛盾、角色分格、所有状态、缩放及设置保存。root 独立复跑输出位于 `tmp/desktop-smoke-20261124-164847/`。
- **真实独立读取**：`collector --once` 返回 `mode=live/source.health=connected/version=0.1.11`，运行任务数为 2；紧接着 T3 `t3_thread_list` 也返回 2 个 running。一次命令耗时约 196 ms，包含 Python 启动，不是周期采集 p95。
- **真实窗口生命周期**：live 模式启动并在 6 秒后自动关闭，退出码 0；运行期间生成了 connected/working 快照，观察到的两个直属子进程在退出后均不存在。
- WPF 含中文文件采用 UTF-8 BOM。已检查离屏渲染效果并启用 HighQuality 图片缩放。

- **Python：52 项测试通过**，root 完整复跑耗时 3.865 秒，覆盖只读/schema/身份与版本、HTTP 大小与总超时、子任务聚合、请求语义、事件基线、快速完成、原子替换、父进程退出和演示隔离。

独立代码审查和远端 CI 状态在集成收尾后补入；本地测试通过不代表远端 CI 已运行。

## 待验收与已知边界

- secret/link 卡片及部分 T3 shell 派生等待语义尚未完整适配，见 [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11)。
- T3 私有 SQLite schema 只核对了 0.1.11。版本升级须重新验证，不自动当作兼容。
- 真实审批、失败、秘密输入、链接请求、服务退出场景尚未逐一触发；故障分支的合成测试不等于这些实机验证。
- 多屏负坐标、显示器热插拔、100%/125%/150% DPI、透明区域点击命中、长时间 CPU/内存尚待人工验收，见 [#9](https://github.com/Mugglen/rebecca-t3-pet/issues/9)。
- 完整动作美术与另一台机器的便携部署分别由 [#5](https://github.com/Mugglen/rebecca-t3-pet/issues/5)、[#10](https://github.com/Mugglen/rebecca-t3-pet/issues/10) 跟进。
- T3 `link_issue` 返回 tracker 未安装或未配置；GitHub tickets 已创建并可使用，T3 ticket 侧栏未关联成功。
