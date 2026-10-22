// SFNT 解析：表目录、head/maxp/hhea/hmtx/loca，以及 cmap 调度。

///|
fn require_table(
  tables : Map[String, TableRecord],
  tag : String,
) -> TableRecord raise FontError {
  match tables.get(tag) {
    Some(record) => record
    None => raise FontMissingTable(tag)
  }
}

///|
/// TTC 集合中的字体数量；单体字体返回 1。
pub fn ttc_face_count(bytes : Bytes) -> Int raise FontError {
  need(bytes, 0, 12)
  let tag = ru32u(bytes, 0)
  let version_collection : UInt = 0x74746366
  if tag != version_collection {
    return 1
  }
  let count = ru32(bytes, 8)
  if count <= 0 || count > 1024 {
    raise FontBadTable("ttcf 字体数量")
  }
  count
}

///|
/// 解析单体 TrueType 字体；如果是 TTC 集合，默认取第 0 面。
///
/// 明确区分「不是字体」和「是字体但本版本不支持」：
/// CFF/CFF2（OTTO）、WOFF、WOFF2 会返回 `FontUnsupported`，而不是 `FontNotSfnt`。
pub fn parse_font(bytes : Bytes) -> Font raise FontError {
  parse_font_face(bytes, 0)
}

///|
/// 解析字体集合的第 `index` 面；单体字体只接受 `index = 0`。
///
/// TTC 的表偏移是相对文件起点的绝对偏移，因此解析时保留整份字节，
/// 只把表目录的基准点移到面偏移处。
pub fn parse_font_face(bytes : Bytes, index : Int) -> Font raise FontError {
  need(bytes, 0, 12)
  let tag = ru32u(bytes, 0)
  let version_collection : UInt = 0x74746366
  if tag != version_collection {
    if index != 0 {
      raise FontBadTable("单体字体只有一个面")
    }
    return parse_sfnt_at(bytes, 0)
  }
  let version = ru32(bytes, 4)
  let version_v1 : Int = 0x00010000
  let version_v2 : Int = 0x00020000
  if version != version_v1 && version != version_v2 {
    raise FontUnsupported("TTC 版本 0x\{hex(version)}")
  }
  let count = ru32(bytes, 8)
  if count <= 0 || count > 1024 {
    raise FontBadTable("ttcf 字体数量")
  }
  if index < 0 || index >= count {
    raise FontBadTable("ttcf 字体下标越界")
  }
  let face_offset = ru32(bytes, 12 + index * 4)
  if face_offset <= 0 || face_offset >= bytes.length() {
    raise FontBadTable("ttcf 字体偏移")
  }
  parse_sfnt_at(bytes, face_offset)
}

///|
fn parse_sfnt_at(bytes : Bytes, base : Int) -> Font raise FontError {
  need(bytes, base, 12)
  let version = ru32u(bytes, base)
  let version_true_type : UInt = 0x00010000
  let version_apple : UInt = 0x74727565
  let version_cff : UInt = 0x4F54544F
  let version_woff : UInt = 0x774F4646
  let version_woff2 : UInt = 0x774F4632
  if version == version_cff {
    raise FontUnsupported(
      "CFF/CFF2 轮廓（OTTO），v0.1 只支持 glyf 轮廓",
    )
  }
  if version == version_woff {
    raise FontUnsupported("WOFF 容器，请先解包为单体 TTF")
  }
  if version == version_woff2 {
    raise FontUnsupported("WOFF2 容器，请先解包为单体 TTF")
  }
  if version != version_true_type && version != version_apple {
    raise FontNotSfnt
  }
  let num_tables = ru16(bytes, base + 4)
  if num_tables == 0 || num_tables > 512 {
    raise FontBadTable("sfnt 表目录")
  }
  let tables : Map[String, TableRecord] = Map([])
  let mut i = 0
  while i < num_tables {
    let record_offset = base + 12 + i * 16
    need(bytes, record_offset, 16)
    let tag = tag_at(bytes, record_offset)
    let record = {
      tag,
      checksum: ru32u(bytes, record_offset + 4),
      offset: ru32(bytes, record_offset + 8),
      length: ru32(bytes, record_offset + 12),
    }
    need(bytes, record.offset, record.length)
    tables.set(tag, record)
    i = i + 1
  }
  let head = require_table(tables, "head")
  let maxp = require_table(tables, "maxp")
  let hhea = require_table(tables, "hhea")
  let hmtx = require_table(tables, "hmtx")
  let loca_record = require_table(tables, "loca")
  let glyf_record = require_table(tables, "glyf")
  let cmap_record = require_table(tables, "cmap")
  if head.length < 54 {
    raise FontBadTable("head")
  }
  let units_per_em = ru16(bytes, head.offset + 18)
  if units_per_em == 0 {
    raise FontBadTable("head.unitsPerEm")
  }
  let index_to_loc_format = ri16(bytes, head.offset + 50)
  if index_to_loc_format != 0 && index_to_loc_format != 1 {
    raise FontBadTable("head.indexToLocFormat")
  }
  let num_glyphs = ru16(bytes, maxp.offset + 4)
  if num_glyphs == 0 {
    raise FontBadTable("maxp.numGlyphs")
  }
  let num_h_metrics = ru16(bytes, hhea.offset + 34)
  if num_h_metrics == 0 || num_h_metrics > num_glyphs {
    raise FontBadTable("hhea.numberOfHMetrics")
  }
  let ascender = ri16(bytes, hhea.offset + 4)
  let descender = ri16(bytes, hhea.offset + 6)

  // loca：numGlyphs + 1 个偏移，必须单调不减且不超过 glyf 长度。
  let loca : Array[Int] = Array(capacity=num_glyphs + 1)
  let mut glyph = 0
  while glyph <= num_glyphs {
    let value = if index_to_loc_format == 0 {
      ru16(bytes, loca_record.offset + glyph * 2) * 2
    } else {
      ru32(bytes, loca_record.offset + glyph * 4)
    }
    if value < 0 || value > glyf_record.length {
      raise FontBadTable("loca")
    }
    if glyph > 0 && value < loca[glyph - 1] {
      raise FontBadTable("loca")
    }
    loca.push(value)
    glyph = glyph + 1
  }

  // hmtx：前 num_h_metrics 个是 (advance, lsb)，其余只有 lsb，advance 复用最后一个。
  let advances : Array[Int] = Array::make(num_glyphs, 0)
  let lsbs : Array[Int] = Array::make(num_glyphs, 0)
  glyph = 0
  while glyph < num_h_metrics {
    advances[glyph] = ru16(bytes, hmtx.offset + glyph * 4)
    lsbs[glyph] = ri16(bytes, hmtx.offset + glyph * 4 + 2)
    glyph = glyph + 1
  }
  while glyph < num_glyphs {
    advances[glyph] = advances[num_h_metrics - 1]
    lsbs[glyph] = ri16(
      bytes,
      hmtx.offset + num_h_metrics * 4 + (glyph - num_h_metrics) * 2,
    )
    glyph = glyph + 1
  }

  let (cmap, cmap_formats) = parse_cmap(bytes, cmap_record)
  {
    bytes,
    tables,
    units_per_em,
    num_glyphs,
    index_to_loc_format,
    loca,
    advances,
    lsbs,
    num_h_metrics,
    ascender,
    descender,
    cmap,
    cmap_formats,
  }
}

///|
/// 每 em 的单位数（常见值 1000 或 2048）。
pub fn Font::units(self : Font) -> Int {
  self.units_per_em
}

///|
/// 字形总数（含 .notdef）。
pub fn Font::glyph_count(self : Font) -> Int {
  self.num_glyphs
}

///|
/// 字符到字形的映射；未收录时返回 `None`，映射到 .notdef 时返回 `Some(0)`。
pub fn Font::glyph_of(self : Font, ch : Char) -> Int? {
  self.cmap.get(ch.to_int())
}

///|
/// 该字符在字体中是否有真实字形（不是 .notdef）。
pub fn Font::has_glyph(self : Font, ch : Char) -> Bool {
  match self.cmap.get(ch.to_int()) {
    Some(glyph) => glyph > 0
    None => false
  }
}

///|
/// 字形的前进宽度；越界返回 `None`。
pub fn Font::advance_of(self : Font, glyph : Int) -> Int? {
  if glyph < 0 || glyph >= self.num_glyphs {
    None
  } else {
    Some(self.advances[glyph])
  }
}

///|
/// 字体包含的表标签，按字典序排列。
pub fn Font::table_tags(self : Font) -> Array[String] {
  let tags : Array[String] = []
  for entry in self.tables {
    tags.push(entry.0)
  }
  tags.sort()
  tags
}

///|
/// 字形数据长度（loca 差值）；用于判断空字形与复合字形。
pub fn Font::glyph_length(self : Font, glyph : Int) -> Int? {
  if glyph < 0 || glyph >= self.num_glyphs {
    None
  } else {
    Some(self.loca[glyph + 1] - self.loca[glyph])
  }
}

///|
/// 是否为复合字形（numberOfContours < 0）。
pub fn Font::is_composite(self : Font, glyph : Int) -> Bool raise FontError {
  if glyph <= 0 || glyph >= self.num_glyphs {
    return false
  }
  let glyf = require_table(self.tables, "glyf")
  let start = glyf.offset + self.loca[glyph]
  let length = self.loca[glyph + 1] - self.loca[glyph]
  if length < 10 {
    return false
  }
  ri16(self.bytes, start) < 0
}

///|
/// 从磁盘读取并解析字体；IO 失败保留路径，便于定位。
pub fn read_font(path : String) -> Font raise FontError {
  let bytes = @fs.read_file_to_bytes(path) catch { _ => raise FontIo(path) }
  parse_font(bytes)
}

///|
/// 从磁盘读取字体并解析指定面。
pub fn read_font_face(path : String, index : Int) -> Font raise FontError {
  let bytes = @fs.read_file_to_bytes(path) catch { _ => raise FontIo(path) }
  parse_font_face(bytes, index)
}
