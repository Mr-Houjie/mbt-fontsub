# MoonBit 十月黑客松 项目申报书

## 一、项目名称与仓库

mbt-fontsub（MoonBit 原生 TrueType 字体子集化引擎）｜https://github.com/Mr-Houjie/mbt-fontsub ｜ MIT ｜ MoonBit ≥ 0.1.20260920 ｜ 已发布至 mooncakes.io：https://mooncakes.io/docs/Mr-Houjie/mbt-fontsub （`moon add Mr-Houjie/mbt-fontsub@0.1.0`）

## 二、项目简介

按文本裁剪字体：输入字体与字符集，输出只含所需字形、但结构合法、度量一致的新字体。流程为 表目录解析 → 字形收集与复合闭包 → glyf/loca/hmtx/cmap 重建 → sfnt 组装与校验和 → 回读自检。库、CLI 与自检入口共用同一套实现。

## 三、项目方向与通用性

方向为文档基础设施 / 开发者工具。核心是纯函数（`Bytes + 字符集 → Bytes`），不依赖网络与渲染后端；文件读写只在 `read_font` 适配层与 CLI，核心仅依赖标准库。中文字体 1–3 万字形、10–20 MB，整份嵌入 PDF 会让产物大一个数量级，子集化是这条链路的必需环节。

## 四、生态边界（选题依据）

2026-10-22 对 mooncakes.io 线上索引（`api/v0/modules`，3217 个模块）全量检索：字体相关包 39 个（mizchi/font、moon_skrifa、harfbuzz、freetype、ttf_parser_moonbit 等）**全部只做解析、度量或排版，无一实现子集化**；`subset` / `glyf` / `loca` / `cmap` 重组检索 0 命中。pdflite 只能诊断已嵌入字体，pagelayout / typst / prawn 负责排版与生成，字体整份嵌入。本项目与它们互补：它们读字体，本项目裁剪字体。

## 五、核心功能

- cmap 双格式解析（format 4 / 12）与重建，覆盖 BMP 与辅助平面
- 复合字形递归闭包，组件编号就地改写为新编号
- 重写 glyf / loca / hmtx / cmap，同步 head / maxp / hhea / OS-2，post 降为格式 3
- sfnt 组装：表按 tag 排序、四字节对齐、逐表校验和、`checkSumAdjustment` 回填
- TTC 集合按面解析（表偏移按文件绝对地址）
- 容器边界识别：OTTO / wOFF / wOF2 返回 `FontUnsupported`，不误判为「非字体」
- 扩展点 `SubsetOptions`：表保留策略、自定义字形收集器、验证器链
- CLI：`info` / `subset` / `verify`，`--face` 选择 TTC 面

## 六、验证结果

| 样本 | 原始 | 子集后 | 字符 / 字形 |
|---|---|---|---|
| VT323（拉丁） | 153,116 B | 8,964 B | 12 / 13 |
| DengXian（中文，29,624 字形） | 16,324,168 B | 16,804 B | 27 / 29 |
| SimSun（TTC 第 1 面，28,905 字形） | 18,070,492 B | 10,320 B | 14 / 15 |

- fontTools 以 `checkChecksums=2` 严格读取子集字体，逐字符比对 cmap、前进宽度与展开后的轮廓坐标：拉丁 16 字符、中文 16 字符全部一致
- 语料巡检（VT323 / PressStart2P / ZCOOLXiaoWei，含中文用例）全部通过
- GitHub Actions 五步全绿：check / build / test / self-check / fontTools 对拍
- 外部渲染器 GDI+ 逐像素对照：拉丁 48,000、中文 99,000 像素，差异 0

## 七、边界与判定终点

「子集成功」= 八项机器断言全部通过：字符覆盖、前进宽度不变、字形非空、复合组件编号在范围内、`unitsPerEm` 一致、逐表校验和一致、整字体校验和为 `0xB1B0AFBA`、字节级确定性。

支持 TrueType `glyf` 轮廓（含 TTC）。明确识别但暂不处理并返回 `FontUnsupported`：CFF/CFF2（OTTO）、WOFF / WOFF2、可变字体实例化、GSUB 连字闭包——这四种属于另一种轮廓或容器格式，不是「声称支持某格式却跳过其核心语义」；对已声明支持的 glyf + cmap + 复合字形，结构、度量、渲染三层闭环。

## 八、项目性质

独立实现（非移植），未复制任何项目源码；表结构、cmap 编码、校验和与 `checkSumAdjustment` 规则参照 OpenType 规范与 Apple TrueType Reference。fonttools 与 harfbuzz-subset 仅作能力参照，fontTools 反而用作外部对拍工具。

## 九、GitHub 与提交记录

`main` 分支 16 个有效提交，按「脚手架 → 字节层 → 类型 → cmap → 解析/TTC → 扩展接口 → 子集 → 自检 → 共享用例 → CLI → 测试 → 自检入口 → 语料/对拍 → CI → 文档」分层，无空提交、无重复提交。
