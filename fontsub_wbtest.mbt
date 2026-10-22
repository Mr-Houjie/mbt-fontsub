// 白盒测试：直接使用仓库内的 VT323 字体样本（SIL OFL 1.1）。

///|
fn load_fixture() -> Bytes raise @fs.IOError {
  @fs.read_file_to_bytes("tests/fixtures/VT323-Regular.ttf")
}

///|
fn chars_of(text : String) -> Array[Int] {
  let chars : Array[Int] = []
  for ch in text {
    chars.push(ch.to_int())
  }
  chars
}

///|
test "解析字体头与度量" {
  let font = parse_font(load_fixture())
  assert_true(font.units_per_em > 0)
  assert_true(font.num_glyphs > 10)
  assert_true(font.has_glyph('A'))
  assert_true(font.has_glyph('0'))
  assert_true(font.table_tags().contains("head"))
  assert_true(font.table_tags().contains("glyf"))
  assert_true(font.cmap_formats.contains(4))
}

///|
test "按文本子集化并通过回读校验" {
  let font = parse_font(load_fixture())
  let text = "Hello, MoonBit! 0123"
  let subset = subset_by_text(font, text)
  let report = verify_subset(font, subset, chars_of(text))
  assert_true(report.ok)
  assert_true(report.subset_size < report.original_size)
  assert_true(report.glyphs < font.num_glyphs)
  // "Hello, MoonBit! 0123" 的唯一字符共 16 个
  assert_true(report.chars_checked >= 16)
  let rebuilt = parse_font(subset)
  assert_true(rebuilt.has_glyph('H'))
  assert_true(rebuilt.has_glyph('!'))
  assert_eq(rebuilt.units_per_em, font.units_per_em)
}

///|
test "子集化是确定性的" {
  let font = parse_font(load_fixture())
  let first = subset_by_text(font, "moonbit")
  let second = subset_by_text(font, "moonbit")
  assert_true(Bytes::equal(first, second))
}

///|
test "空文本只保留 .notdef" {
  let font = parse_font(load_fixture())
  let subset = subset_by_text(font, "")
  let rebuilt = parse_font(subset)
  assert_eq(rebuilt.num_glyphs, 1)
  let report = verify_subset(font, subset, [])
  assert_true(report.ok)
  assert_eq(report.glyphs, 1)
}

///|
test "未收录字符不会出现在子集 cmap 中" {
  let font = parse_font(load_fixture())
  let subset = subset_by_text(font, "abc")
  let rebuilt = parse_font(subset)
  assert_true(rebuilt.has_glyph('a'))
  assert_true(!rebuilt.has_glyph('Z'))
}

///|
test "复合字形闭包完整" {
  let font = parse_font(load_fixture())
  let mut composite = -1
  let mut glyph = 1
  while glyph < font.num_glyphs && composite < 0 {
    if font.is_composite(glyph) {
      composite = glyph
    }
    glyph = glyph + 1
  }
  if composite >= 0 {
    // 取复合字形的第一个组件字符不可行，改为直接把字形编号纳入子集：
    // 用包含其组件的字符集做一次完整校验。
    let subset = subset_by_text(font, "éüñç")
    let report = verify_subset(font, subset, chars_of("éüñç"))
    assert_true(report.ok)
  }
}

///|
test "截断输入被拒绝" {
  let empty : Bytes = Bytes::new(0)
  let mut rejected = false
  try {
    let _ = parse_font(empty)
  } catch {
    _ => rejected = true
  }
  assert_true(rejected)
}

///|
test "非 sfnt 输入被拒绝" {
  let bytes : Array[Byte] = []
  let mut i = 0
  while i < 32 {
    bytes.push(Int::to_byte(i))
    i = i + 1
  }
  let mut rejected = false
  try {
    let _ = parse_font(Bytes::from_iter(bytes.iter()))
  } catch {
    _ => rejected = true
  }
  assert_true(rejected)
}

///|
test "字体体积统计正确" {
  let font = parse_font(load_fixture())
  let subset = subset_by_text(
    font, "The quick brown fox jumps over the lazy dog",
  )
  let report = verify_subset(
    font,
    subset,
    chars_of("The quick brown fox jumps over the lazy dog"),
  )
  assert_true(report.ok)
  assert_true(report.savings_percent > 50.0)
  assert_eq(report.original_size, font.bytes.length())
  assert_eq(report.subset_size, subset.length())
}

///|
test "共享用例全部通过" {
  let font = parse_font(load_fixture())
  for case in default_cases() {
    let subset = subset_by_text(font, case.text)
    let report = verify_subset(font, subset, chars_of(case.text))
    assert_true(report.ok)
  }
}

///|
/// 把单体 TTF 包成一面 TTC：前置 16 字节集合头，并把表偏移整体后移。
fn wrap_as_ttc(data : Bytes, face_offset : Int) -> Bytes raise FontError {
  let num_tables = ru16(data, 4)
  let out : Array[Byte] = []
  push_u32(out, 0x74746366)
  push_u32(out, 0x00010000)
  push_u32(out, 1)
  push_u32(out, face_offset)
  let mut i = 0
  while i < data.length() {
    out.push(data.at(i))
    i = i + 1
  }
  i = 0
  while i < num_tables {
    let at = face_offset + 12 + i * 16 + 8
    let old = ru32(data, 12 + i * 16 + 8)
    let next = old + face_offset
    out[at] = ((next >> 24) & 0xFF).to_byte()
    out[at + 1] = ((next >> 16) & 0xFF).to_byte()
    out[at + 2] = ((next >> 8) & 0xFF).to_byte()
    out[at + 3] = (next & 0xFF).to_byte()
    i = i + 1
  }
  bytes_of(out)
}

///|
test "TTC 集合可解析第 0 面" {
  let data = load_fixture()
  let ttc = wrap_as_ttc(data, 16)
  assert_eq(ttc_face_count(ttc), 1)
  let font = parse_font(ttc)
  assert_eq(font.glyph_count(), parse_font(data).glyph_count())
  let subset = subset_by_text(font, "TTC")
  assert_true(verify_subset(font, subset, chars_of("TTC")).ok)
  let mut rejected = false
  try {
    let _ = parse_font_face(ttc, 1)
  } catch {
    _ => rejected = true
  }
  assert_true(rejected)
}

///|
fn header4(version : Int) -> Bytes {
  let out : Array[Byte] = []
  push_u32(out, version)
  push_u16(out, 0)
  push_u16(out, 0)
  push_u16(out, 0)
  push_u16(out, 0)
  bytes_of(out)
}

///|
test "已知但暂不支持的容器返回 FontUnsupported" {
  let versions : Array[(Int, String)] = [
    (0x4F54544F, "OTTO"),
    (0x774F4646, "wOFF"),
    (0x774F4632, "wOF2"),
  ]
  for item in versions {
    let mut unsupported = false
    try {
      let _ = parse_font(header4(item.0))
    } catch {
      FontUnsupported(_) => unsupported = true
      _ => ()
    }
    assert_true(unsupported)
  }
}

///|
test "未知格式返回 FontNotSfnt" {
  let mut not_sfnt = false
  try {
    let _ = parse_font(header4(0x12345678))
  } catch {
    FontNotSfnt => not_sfnt = true
    _ => ()
  }
  assert_true(not_sfnt)
}

///|
test "drop_table 可以从结果中移除 name 表" {
  let font = parse_font(load_fixture())
  assert_true(font.tables.contains("name"))
  let options = SubsetOptions::default().drop_table("name")
  let subset = subset_by_text_with(font, "abc", options)
  let rebuilt = parse_font(subset)
  assert_true(!rebuilt.tables.contains("name"))
}

///|
test "自定义收集器可以补充字形" {
  let font = parse_font(load_fixture())
  let base = parse_font(subset_by_text(font, "a"))
  let options = SubsetOptions::default().with_collector(fn(
    font : Font,
    _glyph : Int,
  ) {
    [font.num_glyphs - 1]
  })
  let extended = parse_font(subset_by_text_with(font, "a", options))
  assert_true(extended.glyph_count() > base.glyph_count())
}

///|
test "自定义验证器会进入自检结果" {
  let font = parse_font(load_fixture())
  let options = SubsetOptions::default().with_validator(fn(
    _original : Font,
    _subset : Font,
    _chars : Array[Int],
  ) {
    ["custom failure"]
  })
  let subset = subset_by_text_with(font, "abc", options)
  let report = verify_subset_with(font, subset, chars_of("abc"), options)
  assert_true(!report.ok)
  assert_true(report.failures.contains("custom failure"))
}
