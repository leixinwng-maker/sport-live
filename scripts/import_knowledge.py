# -*- coding: utf-8 -*-
"""P4 知识库导入脚本（构建期一次性运行）

读取 scripts/knowledge_sources/ 下的种子素材，校验并合并为
assets/data/evidence_kb.json，供 App 启动时离线加载进本地智脑 RAG。

用法：
    python scripts/import_knowledge.py

原则：
- 静态知识走构建期导入，App 内零网络依赖；
- 正文为改写/摘要而非原文照搬，逐条带 source/url/license；
- MET 值为客观测量数据，禁止改写。

素材许可：
- evidence_seed.json：美国政府作品(公有领域) / WHO CC BY-NC-SA 3.0 IGO /
  中国疾控官方公开(全书版权归人卫社，仅条目化改写) / ISSN / 中医古籍
- met_seed.json：Compendium of Physical Activities 2024（免费商用，须署名，禁改 MET 值）
- exercise_seed.json：Free Exercise DB（Unlicense，公共领域），中文要点为自撰
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

EVIDENCE_REQUIRED = [
    'id', 'domain', 'condition', 'topic', 'recommendation',
    'evidenceLevel', 'source', 'url', 'license',
]


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
        if e.get('evidenceLevel') not in ('指南推荐', '系统评价', 'RCT'):
            problems.append('evidence id=%s 证据等级非法: %s' % (eid, e.get('evidenceLevel')))
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
    for i, x in enumerate(rows):
        if not str(x.get('name', '')).strip():
            problems.append('exercise[%d] 缺少 name' % i)
        if not str(x.get('muscle', '')).strip():
            problems.append('exercise[%d] %s 缺少 muscle' % (i, x.get('name')))
    return problems


def main():
    ev = load_json(os.path.join(SRC_DIR, 'evidence_seed.json'))
    met = load_json(os.path.join(SRC_DIR, 'met_seed.json'))
    ex = load_json(os.path.join(SRC_DIR, 'exercise_seed.json'))

    evidence = ev['entries']
    met_rows = met['met']
    exercises = ex['exercises']

    problems = []
    problems += validate_evidence(evidence)
    problems += validate_met(met_rows)
    problems += validate_exercises(exercises)

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
        {'name': '《中国居民膳食指南(2022)》', 'url': 'http://dg.cnsoc.org/',
         'license': '宝塔/准则免费公开；全书版权归人民卫生出版社'},
        {'name': 'Compendium of Physical Activities 2024', 'url': 'https://pacompendium.com/',
         'license': '免费商用，须署名，禁改 MET 值'},
        {'name': 'Free Exercise DB', 'url': 'https://github.com/yuhonas/free-exercise-db',
         'license': 'Unlicense（公共领域）'},
        {'name': 'ISSN Position Stands', 'url': 'https://jissn.biomedcentral.com/',
         'license': 'CC BY 4.0（署名）'},
        {'name': '《黄帝内经》等中医典籍', 'url': 'https://www.gov.cn/',
         'license': '古籍（公有领域），译文为自撰改写'},
    ]

    out = {
        'version': '1.0.0',
        'generatedAt': datetime.now().strftime('%Y-%m-%dT%H:%M:%S'),
        'description': '问道 P4 循证知识底座：指南/系统评价的证据条目 + MET 强度表 + 动作库。构建期导入，App 内零网络依赖。',
        'sources': sources,
        'evidence': evidence,
        'met': met_rows,
        'exercises': exercises,
    }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with io.open(OUT_PATH, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write('\n')

    print('已生成 %s' % os.path.relpath(OUT_PATH, ROOT))
    print('  evidence  = %d 条' % len(evidence))
    print('  met       = %d 条' % len(met_rows))
    print('  exercises = %d 条' % len(exercises))


if __name__ == '__main__':
    main()
