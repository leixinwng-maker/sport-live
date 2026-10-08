# P5 开源医学文献数据库 调研（接入可行性）

日期：2026-10-08
承接：`docs/research/2026-10-08-p5-condition-exercise-kb-research.md`（疾病—运动关联知识库）。
目标：回答「有没有开源的医学论文数据库」，并给出**能否接入、怎么接入、许可边界在哪**的结论，供 P5 联网文献检索层落地。

## 1. 合规底线（硬约束）

1. **不写爬虫**：不自动抓取出版商站点；只用官方 API / 官方批量数据集。
2. **按许可分层使用**：元数据、摘要、全文三者许可**互不相同**，必须逐层判定，不可整库默认可用。
3. **不整篇转载**：入库只保留「元数据 + 短改写摘要 + 原文链接」，不缓存、不再分发全文。
4. **不以文献替代诊疗**：文献检索结果作为「证据引用」呈现，附免责与就医引导。

## 2. 核心结论

**有，而且不少，但必须分三层理解，"能搜到"不等于"能转载"。**

| 层 | 内容 | 许可状况 | 可用性 |
|---|---|---|---|
| 元数据层 | 标题 / 作者 / 期刊 / 年份 / DOI / 摘要链接 | 多为 CC0 或公共领域 | **可自由商用、可再分发** |
| 摘要层 | 摘要全文 | 部分受出版商/作者版权保护 | **须逐条判定**，多数只宜「存链接 + 改写」 |
| 全文层 | 正文 | 取决于单篇 OA 许可 | 仅 CC0 / CC BY / CC BY-SA / CC BY-ND 可商用 |

**推荐组合（可直接接入）**：**OpenAlex（CC0，主检索）+ Europe PMC（生物医学专用，EMBL-EBI 允许商用）+ Unpaywall / OpenAlex 的 `best_oa_location`（解析合法 OA 全文链接）**，配 **PubMed E-utilities** 作补充。**Semantic Scholar 实时 API 与 Elsevier/Springer/Wiley 全文不可用**（禁商用）。

## 3. 元数据层：可商用、可再分发

| 来源 | 内容 | 许可 | 备注 |
|---|---|---|---|
| [OpenAlex](https://openalex.org/about) | 全球研究图谱（作品/作者/机构/主题），含 `open_access` 与 `best_oa_location` | **CC0（公共领域）** | 数据快照全量免费下载；API 需免费 key，免费额度约 1 美元/日 |
| [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/) | 1.85 亿条 DOI 元数据、基金、许可信息 | 元数据多为**公共领域/CC0**（事实性数据） | **无需注册、无费用**；但**摘要版权仍归出版商/作者** |
| [DOAJ](https://doaj.org/terms/) | 开放获取期刊与文章元数据 | 期刊级与文章级元数据均 **CC0** | 无需署名，可摄入自有系统 |
| [arXiv API](https://info.arxiv.org/help/api/tou.html) | 预印本描述性元数据 | 元数据 **CC0** | 电子印本正文版权归作者，须逐篇看许可 |
| [Unpaywall API](https://unpaywall.org/api) | OA 状态、host 类型、版本、许可 | 免费开放 API | 与 OpenAlex 同团队，OpenAlex 已内建同类字段 |
| [Europe PMC](https://www.ebi.ac.uk/about/faq/) | 生物医学文献、预印本、注释 | **EMBL-EBI 使用条款：面向学术、临床与商业用户免费开放**，数据开放许可、不施加超出数据所有者的额外限制 | 单次 API + 批量下载；OA 子集为 CC 许可 |

关键事实：EMBL-EBI 明确「all EMBL-EBI databases and tools are freely available for academic, clinical and commercial users under our terms of use」，并「不施加超出数据所有者的额外限制」[$TRAE_REF](https://www.ebi.ac.uk/about/faq/)，因此 **Europe PMC 的元数据与 OA 子集可商用**；但非 OA 文章的全文仍受原作者许可约束。

## 4. 摘要 / 全文层：须逐条判定

| 来源 | 可用范围 | 约束 |
|---|---|---|
| [PMC 开放获取子集](https://pmc.ncbi.nlm.nih.gov/tools/textmining/) | **可商用**：CC0、CC BY、CC BY-SA、CC BY-ND；**仅非商用**：CC BY-NC 系列 | 全文仅经云服务 / OAI-PMH / E-utilities / BioC 获取；**许可逐篇不同**；「系统性/批量检索须走官方数据集，其他自动化流程被禁止」 |
| Europe PMC OA 子集 | 受 CC 或类似许可保护的全文 | 逐篇许可；预印本若无许可，会征得作者同意加挂 Europe PMC 许可 |
| [PubMed E-utilities](https://www.ncbi.nlm.nih.gov/books/NBK25497/) | 检索与元数据/摘要 | E-utilities 为**美国政府作品**可自由使用；但**摘要可能含受版权保护内容**，再分发/商用须自行合规，且产品中须呈现 NCBI 免责声明；速率约 3 请求/秒 |

落地结论：**摘要不整篇入库**。做法是「存元数据 + 由模型短改写要点 + 附原文链接」，规避摘要版权风险，同时满足「可核验」。

## 5. 受限与明确排除

| 来源 | 判定 |
|---|---|
| [Semantic Scholar 实时 API](https://api.semanticscholar.org/license/) | **禁止商业使用**（禁止将其嵌入自身或第三方获利产品）；仅可作非商用研究 |
| Semantic Scholar 的 **S2ORC 批量语料** | 采用 **ODC-By**，注明来源可商用 —— 与实时 API 条款不同，须分开看待 |
| [bioRxiv / medRxiv](https://www.medrxiv.org/tdm) | **作者保留版权**；若做索引/工具，**必须回链 medRxiv、不得再托管正文**；改写/商用须先取得作者许可；且**未经许可不得用于训练模型** |
| Elsevier / Springer / Wiley 全文 | 需订阅或授权，排除 |
| Cochrane | 需 Wiley 授权，且禁止上传至生成式 AI |
| 任何站点爬虫 | 法律风险（非法获取计算机信息系统数据） |

## 6. 接入建议（落到本项目）

1. **新增智能体工具 `search_literature`**：入参 `query` / `condition`（可选 `year_from`）；返回「标题＋作者＋期刊＋年份＋DOI＋许可＋链接」，附短改写要点，最多 5 条。
2. **来源优先级**：Europe PMC（生物医学相关性最好，免 key）→ OpenAlex（补全与去重，CC0）→ Unpaywall 字段（解析合法 OA 全文链接）。PubMed E-utilities 作交叉校验，不作主源。
3. **许可过滤**：只保留 `CC0 / public domain / CC BY / CC BY-SA / CC BY-ND`；**丢弃 CC BY-NC 系列与非开放声明**，避免商用风险。
4. **只读不缓存正文**：本地不落全文、不落摘要原文；只存元数据与链接，符合「不整篇转载」底线。
5. **复用现有「循证文献联网检索」开关**：该工具涉及外发检索词，默认**关闭**，须用户显式开启；健康相关检索词外发前提示用户，符合 PIPL 单独同意与最小必要原则。
6. **失败降级**：网络不可用或未开启时，明确返回「联网文献检索未开启／不可用」，并回退到本地循证库（`search_medical_evidence`），**禁止编造文献**。

## 7. 结论

开源医学文献数据库**确实存在且可接入**：**OpenAlex（CC0）+ Europe PMC（EMBL-EBI 可商用）+ Unpaywall 字段**三件套即可覆盖「检索—去重—定位合法全文」全链路，且零许可风险。**唯一雷区是"摘要与全文的转载"**——故本项目的做法是**只引用元数据与链接、要点由模型改写**，并按 CC 许可白名单过滤、默认关闭联网开关。Semantic Scholar 实时 API、bioRxiv 正文再托管、出版商全文三处明确排除。
