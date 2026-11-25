# 开发 Tickets

规格基线：[SPEC.md](SPEC.md)；架构：[ARCHITECTURE.md](ARCHITECTURE.md)。所有 issue 已在 Mugglen/rebecca-t3-pet 创建，以下状态以 GitHub 实时状态为准。

| Ticket | 阶段 | 内容 | 依赖 |
| --- | --- | --- | --- |
| [#1](https://github.com/Mugglen/rebecca-t3-pet/issues/1) | M0 | 整理瑞贝卡官方参考图库与美术依据 | 无 |
| [#2](https://github.com/Mugglen/rebecca-t3-pet/issues/2) | M0 | 固化产品规格、架构决策和验收矩阵 | #1 |
| [#3](https://github.com/Mugglen/rebecca-t3-pet/issues/3) | M1 | 实现 T3 0.1.11 只读状态采集适配器 | #2 |
| [#4](https://github.com/Mugglen/rebecca-t3-pet/issues/4) | M1 | 实现多任务状态归约、完成去重与快照协议 | #3 |
| [#5](https://github.com/Mugglen/rebecca-t3-pet/issues/5) | M1/M2 | 制作 Q 版瑞贝卡透明角色与状态动画资产 | #1、#2 |
| [#6](https://github.com/Mugglen/rebecca-t3-pet/issues/6) | M1 | 实现 WPF 透明桌宠窗口与状态交互 | #4、#5 M1 |
| [#7](https://github.com/Mugglen/rebecca-t3-pet/issues/7) | M1 | 完成启动器、配置和单实例生命周期 | #3、#6 |
| [#8](https://github.com/Mugglen/rebecca-t3-pet/issues/8) | M1 | 自动测试、CI 与真实状态验证报告 | #4、#6、#7 |
| [#9](https://github.com/Mugglen/rebecca-t3-pet/issues/9) | M2 | 完成多屏、DPI、点击命中与资源占用验收 | #8 |
| [#10](https://github.com/Mugglen/rebecca-t3-pet/issues/10) | M3 | 便携发布包、安装与升级故障文档 | #9、#5 M2 |
| [#11](https://github.com/Mugglen/rebecca-t3-pet/issues/11) | M2 | 补齐 secret/link 卡片与特殊等待语义 | #3、#4、#8 |

## 交付顺序

1. M0：参考库与规格文档。
2. M1：只读采集 → 状态归约 → 正式立绘与窗口 → 启动器 → 测试和真实读取验证。
3. M2：完整动作资产、多屏/DPI 和长期运行验收。
4. M3：便携包与清洁环境发布验证。

GitHub issue 是工作记录。实现通过 PR 关联，未通过验收的 ticket 不提前关闭；M1 完成不代表 M2/M3 完成。

本次尝试 T3 link_issue 返回 tracker 未安装或未配置；GitHub tickets 已成功创建，T3 侧栏关联未完成。
