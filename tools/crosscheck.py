#!/usr/bin/env python3
"""用 fontTools 对拍 mbt-fontsub 的子集输出。

检查项：
  1. 子集字体能被 fontTools 严格读取（checkChecksums=2，校验和不符会直接抛错）；
  2. 原始字体能映射的每个字符，在子集中仍然映射到非 0 字形；
  3. 这些字符的前进宽度与原字体完全一致；
  4. 每个字符对应的字形轮廓坐标与原字体完全一致（复合字形会被展开后比较）；
  5. 子集字形总数小于原字体。

依赖：pip install fonttools
用法：
  python tools/crosscheck.py <原字体> <子集字体> "<文本>"
退出码：0 全部一致；1 存在差异或读取失败。
"""

import sys

try:
    from fontTools.ttLib import TTFont
except ImportError:
    print("需要 fontTools：python -m pip install fonttools")
    sys.exit(2)


def load_strict(path):
    # checkChecksums=2：校验和不匹配时直接抛异常
    return TTFont(path, checkChecksums=2, lazy=False)


def outline_points(font, glyph_name):
    glyf = font["glyf"]
    glyph = glyf[glyph_name]
    glyph.expand(glyf)
    coords, end_pts, flags = glyph.getCoordinates(glyf)
    return list(coords), list(end_pts), list(flags)


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    original_path, subset_path, text = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        original = load_strict(original_path)
        subset = load_strict(subset_path)
    except Exception as exc:  # noqa: BLE001 - 需要把底层错误原样报告
        print(f"FAIL 字体无法通过严格校验和检查：{exc}")
        return 1

    failures = []
    original_cmap = original.getBestCmap()
    subset_cmap = subset.getBestCmap()
    original_hmtx = original["hmtx"]
    subset_hmtx = subset["hmtx"]

    checked = 0
    for char in sorted(set(text)):
        code = ord(char)
        original_name = original_cmap.get(code)
        if original_name is None or original_name == ".notdef":
            continue
        checked += 1
        subset_name = subset_cmap.get(code)
        if subset_name is None or subset_name == ".notdef":
            failures.append(f"U+{code:04X} 在子集中缺少字形")
            continue
        if original_hmtx[original_name][0] != subset_hmtx[subset_name][0]:
            failures.append(f"U+{code:04X} 前进宽度不一致")
        try:
            left = outline_points(original, original_name)
            right = outline_points(subset, subset_name)
        except Exception as exc:  # noqa: BLE001
            failures.append(f"U+{code:04X} 轮廓读取失败：{exc}")
            continue
        if left != right:
            failures.append(f"U+{code:04X} 轮廓坐标不一致")

    if subset["maxp"].numGlyphs >= original["maxp"].numGlyphs:
        failures.append(
            "子集字形数未减少："
            f"{subset['maxp'].numGlyphs} >= {original['maxp'].numGlyphs}"
        )

    print(
        f"原字体 {original['maxp'].numGlyphs} 字形 → 子集 {subset['maxp'].numGlyphs} 字形；"
        f"比对 {checked} 个字符"
    )
    if failures:
        print(f"FAIL {len(failures)} 项差异：")
        for item in failures[:20]:
            print("  -", item)
        return 1
    print("PASS fontTools 对拍一致（校验和 / cmap / 度量 / 轮廓）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
