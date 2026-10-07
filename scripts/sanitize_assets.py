# -*- coding: utf-8 -*-
"""清洗 assets/books/ 文件名（去掉 =、空格、括号等特殊字符，避免 Windows/Web 构建问题），并同步更新 index.json"""
import os, re, json

BOOKS_DIR = os.path.join(os.path.dirname(__file__), '..', 'assets', 'books')
INDEX = os.path.join(BOOKS_DIR, 'index.json')

def sanitize(name):
    """只保留中文/字母/数字/连字符/下划线/点，其余替换为下划线，压缩连续下划线"""
    stem, dot, ext = name.rpartition('.')
    stem = re.sub(r'[^\u4e00-\u9fa5a-zA-Z0-9\-_.]', '_', stem)
    stem = re.sub(r'_+', '_', stem)
    stem = stem.strip('_')
    return f'{stem}.{ext}' if dot else stem

# 1. 重命名文件
renamed = {}
for fn in os.listdir(BOOKS_DIR):
    if fn == 'index.json':
        continue
    path = os.path.join(BOOKS_DIR, fn)
    if not os.path.isfile(path):
        continue
    new_fn = sanitize(fn)
    if new_fn != fn:
        new_path = os.path.join(BOOKS_DIR, new_fn)
        # 避免覆盖已存在文件
        if os.path.exists(new_path):
            continue
        os.rename(path, new_path)
        renamed[fn] = new_fn
        print(f'  {fn}  ->  {new_fn}')

# 2. 更新 index.json 中的 file 字段
with open(INDEX, 'r', encoding='utf-8') as f:
    data = json.load(f)
for book in data['books']:
    old = book['file']
    if old in renamed:
        book['file'] = renamed[old]
with open(INDEX, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print(f'\nRenamed {len(renamed)} files, index.json updated.')
