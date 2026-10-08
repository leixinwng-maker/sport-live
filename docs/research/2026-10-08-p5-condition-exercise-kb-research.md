# P5 疾病—运动关联知识库 数据来源与许可调研

日期：2026-10-08
承接：P4 设计规格「非目标」中「疾病—运动处方不做专业医疗建议」的边界，及其后续项。
目标：为「疾病 → 可改善的运动 / 具体动作」这一知识方向，确定**合法、可核验、可条目化改写**的来源清单与开源资产清单，并给出可落地的数据边界。

## 0. 本报告与既有文档的关系

- 本报告将 P5 的主方向从「家庭用药安全（OTC）」**切换为「疾病—运动关联」**，因用户明确「主要我想要疾病和运动之间关联的这种数据库」。
- 既有文档 `docs/research/2026-10-08-p5-home-health-kb-research.md`（家庭用药安全方向）**保留不删**，作为平行的候选方向存档；若后续需要，可另立项名为 P5-Option。
- 用户追加的两条硬性偏好已纳入本报告筛选标准：**优先开源免费**、**优先到 GitHub 找**。

## 1. 合规底线（硬约束）

1. **不写爬虫**：不编写任何自动抓取第三方站点的脚本。最高检指导性案例已明确，超越授权爬取可构成非法获取计算机信息系统数据罪；此约束在 P4 已确立，本方向延续。
2. **优先使用带明确开放许可的资产**：只采用 public domain / CC0 / Unlicense / MIT / Apache-2.0 / CC-BY 等允许再分发与商用的许可；NC / ND 许可一律降级或排除。
3. **改写而非照搬**：逐条改写摘要，不整篇复制；每条带 `source / url / license` 出处。
4. **安全导向而非处方导向**：本方向回答「运动类别与剂量对某类疾病的一般性健康收益」，**不做诊断、不给个体化处方、不承诺疗效**，不替代医生与康复师；所有条目附免责与就医引导。

## 2. 核心结论（先给判断）

1. **不存在现成的「疾病 ↔ 具体动作」映射型开源数据库。** 没有任何一个开源库已把「帕金森 → 硬拉」这类映射填充好。最接近的是 **EXMO**（运动医学本体），但它是**本体骨架 + 公理**，不是填充好的映射表。
2. **权威指南的证据粒度是「疾病 → 运动类别 + FITT-VP 剂量」，不是「疾病 → 具体动作」。** 例如 PAG 2018 只给「每周 150–300 分钟中等强度有氧 + 每周 2 天抗阻」，不会说「做硬拉」。因此把「硬拉 / 卧推」直接挂到疾病上是**证据越级**。
3. 因此本方向必须采用**两层证据结构**（见 §7）：第一层为强证据（疾病→类别+剂量），第二层为弱证据（类别→具体动作，标注为示例且必带禁忌）。这样既满足用户「想看具体动作」的诉求，又不虚构医学结论。
4. 动作侧资产充足且许可宽松（Unlicense / MIT / CC-BY-4.0）；疾病侧编码建议走 **DOID（CC0）**，避开 ICF（CC BY-ND 禁演绎）。

## 3. 可直接接入的开源资产（GitHub 优先）

| 资产 | 内容与规模 | 许可 | 可再分发 | 商用 | 用途定位 |
|---|---|---|---|---|---|
| [yuhonas/free-exercise-db](https://github.com/yuhonas/free-exercise-db) | 800+ 动作，逐条 JSON + JSON Schema | **Unlicense（公共领域）** | 可 | 可 | **动作库首选**：主表 |
| [hasaneyldrm/exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset) | 1324 动作，含中英等 10 语言分步说明 | 数据部分 **MIT**；媒体受限（见 §8） | 可（仅数据） | 可（仅数据） | 中文动作说明来源；**只用数据不用媒体** |
| [wrkout/exercises.json](https://github.com/wrkout/exercises.json) | free-exercise-db 的上游原始数据集 | 公共领域 | 可 | 可 | 动作库溯源自校验 |
| [Exercise-Medicine-Ontology/EXMO](https://github.com/Exercise-Medicine-Ontology/EXMO) | 434 类、9732 公理；含疾病类 + 运动类 + FITT-VP | **CC-BY-4.0** | 可（须署名） | 可 | **结构骨架**：疾病↔运动↔剂量的本体框架 |
| [DiseaseOntology/HumanDiseaseOntology](https://github.com/DiseaseOntology/HumanDiseaseOntology) | DOID 疾病分类本体 | **CC0 1.0** | 可 | 可 | **疾病侧编码**：统一疾病标识 |
| [SolidLabResearch/activity-ontology](https://github.com/SolidLabResearch/activity-ontology) | activo，运动活动 OWL 本体 | **MIT** | 可 | 可 | 运动活动记录建模参考 |
| wger（wger-project） | 约 600 动作 + 食材数据 | 应用 AGPL-3+；**动作/食材数据额外 CC-BY-SA 3.0** | 可（数据须同许可传染） | 可 | 备选动作源（注意 SA 传染） |
| OpenSim（SimTK） | 骨骼肌模型 | **Apache-2.0** | 可 | 可 | 动作→受训肌群推算（离线研究用） |

已核实的关键事实：

- **free-exercise-db** 采用 Unlicense（公共领域），合并文件位于 `https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json`；单条字段为 `id / name / force / level / mechanic / equipment / primaryMuscles / secondaryMuscles / instructions / category / images`，其中 `force / mechanic / equipment` 允许为 `null`。
- **hasaneyldrm/exercises-dataset** 仓库约 22,590 stars / 2,883 forks，GitHub API 返回 `license: Other / NOASSERTION`（需读 NOTICE.md 才能判明真实条款）；字段含 `id / name / category / body_part / equipment / instructions.{en,es,it,tr,ru,zh,hi,pl,ko,fr} / instruction_steps.<lang> / muscle_group / secondary_muscles / target / media_id / image / gif_url / attribution / created_at`，**含中文分步说明**。
- **EXMO** 的许可在 bioregistry 登记为 **CC-BY-4.0**，版本 2025-06-05，OWL 地址 `http://purl.obolibrary.org/obo/exmo.owl`，默认分支为 `master`（仓库 API 无 license 字段，须以 bioregistry 与论文为准），论文 PMID 39695140。
- **DOID** 在 OBO Foundry 登记为 **CC0 1.0**，PURL `http://purl.obolibrary.org/obo/doid.owl`。

## 4. 美国政府 / 公共领域权威来源（可作强证据）

| 来源 | 性质 | 许可 | 用法 |
|---|---|---|---|
| PAG 2018《Physical Activity Guidelines for Americans》第 2 版 | 美国政府作品 | **公共领域** | 疾病/人群 → 运动类别 + 剂量（第一层强证据主来源） |
| 2023 Midcourse Report（老年人实施策略） | 美国政府作品 | 公共领域 | 老年人细分人群补充 |
| CDC 体力活动科普与慢病专题 | 美国政府作品 | 公共领域 | 交叉校验与补充 |
| MedlinePlus | 美国政府作品 | 公共领域 | 患者向表述参考 |
| OpenAlex | 学术元数据 | **CC0** | 文献元数据检索（零许可风险） |

注意：**未检索到独立的「2024 中期报告」**，现行为 2023 年 Midcourse Report（老年人），不对其虚构年份或内容。

## 5. 仅可作事实核对（不可入库、不可再分发）

| 来源 | 限制 |
|---|---|
| ACSM EIM「Rx for Health」 | **All rights reserved**，版权非开放；仅可按病种单页查阅后人工核对事实，不整篇搬运 |
| WHO 2020 体力活动与久坐指南 | **CC BY-NC-SA 3.0 IGO，仅非商业**；若产品商用则不可入库 |
| AHA（美国心脏协会） | 允许 ≤10% 文字 / ≤25% 图表作非商业教育引用并须附声明 |
| NICE NG59（腰痛等） | 须按其再使用条款执行 |
| Cochrane | 需 Wiley 授权，且禁止上传至生成式 AI |
| PEDro | 仅合理使用（≤10%、私用）；商业使用需书面批准；内页有反爬拦截 |
| Europe PMC / NCBI E-utilities | 仅 OA 子集逐篇 CC；E-utilities 限 3/10 RPS，摘要版权存疑 |
| Semantic Scholar | API 不可再授权，数据含 CC BY-NC |

## 6. 明确排除

| 来源 | 排除理由 |
|---|---|
| DrugBank | CC BY-NC，禁商用 |
| Kaggle「ExerciseDB」类数据集 | 页面标 MIT 但说明「商业权利需付费」，不可作免费商用来源 |
| ExRx.net | 受 Cloudflare 反爬保护，**条款未能核实**，不可想当然认为可用 |
| DiseaseKG / openkg 部分疾病知识图谱 | 基于爬取构建，来源不合规 |
| WHO ICF（对**疾病编码**用途） | CC BY-ND 3.0 IGO，**禁演绎**，不能改写为自有结构商用；疾病编码改走 DOID |
| 任何站点的自动抓取脚本 | 法律风险（非法获取计算机信息系统数据） |
| 个体化运动处方 / 处方药建议 | 超出产品边界与责任能力 |

## 7. 两层证据结构设计（落地约束）

**第一层（强证据，必须带出处）**：疾病/人群 → 运动类别 + FITT-VP 剂量。
- 例：2 型糖尿病 → 有氧（每周 ≥150 分钟中等强度）+ 抗阻（每周 2–3 次，非连续日）。
- 来源限 PAG 2018 / CDC / MedlinePlus / WHO（若走非商业）等，逐条改写并带 URL。

**第二层（弱证据，必须标「示例」且带禁忌）**：运动类别 → 具体动作示例。
- 例：抗阻 → 示例动作：深蹲、硬拉、卧推、划船、推举。
- **禁止**写成「硬拉改善某病」；正确表述为「某病推荐进行抗阻训练（示例动作含硬拉），但需在专业指导下进行，合并某情况者禁忌」。
- 来源为动作库（free-exercise-db 等），仅提供动作的肌群/器械/要领，不提供疗效主张。

## 8. 媒体资源约束（重要落地坑）

- `hasaneyldrm/exercises-dataset` 的**图片/动图为 © Gym visual**，仅 **180×180**，且必须保留署名（`attribution` 字段）；README 明确「cloning this repo is not a license」，其媒体复用须**另行**向 Gym visual 取得授权。
- 因此落地策略：**只用其数据（动作名称、肌群、中文分步说明），不使用其图片/动图**；若需插图，另寻可商用图源或自绘。
- `free-exercise-db` 中的 `images` 指向外部托管，同样需单独核实图片许可，不可默认随 JSON 一起可商用。

## 9. 结论与下一步

来源与资产充足且合法：以 **EXMO（CC-BY-4.0）作结构骨架**、**DOID（CC0）作疾病编码**、**free-exercise-db（Unlicense）作动作主表**、**hasaneyldrm 数据集（MIT 数据部分）补中文说明**、**PAG/CDC/MedlinePlus（公共领域）作第一层强证据**，足以支撑一个规模可控、逐条带出处、两层证据分离的「疾病—运动关联」知识库。

下一步：
1. 撰写设计规格 `docs/superpowers/specs/2026-10-08-p5-condition-exercise-kb-design.md`：定义 `EvidenceEntry` 复用方式（新增 `domain=疾病运动`）、两层证据的数据结构、免责与禁忌字段、`search_condition_exercise` 工具契约。
2. 撰写实施计划 `docs/superpowers/plans/2026-10-08-p5-condition-exercise-kb-plan.md`。
3. 落地动作库导入管线（扩展 `scripts/import_knowledge.py`），首批仅导入数据部分、剥离媒体。
