# -*- coding: utf-8 -*-
"""把 books/ 下的 epub/txt/md 提取为纯文本，输出到 assets/books/

版权闸门：assets/books/ 是 pubspec.yaml 声明的打包资产，其中的文本会随 APK 分发。
「不上传 GitHub」不构成豁免——.gitignore 只保护仓库，不保护发布包，分发 APK 中的
书籍全文同样构成版权法意义上的复制与发行。因此只有明确属于公有领域或允许分发的
开放许可来源，才可加入下方 ALLOWED_SOURCES 白名单；未列入者一律跳过。
"""
import os, re, zipfile, shutil, html

SRC = os.path.join(os.path.dirname(__file__), '..', 'books')
DST = os.path.join(os.path.dirname(__file__), '..', 'assets', 'books')

# 白名单（相对 books/ 的路径，如 'tcm/黄帝内经.txt'）。
# 默认留空：需逐个确认许可并显式登记后方可打包，避免现代版权书籍被无意分发。
ALLOWED_SOURCES = {
}

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

def process_file(filepath, domain, index):
    name = os.path.basename(filepath)
    base, ext = os.path.splitext(name)
    # 短文件名 {domain}_{序号}.txt：避免中文长文件名经URL编码膨胀后
    # 超出 Windows 路径长度限制（260字符）导致 web 构建失败
    out_name = f'{domain}_{index}.txt'
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
    index = 0
    for name in sorted(os.listdir(folder)):
        filepath = os.path.join(folder, name)
        if not os.path.isfile(filepath):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext in ('.epub', '.txt', '.md'):
            rel = f'{domain}/{name}'
            if rel not in ALLOWED_SOURCES:
                print(f'  SKIP {rel}：未在白名单中，跳过（版权闸门）')
                continue
            try:
                index += 1
                process_file(filepath, domain, index)
            except Exception as e:
                print(f'  ERR {name}: {e}')

print('\nDone!')
