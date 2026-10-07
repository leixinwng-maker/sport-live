# -*- coding: utf-8 -*-
"""将 assets/books/ 重命名为短文件名 {domain}_{序号}.txt，并更新 index.json。
原因：中文文件名经 URL 编码膨胀 3 倍，长名+嵌套路径超出 Windows 路径长度限制（260字符），导致 web 构建失败。"""
import os, json

BOOKS_DIR = os.path.join(os.path.dirname(__file__), '..', 'assets', 'books')
INDEX = os.path.join(BOOKS_DIR, 'index.json')

with open(INDEX, 'r', encoding='utf-8') as f:
    data = json.load(f)

books = data['books']
# 按 domain 分组计数
counters = {}
for book in books:
    domain = book['domain']
    counters[domain] = counters.get(domain, 0) + 1
    new_file = f"{domain}_{counters[domain]}.txt"
    old_file = book['file']
    if old_file != new_file:
        old_path = os.path.join(BOOKS_DIR, old_file)
        new_path = os.path.join(BOOKS_DIR, new_file)
        if os.path.exists(old_path):
            os.rename(old_path, new_path)
            print(f'  {old_file}  ->  {new_file}')
    book['file'] = new_file

with open(INDEX, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print('\nAll renamed, index.json updated.')
