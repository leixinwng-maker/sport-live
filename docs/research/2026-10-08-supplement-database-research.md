# 补剂（膳食补充剂）数据源 许可与接入调研

日期：2026-10-08
承接：`docs/ROADMAP.md` §3.2「P6-B 补剂数据库调研」，为 P6-C 补剂接入提供决策依据。
目标：为「补剂的成分、剂量、适用人群与安全提示」这一知识方向，逐条核验候选数据源的**许可边界、接入形态、字段覆盖与内容边界**，给出可落地的推荐方案。

## 0. 本报告要回答的四个问题

| 编号 | 问题 | 落点 |
|---|---|---|
| Q1 | 许可边界：四个候选源能否本地打包与再分发，署名与共享义务如何 | §2、§2.5 |
| Q2 | 接入形态：构建期静态导入还是运行时按条码/名称查询 | §3 |
| Q3 | 字段覆盖：六类字段各能拿到多少，中文覆盖率，能否复用 `FoodCatalog` | §4 |
| Q4 | 内容边界：功效宣称的合规约束与免责话术写法 | §5 |

## 1. 合规底线（硬约束）

沿用 P4/P5 已确立的三条约束，本方向不放松：

1. **不写爬虫**：不编写任何自动抓取第三方站点的脚本。数据获取一律走官方发布的公开文本、开放接口或授权许可。最高检指导性案例已明确，超越授权爬取可构成非法获取计算机信息系统数据罪。
2. **只用带明确开放许可的资产**：public domain / CC0 / OGL / ODbL 等允许再分发与商用的许可可用；NC（非商用）、ND（禁演绎）一律降级或排除。
3. **改写而非照搬**：逐条改写摘要，不整篇复制说明书或综述正文；每条带 `source / url / license` 出处。

补剂方向另加一条：**内容侧不做疗效承诺**。详见 §5。

## 2. 候选数据源逐条核验

### 2.1 NIH DSLD（Dietary Supplement Label Database）

美国 NIH 下属 Office of Dietary Supplements（ODS）维护的**产品标签级**数据库，收录美国市场膳食补充剂标签的结构化字段。

**许可**：数据属公共领域，非版权作品，以 **CC0 1.0 Universal** 发布。官方 API Guide 原文：「DSLD data are in the public domain and they are not copyrighted. They are published under CC0 1.0 Universal (CC0 1.0). No permission is needed for their use, but we request that developers list DSLD as the source of the data」（[DSLD API Guide](https://dsld.od.nih.gov/api-guide)）。CC0 允许自由复制、修改、再分发与商用，**署名仅为请求而非法律义务**；官方建议引用格式为「National Institutes of Health, Office of Dietary Supplements. Dietary Supplement Label Database. https://dsld.od.nih.gov/」。

**接入方式**：有官方 REST API，当前版本 9.4.0，基础地址 `https://api.ods.od.nih.gov/dsld/v9/`，端点为 `label/{dsldId}`、`brand-products`、`browse-products`、`browse-brands`、`ingredient-groups`、`search-filter`（支持**条码/UPC**、产品类型、成分、品牌、适用人群、剂型等组合过滤）、`search-filter-histogram`（[DSLD Swagger](https://dsldapi.od.nih.gov/)）。限流默认 1,000 次/小时/IP，注册 data.gov API key 后 10,000 次/小时。另**支持整库下载**，提供 XLSX / CSV / JSON 三种 `.zip` 包（同上 API Guide）。

**字段**：`brandName`（品牌）、`fullName`（产品名）、`upcSku`（条码）、`ingredientRows[]`（成分表，含成分名、quantity + unit、servingSizeUnit、每日参考值百分比）、`netContents[]` + `physicalState`（剂型）、`targetGroups` / `userGroups`（适用人群，如「Adult (18 - 50 Years)」「Vegetarian」）、`statements`（含警示）、`claims`、`contacts`。**六类关切字段全部具备结构化支持**。

**规模**：v9.4.0（2026-01）共 **214,780 条**标签（在市场 121,959 / 已下市 92,821），另有 NHANES 来源 8,506 条（[Release History](https://dsld.od.nih.gov/release-history)）。

**中文**：**无**。库内为美国市场标签原文，以英文为主。

### 2.2 NIH ODS Fact Sheets

ODS 发布的**营养素/成分科普与专业综述**（如 Vitamin C、Iron、Zinc 等），分消费者版与专业人员版。

**许可**：美国政府作品，依 17 U.S.C. §105 不受版权保护，属**公共领域**。ODS 官方出版物明确：「ODS Update is not copyrighted and is in the public domain. If you copy or distribute its content, please credit the NIH Office of Dietary Supplements and include the publication title and date. Do not use our information in any way that suggests we endorse any commercial product or service.」（[ODS Update](https://ods.od.nih.gov/pubs/odsupdate/Spring2015.pdf)）。署名与「不暗示背书」均为官方书面请求。

**接入方式**：**无官方 API，无整库打包下载**。内容以网页 HTML 与可打印 PDF 逐篇发布（如 `https://ods.od.nih.gov/pdf/factsheets/VitaminC-Consumer.pdf`），需逐篇获取（[Fact Sheets 目录](https://ods.od.nih.gov/factsheets/list-VitaminsMinerals/)）。

**字段**：属**综述文本**，非产品标签，故**不含**品牌、单份剂量、剂型等商品字段。其内容结构为：成分名、Consumer / Health Professional 两个版本、按生命阶段列出的推荐摄入量、食物来源、健康效应、危害与药物相互作用、参考资料。**适用人群体现为按生命阶段（婴儿/儿童/青少年/成人/孕妇/哺乳期）列推荐量**，非产品目标人群。

**规模**：无单一总数，覆盖维生素、矿物质、草本/植物、益生菌等，多为「同一主题 × 3 版本（英文消费者版 / 英文专业版 / 西班牙语版）」。

**中文**：**无**，仅英文与西班牙语。

### 2.3 Health Canada LNHPD（Licensed Natural Health Products Database）

加拿大卫生部**已许可天然健康产品**数据库（天然健康产品即加拿大的膳食补充剂监管类目）。

**许可**：**Open Government Licence – Canada v2.0**。许可全文授予「worldwide, royalty-free, perpetual, non-exclusive licence … **including for commercial purposes**」，允许「copy, modify, publish, translate, adapt, distribute or otherwise use」（[OGL-Canada](https://open.canada.ca/en/open-government-licence-canada)）。**无 share-alike 传染条款**，可本地打包、镜像与再分发，仅需履行署名义务；若提供者未指定声明，须使用固定措辞「**Contains information licensed under the Open Government Licence – Canada.**」。许可不覆盖个人信息、第三方权利与官方徽标。

**接入方式**：**CSV 文本提取包已被官方弃用**（数据集页顶部红字提示，链接将删除）；现行推荐 **XML / JSON 经 API 每日更新**。基础 URI `https://health-products.canada.ca/api/natural-licences/`，7 个接口：MedicinalIngredient、NonMedicinalIngredient、ProductDose、ProductLicence、ProductPurpose、ProductRisk、ProductRoute；参数 `id` / `lang=en|fr` / `type=json|xml`（[LNHPD 数据集页](https://open.canada.ca/data/en/dataset/ef546c83-43a8-4404-943e-ab324164eeb3)、[API 文档](https://health-products.canada.ca/api/documentation/lnhpd-documentation-fr.html)）。另有截至 2017-09-28 的历史静态包（竖线分隔文本，已过时）。

**字段**：`product_name`、`licence_number`、`dosage_form`（剂型）、`status`（区分已许可/已停用）、Recommended Dose（`population_type_desc` 人群、`age`、`quantity_dose`/`quantity_minimum_dose`/`quantity_maximum_dose`、`frequency`）、Products Risk（`risk_type_desc`、`risk_text` 风险原文）、Companies（企业名与地址）、Medicinal/Nonmedicinal Ingredients（成分正名、数量、效价）、Route（给药途径）。**字段为英法双语**（`*_e` / `*_f`），以公共键 `product_id` 关联。

**规模**：`MedicinalIngredient` 接口返回 830,185 条（2026-10-08 实测，[API](https://health-products.canada.ca/api/natural-licences/)）；`ProductLicence` 接口响应体过大，本次多次请求超时，未取得精确的「已许可产品数」，如实标注为 [未取得]。

**中文**：**无**，为英语与法语。

### 2.4 Open Food Facts

众包食品数据库，项目已用于食品条码查询（`FoodLookupService`）。

**许可**：三层结构——**数据库整体 ODbL 1.0**，**单项内容 DbCL 1.0**，**产品图片 CC BY-SA 3.0**（[Terms of Use](https://world.openfoodfacts.org/terms-of-use)、[Data](https://world.openfoodfacts.org/data)）。ODbL 含**传染性 share-alike**：第 4.4 条「Any Derivative Database that You Publicly Use must be only under the terms of this License …」；4.4(b) 明确「Extraction or Re-utilisation of the whole or a Substantial part of the Contents into a new database is a Derivative Database and must comply with Section 4.4」（[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/)）。但 4.5 给出豁免：作为**集体库（Collective Database）**的组成部分、生成**产出作品（Produced Work，如报告/图表）**、以及**组织内部非公开使用**，均不触发 share-alike。官方再使用条款还要求署名 Open Food Facts 并链接官网，且数据「must not be used for medical purposes」。

**接入方式**：官方**每日导出**（MongoDB dump / JSONL / Parquet / CSV，全量 CSV 解压约 9 GB）+ 实时 **JSON API v2**。官方明确「Any attempt to scrape the database using the API will very likely be blocked」，全量须走导出文件（[Data](https://world.openfoodfacts.org/data)）。

**字段**：条码、产品名、数量、品牌、分类、配料、添加剂、过敏原、营养值、Nutri-Score、NOVA 分组等；**无「单份剂量」与「剂型」**（其营养值为每 100 g）。

**规模**：**4,799,900** 个产品（2026-10-08 官网首页）。

**中文**：**部分**，存在 `product_name_zh` 等中文字段，项目现有条码查询已在用。

### 2.5 四源对照

| 维度 | NIH DSLD | NIH ODS Fact Sheets | Health Canada LNHPD | Open Food Facts |
|---|---|---|---|---|
| 许可 | 公共领域 + **CC0 1.0** | 公共领域（非版权） | **OGL-Canada v2.0** | **ODbL 1.0**（内容 DbCL 1.0） |
| 商用 | 允许 | 允许 | 允许 | 允许 |
| 本地打包/再分发 | 允许 | 允许 | 允许 | 允许 |
| Share-alike | 无 | 无 | **无** | **有**（公开衍生库须 ODbL） |
| 署名 | 仅请求 | 请求 cite + 不暗示背书 | **须**（固定措辞） | **须**（署名 + 链接） |
| 官方 API | 有（v9.4.0） | 无 | 有（JSON/XML） | 有（JSON v2，禁抓库） |
| 整库下载 | 有（XLSX/CSV/JSON） | 无 | CSV 已弃用，走 API | 有（每日导出） |
| 品牌 | 有 | 无 | 部分（企业名） | 有 |
| 成分表 | 有 | 综述级 | 有 | 有 |
| 单份剂量 | **有** | 无（按生命阶段推荐量） | **有** | 无 |
| 剂型 | **有** | 无 | **有** | 无 |
| 适用人群 | **有**（targetGroups） | 按生命阶段 | **有**（population_type） | 无 |
| 中文 | 无 | 无（英/西） | 无（英/法） | 部分（`product_name_zh`） |

## 3. 接入形态分析

两条路线的取舍：

**构建期静态导入**。把补剂条目在构建期写入资产，随 App 打包。优点是**离线可用、零网络依赖**、字段可在导入时校验、体积可控、许可风险最低（DSLD 的 CC0 与 LNHPD 的 OGL 都允许打包与再分发）。缺点是需要人工或半自动地筛选与汉化，覆盖范围受整理投入限制。

**运行时按条码/名称查询**。命中即返回并缓存。优点是**覆盖极广**（DSLD 21 万条 + OFF 480 万条），且与既有 `FoodLookupService` 的条码链路**同构，改造成本最低**。缺点是依赖联网、结果**不可预校验**（用户扫到的是什么就以什么回答）、受 API 限流与可用性影响。

**推荐：静态导入为主、运行时条码为辅的混合方案。**

理由有三。其一，项目在 `docs/ROADMAP.md` §10 已确立「离线优先」为贯穿约束——静态知识走构建期导入、App 内零网络依赖，动态数据才走运行时且必须可降级；补剂成分与剂量属**低频变化的知识**，天然适合静态。其二，静态路线的许可风险最低，DSLD（CC0）与 LNHPD（OGL）均可放心打包与再分发，而 ODbL 的 share-alike 会在「公开再分发衍生库」时产生义务，作为**运行时单条查询**（项目当前做法）则不构成衍生库公开使用，恰好规避。其三，运行时路线可直接复用现有 `FoodLookupService` 的降级范式（开关关闭不联网、失败回落本地、不抛异常），边际成本低，可作为静态库的补充。

具体分工：**常见补剂**（肌酸、乳清蛋白、维生素 D、鱼油、咖啡因、复合维生素等）走静态导入，来源以 DSLD（CC0）+ ODS Fact Sheets + LNHPD 为准，条目化改写并标注 `license`；**带包装的商品件**走运行时条码查询，优先复用 OFF（已有链路），必要时按 DSLD 的 `search-filter` 条码过滤补充英文标签字段。

## 4. 字段覆盖与模型复用

### 4.1 六类字段可得性

| 字段 | 最佳来源 | 可得性 | 备注 |
|---|---|---|---|
| 品牌 | DSLD `brandName` / OFF `brands` | 高 | LNHPD 提供企业名而非消费品牌 |
| 产品名 | DSLD `fullName` / LNHPD `product_name` | 高 | OFF 提供 `product_name_zh` |
| 成分表 | DSLD `ingredientRows[]` / LNHPD 成分接口 | 高 | DSLD 分「膳食成分」与「其他成分」 |
| 单份剂量 | DSLD `quantity[]` / LNHPD 剂量接口 | 高（英文源） | OFF 无此项 |
| 剂型 | DSLD `physicalState` / LNHPD `dosage_form` | 高 | OFF 无此项 |
| 适用人群 | DSLD `targetGroups` / LNHPD `population_type_desc` | 高 | ODS 仅有按生命阶段推荐量 |

结论：**商品级六类字段的权威来源是 DSLD 与 LNHPD**；ODS Fact Sheets 提供营养素的科学综述，用作成分安全与相互作用的知识底稿；OFF 只覆盖条码与中文品名，不覆盖剂量与剂型。

### 4.2 中文覆盖

四个源**均无完全中文覆盖**。DSLD、ODS、LNHPD 为英文（LNHPD 另有法语），OFF 仅有部分 `product_name_zh`。因此面向中文用户，补剂条目需要**自行汉化**：常见补剂的品名、成分与人群术语做中文映射，或在条目化改写时直接译为中文并保留英文原名与源链接。这是静态导入路线必须承担的整理成本，也是其体积与质量可控的代价。

### 4.3 与 `FoodCatalog` 模型的复用性

**结论：不能直接复用 `FoodCatalog`。**

`FoodCatalog`（`lib/models/diet.dart`）的字段是 `name / caloriesPer100g / proteinPer100g / fatPer100g / carbsPer100g / category` —— 一个**按每 100 g 计的三大营养素模型**，服务的是食物热量记账。补剂与之有三点根本差异：其一，补剂的关注量是**每份的功能成分剂量**（如肌酸 3-5 g/日、维生素 D IU），而非每 100 g 的宏量营养素；其二，补剂有**剂型与适用人群**维度，`FoodCatalog` 完全没有；其三，补剂的安全提示（禁忌、相互作用、人群限制）属于**文本知识**，`FoodCatalog` 无承载位。

两条可行路径：

**静态路线复用 `EvidenceEntry`**。补剂条目与 P6-A 用药安全条目同构——都是「场景 + 结构化正文 + 出处 + 许可」的可检索文本知识。新增 `domain='补剂'`，复用 `EvidenceEntry` 与 `import_knowledge.py` 管线、`KnowledgeIndex` 检索与 `search_supplement` / `lookup_supplement` 工具三处登记，**零新模型**，与现有架构完全一致。这是推荐路径。

**运行时路线新增轻量模型**。若走条码查询，需新增 `SupplementCatalog`（条码、品名、品牌、剂型、成分与剂量列表、适用人群、安全提示、出处、许可）。不复用 `FoodCatalog`，因其字段语义不匹配；但可仿照 `FoodLookupService` 的降级与缓存范式。

## 5. 内容边界：功效宣称合规

补剂的功效宣称受《广告法》与《食品安全法》双重管制，约束强度与 P5 疾病—运动库的「禁止证据越级」同级。

**《广告法》第十八条**规定保健食品广告不得含有「表示功效、安全性的断言或者保证」「涉及疾病预防、治疗功能」「声称或者暗示广告商品为保障健康所必需」「与药品、其他保健食品进行比较」「利用广告代言人作推荐、证明」等内容，且「保健食品广告应当显著标明"本品不能代替药物"」；**第十七条**进一步规定「除医疗、药品、医疗器械广告外，禁止其他任何广告涉及疾病治疗功能」（[广告法](https://www.gov.cn/guoqing/2021-10/29/content_5647620.htm)）。配套的《药品、医疗器械、保健食品、特殊医学用途配方食品广告审查管理暂行办法》要求标注「保健食品不是药物，不能代替药物治疗疾病」，并显著标明保健食品标志与适宜/不适宜人群（[暂行办法](https://www.gov.cn/zhengce/2019-12/27/content_5723743.htm)）。

**《食品安全法》第七十八条**规定保健食品标签说明书「不得涉及疾病预防、治疗功能」，须「载明适宜人群、不适宜人群、功效成分或者标志性成分及其含量等，并声明"本品不能代替药物"」；**第七十九条**要求保健食品广告同样声明「本品不能代替药物」并经审查批准（[食品安全法](https://www.gov.cn/zhengce/2015-04/25/content_2853643.htm)）。标签警示语的具体规格由《保健食品标注警示用语指南》规定：警示用语区面积不小于所在面的 20%，黑体印刷，内容为「保健食品不是药物，不能代替药物治疗疾病。」（[警示用语指南](https://www.samr.gov.cn/zt/ndzt/2019n/bjspjsqjxcjwljxyjsckpxc/zcfg/art/2023/art_fdb7d9ff30a7467eab4a2da27e697cf6.html)）。

值得注意的时间点：新《食品标识监督管理办法》（市场监管总局令第 100 号）自 **2027-03-16** 起施行，届时废止原《保健食品标识规定》；在此之前，现行依据仍为原规定与上述警示用语指南（[标识办法](https://www.gov.cn/gongbao/2025/issue_12006/202504/content_7021456.html)）。中国官方的特殊食品信息查询平台提供按批准文号/企业名称的**逐条公开查询**，据官方答复未提供批量数据下载接口，故不能作为数据源（[查询平台](http://ypzsx.gsxt.gov.cn/specialfood/)、[总局答复](https://www.samr.gov.cn/zw/zfxxgk/fdzdgknr/tssps/art/2023/art_903c730481d8439fbb070b46e85e69c8.html)）。

### 5.1 落地的硬约束（写入 system prompt 与工具输出）

1. 只给成分、剂量与一般性安全提示，**不作诊断、不承诺疗效、不给个体化处方**。
2. **禁止疾病预防/治疗表述**：不得出现「治疗/防治/缓解/改善某某病」这类把补剂与疾病疗效直接挂钩的措辞（与 P5「禁止证据越级」同级）。
3. 涉及保健食品时，必带「保健食品不是药物，不能代替药物治疗疾病」或等效免责。
4. 必列**适宜人群与不适宜人群**（对准《食品安全法》第七十八条）。
5. **强制出处**：每条带 `source / url / license`；许可存疑的条目不入库。
6. 药物相互作用、特殊人群（孕产、哺乳、儿童、老年、慢病）只给「咨询医师或药师」，不给剂量结论。
7. **未命中的处理**：如实说明本地库无依据，**绝不编造**成分、剂量或规定。

### 5.2 建议的免责话术

> 以上为膳食补充剂的成分与剂量等一般性信息，不构成用药建议、医疗建议或疗效承诺，不能替代医生、药师或注册营养师的专业判断。保健食品不是药物，不能代替药物治疗疾病。孕妇、哺乳期、儿童、老年人及慢性病患者在服用任何补充剂前，请咨询专业医务人员。具体请以产品说明书与标签为准。

## 6. 结论与建议

**许可边界（Q1）**：四个源全部允许商用与本地打包再分发。DSLD 为 CC0（署名仅请求，最宽松），ODS Fact Sheets 为公共领域（请求 cite 且不暗示背书），LNHPD 为 OGL-Canada（须固定措辞署名，无 share-alike），Open Food Facts 为 ODbL（须署名，且**公开再分发衍生库须以 ODbL 发布**）。因此作为**运行时单条查询**使用 OFF 不触发 share-alike；若把 OFF 数据**打包进 App 资产**，则须评估是否构成公开衍生库并履行 ODbL 义务，建议**避免把 OFF 全量或实质部分打包**。

**接入形态（Q2）**：推荐**静态导入为主、运行时条码为辅**的混合方案。常见补剂走静态导入（DSLD / ODS / LNHPD 为源，`domain='补剂'` 的 `EvidenceEntry`），商品件走运行时条码查询（复用 OFF 链路，必要时接 DSLD 条码过滤）。

**字段覆盖（Q3）**：六类字段的权威来源是 DSLD 与 LNHPD；OFF 只覆盖条码与部分中文品名；四个源均无完整中文，需自行汉化。`FoodCatalog` 是每 100 g 宏量营养模型，**不能直接复用**；静态路线应复用 `EvidenceEntry`，运行时路线需新增轻量模型。

**内容边界（Q4）**：功效宣称受《广告法》第十七/十八条与《食品安全法》第七十八/七十九条管制，落地的硬约束与免责话术见 §5，强度与 P5 疾病—运动库的「禁止证据越级」持平。

**对 P6-C 的落地建议**：优先执行 ROADMAP §3.3 的**静态导入路线**——把肌酸、乳清蛋白、维生素 D、鱼油、咖啡因、复合维生素等常见补剂整理为 `domain='补剂'` 的 `EvidenceEntry`，来源标注 DSLD（CC0）/ ODS / LNHPD（OGL），新增 `lookup_supplement(query)` 工具，并把现有营养域仅 2 条补剂条目扩充到可用量级（当前营养域 9 条证据中，仅「肌酸补充」「咖啡因与运动表现」属补剂）。运行时条码路线作为可选的第二步，复用 `FoodLookupService` 的同构范式。

## 7. 风险与未决项

**资产体积**。补剂库若走静态导入，`assets/data/evidence_kb.json` 会继续增大（当前已含循证 84 / 用药安全 64 条）。P6-C 需同步评估是否按域拆分资产文件，避免单文件膨胀影响加载与检索内存占用。

**中文映射质量**。四源均无完整中文，汉化质量直接决定可用性；成分术语存在「同物异名」（如维生素 B1 / 硫胺素），需在导入期建立映射表并校验，避免同一成分多条并存。

**运行时结果不可预校验**。条码查询返回的是实时数据，可能命中未审核条目；须在输出侧强制附加 §5.2 免责话术与出处，并遵循 OFF「不得用于医疗目的」的条款。

**数据时效**。LNHPD 含已停用产品（以 `status` 区分），DSLD 含已下市标签（off market）；静态导入时应只取在售/已许可条目，避免把下市信息当作现售推荐。

**未决项**。LNHPD 的「已许可产品」精确总数因接口响应过大未能取得（[未取得]）；若 P6-C 需要规模评估，可在网络稳定时单独调用 `ProductLicence` 接口读取 `metadata.pagination.total`。

## 8. 来源清单

- NIH DSLD API Guide：https://dsld.od.nih.gov/api-guide
- NIH DSLD Swagger API：https://dsldapi.od.nih.gov/
- NIH DSLD Release History：https://dsld.od.nih.gov/release-history
- NIH ODS Fact Sheets 目录：https://ods.od.nih.gov/factsheets/list-VitaminsMinerals/
- NIH ODS 版权声明（ODS Update，公共领域）：https://ods.od.nih.gov/pubs/odsupdate/Spring2015.pdf
- NIH 网站政策：https://www.nih.gov/web-policies-notices
- Health Canada LNHPD 数据集页：https://open.canada.ca/data/en/dataset/ef546c83-43a8-4404-943e-ab324164eeb3
- Open Government Licence – Canada：https://open.canada.ca/en/open-government-licence-canada
- LNHPD API 文档：https://health-products.canada.ca/api/documentation/lnhpd-documentation-fr.html
- LNHPD 旧数据提取说明与字段：https://www.canada.ca/en/health-canada/services/drugs-health-products/natural-non-prescription/applications-submissions/product-licensing/licensed-natural-health-product-database-data-extract.html
- Open Food Facts Data：https://world.openfoodfacts.org/data
- Open Food Facts Terms of Use：https://world.openfoodfacts.org/terms-of-use
- Open Database License (ODbL) 1.0：https://opendatacommons.org/licenses/odbl/1-0/
- 中华人民共和国广告法：https://www.gov.cn/guoqing/2021-10/29/content_5647620.htm
- 药品、医疗器械、保健食品、特殊医学用途配方食品广告审查管理暂行办法：https://www.gov.cn/zhengce/2019-12/27/content_5723743.htm
- 中华人民共和国食品安全法：https://www.gov.cn/zhengce/2015-04/25/content_2853643.htm
- 保健食品标注警示用语指南：https://www.samr.gov.cn/zt/ndzt/2019n/bjspjsqjxcjwljxyjsckpxc/zcfg/art/2023/art_fdb7d9ff30a7467eab4a2da27e697cf6.html
- 食品标识监督管理办法（市场监管总局令第100号）：https://www.gov.cn/gongbao/2025/issue_12006/202504/content_7021456.html
- 特殊食品信息查询平台：http://ypzsx.gsxt.gov.cn/specialfood/
- 市场监管总局对第8707号建议的答复（特殊食品信息公示范围）：https://www.samr.gov.cn/zw/zfxxgk/fdzdgknr/tssps/art/2023/art_903c730481d8439fbb070b46e85e69c8.html
