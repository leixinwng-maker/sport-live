# -*- coding: utf-8 -*-
"""P4/P5 知识库导入脚本（构建期一次性运行）

读取 scripts/knowledge_sources/ 下的种子素材，校验并合并为
assets/data/evidence_kb.json，供 App 启动时离线加载进本地智脑 RAG。

用法：
    python scripts/import_knowledge.py

原则：
- 静态知识走构建期导入，App 内零网络依赖；
- 正文为改写/摘要而非原文照搬，逐条带 source/url/license；
- MET 值为客观测量数据，禁止改写；
- 疾病—运动为两层证据结构：第一层（疾病 → 运动类别 + 剂量）走 evidence，
  第二层（运动类别 → 动作示例 + 禁忌）走 conditionExercises，严禁证据越级。
- 动作库**只取数据、剥离媒体**（不含图片/动图等二进制字段）。

素材许可：
- evidence_seed.json：美国政府作品(公有领域) / WHO CC BY-NC-SA 3.0 IGO /
  中国疾控官方公开(全书版权归人卫社，仅条目化改写) / ISSN / 中医古籍
- met_seed.json：Compendium of Physical Activities 2024（免费商用，须署名，禁改 MET 值）
- exercise_seed.json：Free Exercise DB（Unlicense，公共领域）结构参考，中文名与要点为自撰改写
- condition_exercise_seed.json：公开身体活动指南要点改写
  （WHO 2020 / 美国 PAG 2018 / 中国人群身体活动指南 2021 / ACSM），未逐字复制
- otc_safety_seed.json：国家卫健委《新冠病毒感染者居家治疗常用药参考表》
  （政府公开发布，官方媒体刊载全文）与 NMPA《第二批国家非处方药化学药品使用
  说明书目录》（官方公开发布）要点条目化改写，未复制整篇说明书
- supplement_seed.json：NIH ODS 消费者事实清单 / FDA 消费者资讯（美国政府作品，
  公共领域）与 ISSN 立场声明、EFSA 科学意见（开放获取）要点条目化改写，
  未照搬原文；只给成分、剂量与一般性安全提示，不作诊断、不承诺疗效
- ontology_exmo.json：EXMO（Exercise Medicine Ontology，CC BY 4.0）EXM 命名空间术语，
  仅搬运原始 label/definition/altLabel，未翻译、未改写
- ontology_rehabo.json：RehabO（The Rehabilitation Ontology，CC0 1.0）术语，
  仅搬运原始 label/definition/altLabel，未翻译、未改写
- exercise_catalog_seed.json：Exercises Dataset（数据部分 MIT）+ Free Exercise DB
  （Unlicense）；**仅取数据、剥离全部图片/动图等媒体字段**，媒体版权归原作者不收录
- dataset_registry_seed.json：各开放数据源/本体/知识图谱的**元数据登记**
  （名称、规模、许可、获取方式），不含任何正文数据；未核实许可者仅登记题录
"""
import io
import json
import os
import sys
from datetime import datetime

# 项目根目录 = 本脚本上级目录
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, 'scripts', 'knowledge_sources')
OUT_PATH = os.path.join(ROOT, 'assets', 'data', 'evidence_kb.json')
# 开放动作库（2062 条）体量较大，独立成文件，App 侧按需加载，避免拖慢启动
OUT_CATALOG_PATH = os.path.join(ROOT, 'assets', 'data', 'exercise_catalog.json')

EVIDENCE_REQUIRED = [
    'id', 'domain', 'condition', 'topic', 'recommendation',
    'evidenceLevel', 'source', 'url', 'license',
]
EVIDENCE_LEVELS = ('指南推荐', '系统评价', 'RCT')

# 用药安全条目：性质为「官方文件规定」与「说明书范本」，不适配临床证据三级分级。
# 故独立设白名单：指南＝官方文件（如卫健委参考表）；专家＝NMPA 说明书范本。
OTC_SAFETY_DOMAIN = '用药安全'
OTC_SAFETY_LEVELS = ('指南', '专家')

# 补剂条目：性质为「官方摄入参考与安全提示」与「专业学会共识」，同样不适配临床证据三级分级。
# 独立设白名单：指南＝政府/官方文件（NIH ODS、FDA）；专家＝专业学会共识（ISSN、EFSA）。
SUPPLEMENT_DOMAIN = '补剂'
SUPPLEMENT_LEVELS = ('指南', '专家')

# 第二层：运动类别白名单（与 ExerciseExampleEntry.category 对应）
CONDITION_CATEGORIES = ('有氧', '抗阻', '柔韧', '平衡', '身心')
CONDITION_REQUIRED = [
    'category', 'examples', 'cues', 'cautions', 'source', 'url', 'license',
]

# 本体术语（EXMO / RehabO）：字段自上游本体文件搬运，禁止改写或翻译
ONTOLOGY_REQUIRED = ['id', 'ontology', 'label']
ONTOLOGY_IDS = ('EXMO', 'RehabO')
# 各本体的 CURIE 前缀，用于校验术语归属（EXMO 用 EXM: ，RehabO 用 REHABO:）
ONTOLOGY_ID_PREFIX = {'EXMO': 'EXM:', 'RehabO': 'REHABO:'}

# 开放数据与本体登记表：仅元数据与获取指引，不含正文
REGISTRY_REQUIRED = ['id', 'name', 'kind', 'domain', 'license', 'access', 'note']
REGISTRY_KINDS = ('本体', '知识图谱', '数据集', '语料', 'API', '食品数据库', '开源软件')
REGISTRY_ACCESS = ('已接入', '可接入', '登记题录')
# 「已接入/可接入」条目必须给出可直达地址；「登记题录」允许 url 留空（尚无可核实入口）
REGISTRY_URL_REQUIRED_ACCESS = ('已接入', '可接入')

# 动作库目录（Exercises Dataset + Free Exercise DB 归并）
CATALOG_REQUIRED = ['id', 'name', 'target', 'bodyPart', 'equipment', 'steps',
                    'lang', 'source', 'license']
CATALOG_LANGS = ('zh', 'en')
CATALOG_MEDIA_KEYS = ('images', 'image', 'gif', 'gif_url', 'media_id', 'attribution',
                      'instruction_steps', 'image_url', 'video_url')


def load_json(path):
    with io.open(path, encoding='utf-8') as f:
        return json.load(f)


def validate_evidence(entries):
    problems = []
    seen = set()
    for i, e in enumerate(entries):
        for k in EVIDENCE_REQUIRED:
            if not str(e.get(k, '')).strip():
                problems.append('evidence[%d] id=%s 缺少字段 %s' % (i, e.get('id'), k))
        eid = e.get('id', '')
        if eid in seen:
            problems.append('evidence 重复 id: %s' % eid)
        seen.add(eid)
        if e.get('evidenceLevel') not in EVIDENCE_LEVELS:
            problems.append('evidence id=%s 证据等级非法: %s' % (eid, e.get('evidenceLevel')))
    return problems


def validate_otc_safety(entries, evidence_ids):
    """用药安全校验：9 必填 + domain 固定 + 独立等级白名单 + 跨数组 id 不重复。"""
    problems = []
    seen = set()
    for i, e in enumerate(entries):
        for k in EVIDENCE_REQUIRED:
            if not str(e.get(k, '')).strip():
                problems.append('otcSafety[%d] id=%s 缺少字段 %s' % (i, e.get('id'), k))
        eid = e.get('id', '')
        if eid in seen:
            problems.append('otcSafety 重复 id: %s' % eid)
        if eid in evidence_ids:
            problems.append('otcSafety id 与 evidence 冲突: %s' % eid)
        seen.add(eid)
        if e.get('domain') != OTC_SAFETY_DOMAIN:
            problems.append('otcSafety id=%s domain 必须为「%s」，实际: %s'
                            % (eid, OTC_SAFETY_DOMAIN, e.get('domain')))
        if e.get('evidenceLevel') not in OTC_SAFETY_LEVELS:
            problems.append('otcSafety id=%s 证据等级非法: %s（允许 %s）'
                            % (eid, e.get('evidenceLevel'), '/'.join(OTC_SAFETY_LEVELS)))
    return problems


def validate_supplements(entries, reserved_ids):
    """补剂校验：9 必填 + domain 固定 + 独立等级白名单 + 与既有数组 id 不重复。"""
    problems = []
    seen = set()
    for i, e in enumerate(entries):
        for k in EVIDENCE_REQUIRED:
            if not str(e.get(k, '')).strip():
                problems.append('supplements[%d] id=%s 缺少字段 %s' % (i, e.get('id'), k))
        eid = e.get('id', '')
        if eid in seen:
            problems.append('supplements 重复 id: %s' % eid)
        if eid in reserved_ids:
            problems.append('supplements id 与 evidence/otcSafety 冲突: %s' % eid)
        seen.add(eid)
        if e.get('domain') != SUPPLEMENT_DOMAIN:
            problems.append('supplements id=%s domain 必须为「%s」，实际: %s'
                            % (eid, SUPPLEMENT_DOMAIN, e.get('domain')))
        if e.get('evidenceLevel') not in SUPPLEMENT_LEVELS:
            problems.append('supplements id=%s 证据等级非法: %s（允许 %s）'
                            % (eid, e.get('evidenceLevel'), '/'.join(SUPPLEMENT_LEVELS)))
    return problems


def validate_met(rows):
    problems = []
    for i, m in enumerate(rows):
        if not str(m.get('activity', '')).strip():
            problems.append('met[%d] 缺少 activity' % i)
        met = m.get('met')
        if not isinstance(met, (int, float)) or met <= 0:
            problems.append('met[%d] %s 的 MET 值非法: %r' % (i, m.get('activity'), met))
    return problems


def validate_exercises(rows):
    problems = []
    seen = set()
    for i, x in enumerate(rows):
        name = str(x.get('name', '')).strip()
        if not name:
            problems.append('exercise[%d] 缺少 name' % i)
        elif name in seen:
            problems.append('exercise 重复 name: %s' % name)
        seen.add(name)
        if not str(x.get('muscle', '')).strip():
            problems.append('exercise[%d] %s 缺少 muscle' % (i, x.get('name')))
        # 构建期剥离媒体：动作库不得携带任何媒体字段
        for media_key in ('images', 'image', 'gif', 'gif_url', 'media_id', 'attribution'):
            if media_key in x:
                problems.append('exercise[%d] %s 含媒体字段 %s（须剥离）' % (i, name, media_key))
    return problems


def validate_condition_exercises(rows, exercise_names):
    """第二层校验：类别白名单 + 示例非空 + 禁忌非空 + 示例动作必须命中动作库。"""
    problems = []
    for i, r in enumerate(rows):
        for k in CONDITION_REQUIRED:
            if not str(r.get(k, '')).strip():
                problems.append('conditionExercises[%d] 缺少字段 %s' % (i, k))
        cat = r.get('category', '')
        if cat and cat not in CONDITION_CATEGORIES:
            problems.append('conditionExercises[%d] 类别非法: %s' % (i, cat))
        examples = r.get('examples')
        if not isinstance(examples, list) or not examples:
            problems.append('conditionExercises[%d] %s 的 examples 必须为非空列表' % (i, cat))
        else:
            for name in examples:
                if name not in exercise_names:
                    problems.append(
                        'conditionExercises[%d] %s 示例动作不在本地动作库中: %s' % (i, cat, name))
        cautions = r.get('cautions')
        if isinstance(cautions, list) and not cautions:
            problems.append('conditionExercises[%d] %s 的 cautions 不能为空列表' % (i, cat))
    return problems


def tag_ontology(terms, ontology_id):
    """为上游本体术语打上归属标记（上游文件本身不含该字段）。"""
    out = []
    for t in terms:
        row = dict(t)
        row['ontology'] = ontology_id
        out.append(row)
    return out


def validate_ontology(terms):
    """本体术语校验：3 必填 + ontology 白名单 + id 唯一 + id 前缀与本体一致。"""
    problems = []
    seen = set()
    for i, t in enumerate(terms):
        for k in ONTOLOGY_REQUIRED:
            if not str(t.get(k, '')).strip():
                problems.append('ontologies[%d] id=%s 缺少字段 %s' % (i, t.get('id'), k))
        oid = t.get('ontology', '')
        tid = t.get('id', '')
        if oid and oid not in ONTOLOGY_IDS:
            problems.append('ontologies[%d] id=%s ontology 非法: %s' % (i, tid, oid))
        if tid in seen:
            problems.append('ontologies 重复 id: %s' % tid)
        seen.add(tid)
        prefix = ONTOLOGY_ID_PREFIX.get(oid)
        if prefix and tid and not tid.startswith(prefix):
            problems.append('ontologies id=%s 前缀与本体 %s 不符（应以 %s 开头）'
                            % (tid, oid, prefix))
    return problems


def validate_registry(entries):
    """登记表校验：必填 + kind/access 白名单 + id 唯一 + 已接入/可接入必须有 url。"""
    problems = []
    seen = set()
    for i, r in enumerate(entries):
        for k in REGISTRY_REQUIRED:
            if not str(r.get(k, '')).strip():
                problems.append('datasetRegistry[%d] id=%s 缺少字段 %s' % (i, r.get('id'), k))
        eid = r.get('id', '')
        if eid in seen:
            problems.append('datasetRegistry 重复 id: %s' % eid)
        seen.add(eid)
        kind = r.get('kind', '')
        if kind and kind not in REGISTRY_KINDS:
            problems.append('datasetRegistry id=%s kind 非法: %s' % (eid, kind))
        access = r.get('access', '')
        if access and access not in REGISTRY_ACCESS:
            problems.append('datasetRegistry id=%s access 非法: %s' % (eid, access))
        if access in REGISTRY_URL_REQUIRED_ACCESS and not str(r.get('url', '')).strip():
            problems.append('datasetRegistry id=%s 状态为「%s」但缺少 url' % (eid, access))
    return problems


def validate_catalog(rows):
    """开放动作库校验：9 必填 + id 唯一 + lang 白名单 + 构建期剥离媒体字段。"""
    problems = []
    seen = set()
    for i, x in enumerate(rows):
        for k in CATALOG_REQUIRED:
            if not str(x.get(k, '')).strip():
                problems.append('exerciseCatalog[%d] id=%s 缺少字段 %s' % (i, x.get('id'), k))
        cid = x.get('id', '')
        if cid in seen:
            problems.append('exerciseCatalog 重复 id: %s' % cid)
        seen.add(cid)
        if x.get('lang') not in CATALOG_LANGS:
            problems.append('exerciseCatalog id=%s lang 非法: %s' % (cid, x.get('lang')))
        for media_key in CATALOG_MEDIA_KEYS:
            if media_key in x:
                problems.append('exerciseCatalog id=%s 含媒体字段 %s（须剥离）' % (cid, media_key))
    return problems


def main():
    ev = load_json(os.path.join(SRC_DIR, 'evidence_seed.json'))
    met = load_json(os.path.join(SRC_DIR, 'met_seed.json'))
    ex = load_json(os.path.join(SRC_DIR, 'exercise_seed.json'))
    ce = load_json(os.path.join(SRC_DIR, 'condition_exercise_seed.json'))
    otc = load_json(os.path.join(SRC_DIR, 'otc_safety_seed.json'))
    supp = load_json(os.path.join(SRC_DIR, 'supplement_seed.json'))
    onto_exmo = load_json(os.path.join(SRC_DIR, 'ontology_exmo.json'))
    onto_rehabo = load_json(os.path.join(SRC_DIR, 'ontology_rehabo.json'))
    catalog = load_json(os.path.join(SRC_DIR, 'exercise_catalog_seed.json'))
    registry = load_json(os.path.join(SRC_DIR, 'dataset_registry_seed.json'))

    # 第一层（疾病 → 类别 + 剂量）与既有证据条目同构，统一并入 evidence
    evidence = list(ev['entries']) + list(ce.get('entries', []))
    met_rows = met['met']
    exercises = ex['exercises']
    condition_exercises = ce['conditionExercises']
    otc_safety = list(otc.get('entries', []))
    supplements = list(supp.get('entries', []))
    # 本体术语：上游不含 ontology 归属字段，构建期统一打标后归并
    ontologies = (tag_ontology(onto_exmo.get('terms', []), 'EXMO')
                  + tag_ontology(onto_rehabo.get('terms', []), 'RehabO'))
    catalog_rows = catalog['exercises']
    registry_rows = registry['entries']
    exercise_names = {x.get('name') for x in exercises}
    evidence_ids = {e.get('id') for e in evidence}

    problems = []
    problems += validate_evidence(evidence)
    problems += validate_otc_safety(otc_safety, evidence_ids)
    problems += validate_supplements(supplements, evidence_ids | {e.get('id') for e in otc_safety})
    problems += validate_met(met_rows)
    problems += validate_exercises(exercises)
    problems += validate_condition_exercises(condition_exercises, exercise_names)
    problems += validate_ontology(ontologies)
    problems += validate_registry(registry_rows)
    problems += validate_catalog(catalog_rows)

    if problems:
        sys.stderr.write('校验失败，共 %d 个问题：\n' % len(problems))
        for p in problems:
            sys.stderr.write('  - %s\n' % p)
        sys.exit(1)

    sources = [
        {'name': '美国身体活动指南第2版（2018）', 'url': 'https://health.gov/our-work/nutrition-physical-activity/physical-activity-guidelines',
         'license': '美国政府作品，公有领域'},
        {'name': 'WHO 2020 身体活动与久坐行为指南', 'url': 'https://www.who.int/publications/i/item/9789240015128',
         'license': 'CC BY-NC-SA 3.0 IGO'},
        {'name': '中国《人群身体活动指南(2021)》', 'url': 'https://www.chinacdc.cn/',
         'license': '官方免费公开；全书版权归人民卫生出版社，仅条目化改写'},
        {'name': 'ACSM 运动测试与运动处方指南', 'url': 'https://www.acsm.org/',
         'license': '引用要点，未逐字复制；仅内部知识库使用'},
        {'name': '《中国居民膳食指南(2022)》', 'url': 'http://dg.cnsoc.org/',
         'license': '宝塔/准则免费公开；全书版权归人民卫生出版社'},
        {'name': 'Compendium of Physical Activities 2024', 'url': 'https://pacompendium.com/',
         'license': '免费商用，须署名，禁改 MET 值'},
        {'name': 'Free Exercise DB', 'url': 'https://github.com/yuhonas/free-exercise-db',
         'license': 'Unlicense（公共领域）；仅取动作分类结构，中文名与要点为自撰改写，媒体不收录'},
        {'name': 'hasaneyldrm/exercises-dataset', 'url': 'https://github.com/hasaneyldrm/exercises-dataset',
         'license': '数据部分 MIT（依据仓库 NOTICE/README 判定）；仅取数据（中文说明/肌群/器械），不取图片与动图（媒体版权为 Gym visual ©，未收录）'},
        {'name': 'Longhaul Exercises', 'url': 'https://github.com/longhaul-fitness/exercises',
         'license': 'MIT（Copyright (c) 2023 Longhaul Fitness）；仅取力量/拉伸/有氧动作数据（名称/肌群/步骤），不含任何媒体文件'},
        {'name': 'EXMO（Exercise Medicine Ontology）', 'url': 'https://github.com/DarkKnight0-0/exmo',
         'license': 'CC BY 4.0（署名）；内置 EXM 命名空间术语摘录，仅搬运原始 label/definition，未翻译改写'},
        {'name': 'RehabO（The Rehabilitation Ontology）', 'url': 'https://github.com/mcwdsi/rehabo',
         'license': 'CC0 1.0（公共领域贡献）；内置术语摘录，仅搬运原始 label/definition，未翻译改写'},
        {'name': 'DOID（Human Disease Ontology）', 'url': 'https://disease-ontology.org/',
         'license': 'CC0（公共领域）；仅用于疾病名称规范化对齐'},
        {'name': 'ISSN Position Stands', 'url': 'https://jissn.biomedcentral.com/',
         'license': 'CC BY 4.0（署名）'},
        {'name': '《黄帝内经》等中医典籍', 'url': 'https://www.gov.cn/',
         'license': '古籍（公有领域），译文为自撰改写'},
        {'name': '国家卫健委《新冠病毒感染者居家治疗常用药参考表》（2022-12-08）',
         'url': 'https://news.cctv.com/2022/12/16/ARTIQruRkEJ64gUJm88HnvLk221216.shtml',
         'license': '政府公开发布；经官方媒体刊载全文，仅条目化改写'},
        {'name': '国家药监局《第二批国家非处方药化学药品使用说明书目录》',
         'url': 'https://www.nmpa.gov.cn/wwwroot/otc2h/otc2xyml.htm',
         'license': '官方公开发布；仅条目化改写，未复制整篇说明书'},
        {'name': '美国国立卫生研究院膳食补充剂办公室（NIH ODS）膳食补充剂消费者事实清单',
         'url': 'https://ods.od.nih.gov/factsheets/list-all/',
         'license': '美国政府作品，属公共领域（17 U.S.C. §105）；仅条目化改写，未照搬原文'},
        {'name': '美国食品药品监督管理局（FDA）消费者资讯：多少咖啡因算过量',
         'url': 'https://www.fda.gov/consumers/consumer-updates/spilling-beans-how-much-caffeine-too-much',
         'license': '美国政府作品，属公共领域（17 U.S.C. §105）；仅条目化改写，未照搬原文'},
        {'name': '欧洲食品安全局（EFSA）关于咖啡因安全性的科学意见（2015）',
         'url': 'https://efsa.onlinelibrary.wiley.com/doi/10.2903/j.efsa.2015.4102',
         'license': '开放获取；仅条目化改写，标注出处'},
        {'name': 'Europe PMC REST API（循证文献联网检索主源）',
         'url': 'https://europepmc.org/',
         'license': 'EMBL-EBI 免费开放（含商业用途）；仅取题录元数据，解析时丢弃正文，不落摘要'},
        {'name': 'OpenAlex 学术图谱 API（补源，CC0）',
         'url': 'https://openalex.org/',
         'license': 'CC0 1.0 公共领域；仅取题录元数据；非商用（CC BY-NC）许可条目直接丢弃'},
        {'name': 'Crossref REST API（兜底源）',
         'url': 'https://www.crossref.org/',
         'license': '官方免费开放；仅取题录元数据与许可声明，不取正文'},
        {'name': 'Semantic Scholar Graph API（兜底源）',
         'url': 'https://www.semanticscholar.org/',
         'license': 'Allen 研究所免费开放（无 Key 限流）；接口不返回许可串，条目一律退化为纯著录题录，不转载正文'},
        {'name': '肌筋膜链（含螺旋线）系统评价',
         'url': 'https://pubmed.ncbi.nlm.nih.gov/26755480/',
         'license': '摘要经 PubMed 免费公开；仅转述结论，未复制原文'},
    ]

    out = {
        'version': '1.6.0',
        'generatedAt': datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
        'description': '问道循证知识底座：指南/系统评价证据条目 + MET 强度表 + 动作库 + 疾病—运动两层关联 + 家庭用药安全条目 + 常见补剂常识条目 + 运动医学/康复本体术语 + 开放数据与本体登记表 + 开放文献检索 API 登记。构建期导入，App 内零网络依赖。',
        'sources': sources,
        'evidence': evidence,
        'otcSafety': otc_safety,
        'supplements': supplements,
        'met': met_rows,
        'exercises': exercises,
        'conditionExercises': condition_exercises,
        'ontologies': ontologies,
        'datasetRegistry': registry_rows,
    }

    catalog_out = {
        'version': '1.1.0',
        'generatedAt': datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
        'description': '开放动作库目录：Exercises Dataset（含自然中文说明）+ Free Exercise DB + Longhaul Exercises。构建期导入、仅取数据、剥离全部媒体字段；随 App 离线打包，按需加载。',
        'generatedFrom': catalog.get('generatedFrom', []),
        'count': len(catalog_rows),
        'exercises': catalog_rows,
    }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with io.open(OUT_PATH, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write('\n')
    with io.open(OUT_CATALOG_PATH, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(catalog_out, f, ensure_ascii=False, indent=2)
        f.write('\n')

    print('已生成 %s' % os.path.relpath(OUT_PATH, ROOT))
    print('  evidence            = %d 条' % len(evidence))
    print('  otcSafety           = %d 条' % len(otc_safety))
    print('  supplements         = %d 条' % len(supplements))
    print('  met                 = %d 条' % len(met_rows))
    print('  exercises           = %d 条' % len(exercises))
    print('  conditionExercises  = %d 条' % len(condition_exercises))
    print('  ontologies          = %d 条' % len(ontologies))
    print('  datasetRegistry     = %d 条' % len(registry_rows))
    print('已生成 %s' % os.path.relpath(OUT_CATALOG_PATH, ROOT))
    print('  exerciseCatalog     = %d 条' % len(catalog_rows))


if __name__ == '__main__':
    main()
