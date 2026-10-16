#!/usr/bin/env python3
"""由 tools/zh-Hant.json 產生 Localization/zh-Hant.lproj/Localizable.strings。

翻譯以 JSON 維護（鍵＝程式碼中的英文字串，與編譯器 -emit-localized-strings 的鍵一致）。
可加 --check <keys.json> 比對編譯器擷取的鍵，列出尚未翻譯者。
用法：python3 tools/gen-strings.py [--check keys.json]
"""
import json, os, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
table = json.load(open(os.path.join(root, "tools/zh-Hant.json"), encoding="utf-8"))

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

out = os.path.join(root, "Localization/zh-Hant.lproj/Localizable.strings")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    f.write("/* 由 tools/gen-strings.py 自 tools/zh-Hant.json 產生，請勿手動修改 */\n")
    for k in sorted(table):
        f.write(f'"{esc(k)}" = "{esc(table[k])}";\n')
print(f"已產出 {out}（{len(table)} 筆）")

if "--check" in sys.argv:
    keys = json.load(open(sys.argv[sys.argv.index("--check") + 1], encoding="utf-8"))
    missing = [k for k in keys if k and k not in table]
    for k in missing:
        print("未翻譯：", repr(k))
    sys.exit(1 if missing else 0)
