# P3 AI 智能体实施计划

设计依据：`docs/superpowers/specs/2026-10-07-p3-ai-agent-design.md`
目标：把 AI 从"一键生成卡片"升级为"数据感知的多轮对话智能体"，复用既有 `AIEngine` 配置与 `AppProvider` 数据文本化方法。

## 任务拆解

### T1 AgentService 核心（M1）
- 新建 `lib/services/agent_service.dart`：agent 循环（tool_calls → 本地执行 → role:'tool' 回传 → 再请求，上限 6 轮）；超限注入 system 强制收敛
- `AIEngine` 新增 `chatWithTools(messages, tools)` 返回 `ChatResponse{text, toolCalls}`；请求体带 `tools` + `tool_choice:'auto'`
- 降级模式：400 且报文含 tools/function 关键字 → `_toolsUnsupported`，改走数据注入（首轮拼 `getPersonalContext(3)` + `getUserProfileText()`）
- 上下文窗口：保留最近 24 条，更早轮次压缩为摘要
- 验收：mock http 下"问题→工具调用→结果→回答"闭环通过；不支持 tools 的响应正确降级

### T2 工具集（M1）
- `agent_service.dart` 内实现 8 工具注册表（name/description/JSON schema/执行函数），全部复用 Provider：`get_user_profile` / `get_today_summary` / `get_recent_workouts` / `get_recent_diets` / `get_finance_overview` / `get_health_metrics` / `search_knowledge` / `get_life_status`
- 返回人类可读文本，单条截断 ≤2000 字符；days 上限 90
- 验收：每个工具单独调用返回格式正确；非法参数安全兜底

### T3 聊天界面（M2）
- `ai_screen.dart` 重构：消息气泡流（user 右/assistant 左）+ 输入框 + 发送按钮
- 工具状态条："正在查询：…"进行中显示，完成后折叠"已查询 N 项数据"
- 快捷指令 chips（每日建议/训练方案/饮食计划/阶段总结/财务建议）预填提示词；"经典模式"入口保留旧卡片页
- 空状态引导 + 3 个示例问题
- 验收：多轮对话上下文连续；工具查询过程可见；旧功能无回归

### T4 会话管理与接入（M2）
- 新建 `lib/providers/agent_provider.dart`：messages/sending/toolStatus 状态；`sendMessage` 编排 AgentService；错误气泡可重发
- 持久化：SharedPreferences JSON（`agent_chat_history`，上限 50 条）；新会话按钮清空
- 接入 `main.dart` MultiProvider；`ai_screen` 从 AppProvider 读 aiConfigured 判断保留
- 验收：杀进程重开聊天记录还在；清空生效；`flutter analyze` 零错误

### T5 验收与收尾（M3）
- 单测：`test/agent_service_test.dart`（mock http：纯文本回答 / 单工具 / 多工具 / 6 轮上限 / 降级注入，5 用例）
- `flutter test` 全量通过 + `flutter analyze` 零错误
- Android release 编译通过（沿用 LOCALAPPDATA 重定向环境）
- README 更新（AI 智能体对话式交互、工具调用说明）
- 验收：设计 §6 七条验收逐条执行

### T6 git 提交（贯穿）
- 分批提交：T1-T2 / T3-T4 / T5，只提交客户端代码与文档

## 顺序与依赖

T1 → T2 → T3 → T4 → T5 → T6；T2 可与 T1 尾部并行。

## 工作量

| 里程碑 | 任务 | 预估 |
|---|---|---|
| M1 Agent 核心 | T1-T2 | 1.5 天 |
| M2 界面与接入 | T3-T4 | 1.5 天 |
| M3 验收 | T5-T6 | 0.5 天 |

合计约 **3.5 个开发日**。
