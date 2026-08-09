# -*- coding: utf-8 -*-
"""把 books/ 下的 epub/txt/md 提取为纯文本，输出到 assets/books/"""
import os, re, zipfile, shutil, html

SRC = os.path.join(os.path.dirname(__file__), '..', 'books')
DST = os.path.join(os.path.dirname(__file__), '..', 'assets', 'books')

os.makedirs(DST, exist_ok=True)

def strip_html(text):
    """剥离 HTML 标签，保留纯文本"""
    # 去掉 script/style
    text = re.sub(r'<(script|style)[^>]*>.*?</\1>', '', text, flags=re.DOTALL | re.IGNORECASE)
    # 块级标签换行
    text = re.sub(r'<(p|div|br|h[1-6]|li|tr|td)[^>]*>', '\n', text, flags=re.IGNORECASE)
    # 去掉所有标签
    text = re.sub(r'<[^>]+>', '', text)
    # HTML 实体
    text = html.unescape(text)
    # 合并多余空行
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()

def extract_epub(path):
    """从 epub 提取纯文本"""
    parts = []
    with zipfile.ZipFile(path, 'r') as zf:
        for name in sorted(zf.namelist()):
            if name.lower().endswith(('.html', '.xhtml', '.htm')):
                raw = zf.read(name).decode('utf-8', errors='ignore')
                parts.append(strip_html(raw))
    return '\n\n'.join(p for p in parts if p)

def process_file(filepath, domain):
    name = os.path.basename(filepath)
    base, ext = os.path.splitext(name)
    # 简化文件名：去掉 z-library 等冗余后缀
    clean = re.sub(r'\s*\(z-library.*?\)', '', base, flags=re.IGNORECASE)
    clean = re.sub(r'\s*--\s*.*$', '', clean)
    clean = clean.strip()
    if len(clean) > 60:
        clean = clean[:60]

    out_name = f'{domain}_{clean}.txt'
    out_path = os.path.join(DST, out_name)

    if ext.lower() == '.epub':
        text = extract_epub(filepath)
    else:
        with open(filepath, 'r', encoding='utf-8') as f:
            text = f.read()

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(text)

    size_kb = round(len(text.encode('utf-8')) / 1024, 1)
    print(f'  OK  {domain}/{name} -> {out_name} ({size_kb}KB)')

for domain in ['fitness', 'finance', 'tcm']:
    folder = os.path.join(SRC, domain)
    if not os.path.isdir(folder):
        continue
    print(f'\n=== {domain} ===')
    for name in sorted(os.listdir(folder)):
        filepath = os.path.join(folder, name)
        if not os.path.isfile(filepath):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext in ('.epub', '.txt', '.md'):
            try:
                process_file(filepath, domain)
            except Exception as e:
                print(f'  ERR {name}: {e}')

print('\nDone!')
