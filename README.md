# mbt-fontsub

纯 MoonBit 实现的 TrueType 字体子集化引擎：给定字体和文本，输出只包含所需字形、
但结构与度量完全合法的子集字体。面向 PDF / 文档生成、电子书打包与 Web 字体裁剪。

## 为什么需要它

中文字体通常有 1–3 万个字形、体积 10–20 MB。文档生成时如果整份嵌入，产物会大一个数量级。
现有 MoonBit 字体包（`mizchi/font`、`moon_skrifa`、`harfbuzz`、`freetype` 等）
都只做**解析、度量或排版**，没有一个能裁剪字体。mbt-fontsub 补的是这一环。

实测：

| 样本 | 原始 | 子集后 | 字符 / 字形 | 外部校验 |
|---|---|---|---|---|
| VT323（拉丁） | 153,116 B | 8,964 B | 12 / 13 | GDI+ 逐像素差异 0 |
| DengXian（中文） | 16,324,168 B | 16,804 B | 27 / 29 | GDI+ 逐像素差异 0 |
| SimSun（TTC 第 1 面） | 18,070,492 B | 10,320 B | 14 / 15 | 本工具回读 + 校验和 |

## 安装与使用

```bash
moon add Mr-Houjie/mbt-fontsub
```

```bash
# 查看字体信息（含 TTC 面数）
moon run cmd/main -- info tests/fixtures/VT323-Regular.ttf

# 按文本子集化
moon run cmd/main -- subset tests/fixtures/VT323-Regular.ttf \
  --text "Hello, MoonBit!" -o out.ttf

# TTC 集合：指定面
moon run cmd/main -- subset C:/Windows/Fonts/simsun.ttc --face 1 \
  --text "你好，世界" -o out.ttf

# 只做自检，不写文件
moon run cmd/main -- verify tests/fixtures/VT323-Regular.ttf --text "Hello"
```

输出示例：

```
已写出       : out.ttf
体积         : 153116 → 8964 字节（省 94.15%）
字符 / 字形  : 12 / 13（原 587）
自检         : 通过
```

## 库 API

```moonbit
///|
let font = @fontsub.read_font("tests/fixtures/VT323-Regular.ttf")
let text = "Hello, MoonBit!"
let chars : Array[Int] = []
for ch in text {
  chars.push(ch.to_int())
}
let subset = @fontsub.subset_by_chars(font, chars)
let report = @fontsub.verify_subset(font, subset, chars)
assert_true(report.ok)
```

| API | 说明 |
|---|---|
| `parse_font(Bytes) -> Font` | 解析单体 TrueType，TTC 默认第 0 面 |
| `parse_font_face(Bytes, Int) -> Font` | 解析指定面 |
| `ttc_face_count(Bytes) -> Int` | TTC 面数，单体字体返回 1 |
| `read_font` / `read_font_face` | 读文件并解析 |
| `subset_by_text` / `subset_by_chars` | 默认策略子集化 |
| `subset_by_text_with` / `subset_by_chars_with` | 带 `SubsetOptions` 的子集化 |
| `verify_subset` / `verify_subset_with` | 回读自检 |
| `Font::glyph_of` / `has_glyph` / `advance_of` | 查询映射与度量 |

## 扩展点

`SubsetOptions` 提供三个入口，不需要改库代码：

```moonbit
///|
let options = @fontsub.SubsetOptions::default()
  .drop_table("name")                       // 额外丢弃某张表
  .keep_table("GSUB")                       // 强制保留某张表
  .with_collector(fn(_font, _glyph) { [] }) // 为字形补充依赖（例如 GSUB 闭包）
  .with_validator(fn(_original, _subset, _chars) { ["自定义规则"] })
let subset = @fontsub.subset_by_text_with(font, text, options)
```

- **表策略**：`keep_table` / `drop_table` 控制结果里保留哪些表；
- **字形收集器**：对每个已选字形调用，返回的字形继续参与闭包与编号重排；
- **验证器**：在内建检查之后追加自定义验收规则，失败信息进入 `VerifyReport`。

## 子集做了什么

1. 始终保留 `.notdef`（glyph 0）；
2. 字符经 `cmap` 映射到的字形；
3. 复合字形递归引用到的全部组件（闭包），并改写组件编号；
4. 重写 `glyf` / `loca` / `hmtx` / `cmap`，修正 `head` / `maxp` / `hhea` / `OS/2`，
   `post` 降为格式 3；
5. 按 OpenType 规范重新计算逐表校验和与 `head.checkSumAdjustment`。

## 能力边界（v0.1）

支持：单体 TrueType 与 TTC 集合、`glyf` 轮廓、`cmap` format 4 / 12、复合字形、
BMP 与辅助平面字符。

明确识别但暂不处理，遇到时返回 `FontUnsupported`（不是误判为「不是字体」）：

- CFF / CFF2 轮廓（`OTTO`）
- WOFF / WOFF2 容器
- 可变字体实例化（`gvar`）
- GSUB 连字闭包（默认丢弃 GSUB/GPOS/GDEF；可用 `keep_table` + `collector` 自行处理）

## 自检与跨库验证

```bash
moon test                    # 单元测试
moon run cmd/verify          # 独立自检（Windows 下 moon test 嵌套进程受限时使用）
moon run cmd/verify -- corpus/fonts/*.ttf   # 对语料逐字体巡检
```

`verify_subset` 会断言：字符覆盖、前进宽度、字形非空、复合组件范围、`unitsPerEm`、
逐表校验和、整字体校验和（`0xB1B0AFBA`）、体积变化与结果确定性。

跨库对拍（需要 `fonttools`）：

```bash
moon run cmd/main -- subset tests/fixtures/VT323-Regular.ttf \
  --text "Hello, MoonBit! 0123" -o /tmp/subset.ttf
python tools/crosscheck.py tests/fixtures/VT323-Regular.ttf \
  /tmp/subset.ttf "Hello, MoonBit! 0123"
```

`crosscheck.py` 用 fontTools 以 `checkChecksums=2` 严格读取子集字体，
并逐字符比较 cmap、前进宽度与展开后的轮廓坐标。

## 语料

大字体不进仓库，只提交清单（URL + SHA-256 + 许可证）：

```bash
python tools/fetch_corpus.py
moon run cmd/verify -- corpus/fonts/PressStart2P-Regular.ttf corpus/fonts/ZCOOLXiaoWei-Regular.ttf
```

## 许可证

MIT。测试样本 `tests/fixtures/VT323-Regular.ttf` 来自 Google Fonts，
按 SIL Open Font License 1.1 分发，详见 `tests/fixtures/OFL.txt`。
