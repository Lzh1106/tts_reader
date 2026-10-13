"""静态自检脚本：

1. 校验 Android 侧 XML 是否格式良好（lxml）。
2. 对每个 .dart 文件做括号配对检查（跳过注释与字符串字面量），
   用于在没有 Flutter SDK 的环境下发现明显的语法残缺。
3. 校验 import 的相对路径是否存在。
"""

import os
import re
import sys

from lxml import etree

ROOT = r"C:\Users\user\Documents\deepseek-harness\default-workspace\tts_reader"
problems = []


def check_xml():
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        for name in filenames:
            if not name.endswith(".xml"):
                continue
            path = os.path.join(dirpath, name)
            try:
                etree.parse(path)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"[XML] {os.path.relpath(path, ROOT)}: {exc}")


def strip_dart(src: str) -> str:
    """移除注释与字符串内容，保留结构字符。"""
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if ch in "'\"":
            triple = src[i : i + 3] == ch * 3
            quote = ch * 3 if triple else ch
            i += len(quote)
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src.startswith(quote, i):
                    i += len(quote)
                    break
                if not triple and src[i] == "\n":
                    break
                i += 1
            out.append('""')
            continue
        if ch == "r" and nxt in "'\"":
            # 原始字符串
            quote = nxt
            i += 2
            while i < n and src[i] != quote:
                i += 1
            i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_dart_balance():
    pairs = {")": "(", "]": "[", "}": "{"}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in {".dart_tool", "build"}]
        for name in filenames:
            if not name.endswith(".dart"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as handle:
                src = handle.read()
            code = strip_dart(src)
            stack = []
            line = 1
            for ch in code:
                if ch == "\n":
                    line += 1
                elif ch in "([{":
                    stack.append((ch, line))
                elif ch in ")]}":
                    if not stack:
                        problems.append(f"[DART] {rel}:{line} 多余的 '{ch}'")
                        break
                    opening, opened_at = stack.pop()
                    if opening != pairs[ch]:
                        problems.append(
                            f"[DART] {rel}:{line} '{ch}' 与第 {opened_at} 行的 '{opening}' 不匹配"
                        )
                        break
            else:
                if stack:
                    opening, opened_at = stack[-1]
                    problems.append(
                        f"[DART] {rel}: 第 {opened_at} 行的 '{opening}' 未闭合（嵌套深度 {len(stack)}）"
                    )


def check_imports():
    for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, "lib")):
        for name in filenames:
            if not name.endswith(".dart"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as handle:
                for lineno, text in enumerate(handle, start=1):
                    match = re.match(r"\s*import\s+'([^']+)'", text)
                    if not match:
                        continue
                    target = match.group(1)
                    if target.startswith(("dart:", "package:")):
                        continue
                    resolved = os.path.normpath(os.path.join(dirpath, target))
                    if not os.path.exists(resolved):
                        problems.append(f"[IMPORT] {rel}:{lineno} 找不到 {target}")


check_xml()
check_dart_balance()
check_imports()

if problems:
    print("发现问题：")
    for item in problems:
        print(" -", item)
    sys.exit(1)
print("XML 格式、Dart 括号配对、import 路径 全部通过")
