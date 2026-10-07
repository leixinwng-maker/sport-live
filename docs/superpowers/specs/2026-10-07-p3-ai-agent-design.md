# P3 AI 智能体设计规格

日期：2026-10-07
状态：待批准

## 1. 目标与非目标

### 目标
把 AI 能力从"一键生成卡片的场景化问答"升级为**数据感知的多轮对话智能体**：
- AI 可自主调用工具查询用户真实数据（训练/饮食/财务/健康/知识库/生活状态），基于事实回答，而非用户手动粘贴
- 支持多轮追问，上下文连续（"把昨天的训练加两组"能接住上一轮的方案）
- 对话过程透明：查询了哪些数据、工具调用状态可见

### 非目标
- 不做流式输出（国内模型流式兼容差异大，整段返回已够用）
- 不做多智能体协作
- 不做语音输入
- 旧六大场景方法（每日建议/阶段总结/训练方案/饮食计划/财务建议/报告解读）保留不动，作为快捷指令入口

## 2. 现状与差距

### 已有基础（侦查结论）
- `ai_engine.dart`（336 行）：http 直连 OpenAI 兼容 `/v1/chat/completions`，配置（baseUrl/apiKey/model/visionModel）存 SharedPreferences；6 个场景化方法均为"硬编码 system prompt + 拼接数据字符串 → 单次 chat()"
- `app_provider.dart`：**数据文本化方法已齐备**——`getUserProfileText()` / `getTodaySummary()` / `getFinanceOverviewText()` / `getBrainContext(query, topN)` / `getPersonalContext(days)`；训练/饮食/财务/健康/生活状态 List 均在内存
- `ai_screen.dart`：静态卡片流，一键生成、无上下文

### 差距
1. 无多轮会话（每次都是独立请求）
2. 无 function calling 循环（数据只能预先拼接，AI 无法按需查询）
3. 无聊天界面

## 3. 架构：Agent 循环

```
用户消息 → AgentService.sendMessage()
  ├─ 1. 组装 messages（system + 历史窗口 + 新消息）
  ├─ 2. 调 AIEngine.chatWithTools(messages, tools)
  ├─ 3. 响应含 tool_calls？
  │     ├─ 是 → 逐个执行本地工具 → 结果以 role:'tool' 追加 → 回到 2（上限 6 轮）
  │     └─ 否 → 最终回答，返回
  └─ 4. 消息历史落盘（SharedPreferences JSON，上限 50 条）
```

### 3.1 AgentService（新文件 `lib/services/agent_service.dart`）
- `sendMessage(String userText)` → 追加 user 消息 → 循环上述 2-3 → 返回 assistant 最终文本
- 每轮工具调用通过回调 `onToolCall(name, args)` / `onToolResult(name, summary)` 通知 UI 展示状态
- 6 轮上限触发时注入一条 system 提示强制收敛回答
- 上下文窗口：保留最近 24 条消息；超出时把更早轮次压缩为一段摘要（`此前对话要点：…`，由当轮 assistant 文本拼接）

### 3.2 AIEngine 扩展（`chatWithTools`）
- 请求体增加 `tools` 与 `tool_choice: 'auto'`
- 解析响应 `choices[0].message`：含 `tool_calls` 时返回结构化对象（不走纯文本分支）
- 新增 `ChatResponse` 类型：`{ text: String?, toolCalls: List<ToolCall>? }`
- 工具执行结果格式：`role:'tool'`, `tool_call_id`, `content`（JSON 字符串）

### 3.3 降级模式（模型不支持 tools）
- 首次请求带 tools 返回 400 且报文含 `tools`/`function` 关键字 → 标记 `_toolsUnsupported = true`
- 降级为**数据注入模式**：首轮请求前自动拼接 `getPersonalContext(3)` + `getUserProfileText()` 进 system，后续轮次仅靠对话历史
- UI 设置页提示"当前模型不支持工具调用，已启用简化模式"

## 4. 工具集契约（8 个，全部复用 Provider 现有方法）

| 工具名 | 参数 | 实现（复用） | 返回 |
|---|---|---|---|
| `get_user_profile` | - | `getUserProfileText()` | 身体档案文本 |
| `get_today_summary` | - | `getTodaySummary()` | 今日训练/饮食/收支摘要 |
| `get_recent_workouts` | `days:int=7` | workouts 列表过滤格式化 | 逐条：日期/部位/动作×组次重量 |
| `get_recent_diets` | `days:int=3` | diets 列表过滤格式化 | 逐条：日期/餐次/食物×热量 |
| `get_finance_overview` | - | `getFinanceOverviewText()` | 月度收支/分类占比 |
| `get_health_metrics` | `days:int=30` | healthMetrics 过滤格式化 | 逐条：日期/指标/数值 |
| `search_knowledge` | `query:string` | `getBrainContext(query, topN:6)` | 知识库片段 |
| `get_life_status` | `days:int=7` | lifeStatus 过滤格式化 | 睡眠/情绪/压力记录 |

- 所有返回为**人类可读文本**（直接作为 tool content），截断保护单条 ≤2000 字符
- 参数校验：days 上限 90，query 非空

## 5. 会话管理与 UI

### 5.1 AgentProvider（并入 AppProvider 或独立，倾向独立 `lib/providers/agent_provider.dart`）
- 状态：`messages: List<ChatMessage>`（role/text/toolCalls 标记）、`sending: bool`、`toolStatus: String?`
- 持久化：SharedPreferences JSON（key `agent_chat_history`），上限 50 条，新会话按钮清空
- 发送失败：错误气泡 + 消息保留可重发

### 5.2 聊天界面（`ai_screen.dart` 重构）
- 主体：ListView 消息气泡（user 右侧玉石绿底 / assistant 左侧宣纸白底），Markdown 延用现有渲染方式
- 工具状态条：assistant 气泡上方浅色条显示"🔍 正在查询：训练记录…"，完成后折叠为"已查询 3 项数据"小字
- 输入区：TextField + 发送按钮，sending 时禁用并显示转圈
- 快捷指令：输入框上方横向滚动 chips（每日建议/训练方案/饮食计划/阶段总结/财务建议），点击预填对应提示词进聊天框（走智能体，AI 自主查数据）；旧卡片页保留入口按钮"经典模式"跳转
- 空状态：引导语 + 3 个示例问题点击即发

## 6. 验收标准

1. 多轮追问：首轮"最近一周训练怎么样"（AI 自动调 `get_recent_workouts`），次轮"根据这个给我明天的计划"（能引用上轮数据，AI 视需要再调工具）
2. 工具透明：AI 查询了什么数据在界面上可见
3. 快捷指令：chips 触发的回答包含真实数据（非模板空谈）
4. 降级可用：不支持 tools 的模型下走数据注入模式，回答仍含真实数据
5. 会话持久：杀进程重开，聊天记录还在；新会话按钮可清空
6. `flutter analyze` 零错误；旧六大场景功能不回归（经典模式可用）
7. 单测：mock http 下 agent 循环（工具调用→结果回传→收敛）通过

## 7. 工作量

| 任务 | 预估 |
|---|---|
| T1 AgentService + AIEngine.chatWithTools | 1 天 |
| T2 工具集 8 个 | 0.5 天 |
| T3 聊天界面重构 | 1 天 |
| T4 AgentProvider + 持久化 + analyze 清零 | 0.5 天 |
| T5 测试 + Android 编译 + README | 0.5 天 |
| T6 git 提交 | - |

合计约 **3.5 个开发日**。
