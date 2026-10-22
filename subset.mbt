// 子集化：字形收集、复合字形闭包、表重建与 sfnt 组装。

///|
/// 读取复合字形直接引用的字形编号（非复合字形返回空数组）。
fn component_gids(font : Font, glyph : Int) -> Array[Int] raise FontError {
  let result : Array[Int] = []
  if glyph <= 0 || glyph >= font.num_glyphs {
    return result
  }
  let glyf = require_table(font.tables, "glyf")
  let start = glyf.offset + font.loca[glyph]
  let length = font.loca[glyph + 1] - font.loca[glyph]
  if length < 10 {
    return result
  }
  if ri16(font.bytes, start) >= 0 {
    return result
  }
  let end = start + length
  let mut pos = start + 10
  let mut steps = 0
  while pos + 4 <= end && steps < 1024 {
    let flags = ru16(font.bytes, pos)
    let component = ru16(font.bytes, pos + 2)
    result.push(component)
    pos = pos + 4
    if (flags & 0x0001) != 0 {
      pos = pos + 4
    } else {
      pos = pos + 2
    }
    if (flags & 0x0008) != 0 {
      pos = pos + 2
    } else if (flags & 0x0040) != 0 {
      pos = pos + 4
    } else if (flags & 0x0080) != 0 {
      pos = pos + 8
    }
    steps = steps + 1
    if (flags & 0x0020) == 0 {
      break
    }
  }
  result
}

///|
/// 把原字体中的一个字形追加到新 glyf 数据，并把复合字形里的组件编号
/// 从旧编号改写为新编号。
fn append_glyph(
  out : Array[Byte],
  font : Font,
  start : Int,
  length : Int,
  old_to_new : Array[Int],
) -> Unit raise FontError {
  let out_start = out.length()
  push_range(out, font.bytes, start, length)
  if length < 10 {
    return
  }
  if ri16(font.bytes, start) >= 0 {
    return
  }
  let mut pos = 10
  let mut steps = 0
  while pos + 4 <= length && steps < 1024 {
    let flags = ru16(font.bytes, start + pos)
    let old_glyph = ru16(font.bytes, start + pos + 2)
    let new_glyph = if old_glyph < old_to_new.length() {
      old_to_new[old_glyph]
    } else {
      -1
    }
    if new_glyph < 0 {
      raise FontBadTable("glyf：复合字形引用了未收录的字形")
    }
    out[out_start + pos + 2] = ((new_glyph >> 8) & 0xFF).to_byte()
    out[out_start + pos + 3] = (new_glyph & 0xFF).to_byte()
    pos = pos + 4
    if (flags & 0x0001) != 0 {
      pos = pos + 4
    } else {
      pos = pos + 2
    }
    if (flags & 0x0008) != 0 {
      pos = pos + 2
    } else if (flags & 0x0040) != 0 {
      pos = pos + 4
    } else if (flags & 0x0080) != 0 {
      pos = pos + 8
    }
    steps = steps + 1
    if (flags & 0x0020) == 0 {
      break
    }
  }
}

///|
/// 按字符集合做子集化，返回新的 TTF 字节。
///
/// 收录规则：
///   1. 始终保留 `.notdef`（glyph 0）；
///   2. 字符经 cmap 映射到的字形；
///   3. 这些字形通过复合引用到的所有组件（递归闭包）。
///
/// 未收录字符不会出现在新 cmap 中；调用方可以用 `verify_subset` 复核。
pub fn subset_by_chars_with(
  font : Font,
  chars : Array[Int],
  options : SubsetOptions,
) -> Bytes raise FontError {
  let sorted : Array[Int] = []
  for code in chars {
    if code >= 0 && code <= 0x10FFFF && !sorted.contains(code) {
      sorted.push(code)
    }
  }
  sorted.sort()

  // 直接映射的字形
  let pairs : Array[(Int, Int)] = []
  let queue : Array[Int] = []
  let selected : Map[Int, Bool] = Map([])
  selected.set(0, true)
  for code in sorted {
    match font.cmap.get(code) {
      Some(glyph) =>
        if glyph > 0 && glyph < font.num_glyphs {
          pairs.push((code, glyph))
          if !selected.contains(glyph) {
            selected.set(glyph, true)
            queue.push(glyph)
          }
        }
      None => ()
    }
  }

  // 复合字形闭包 + 自定义收集器
  let mut head = 0
  while head < queue.length() {
    let glyph = queue[head]
    head = head + 1
    for component in component_gids(font, glyph) {
      if component > 0 &&
        component < font.num_glyphs &&
        !selected.contains(component) {
        selected.set(component, true)
        queue.push(component)
      }
    }
    match options.collector {
      Some(collector) =>
        for extra in collector(font, glyph) {
          if extra > 0 && extra < font.num_glyphs && !selected.contains(extra) {
            selected.set(extra, true)
            queue.push(extra)
          }
        }
      None => ()
    }
  }

  // 新字形顺序：0 → 字符直接映射的字形（按码点顺序）→ 其余闭包字形（按旧编号）
  let order : Array[Int] = [0]
  let assigned : Map[Int, Bool] = Map([])
  assigned.set(0, true)
  for pair in pairs {
    let glyph = pair.1
    if !assigned.contains(glyph) {
      assigned.set(glyph, true)
      order.push(glyph)
    }
  }
  let rest : Array[Int] = []
  for glyph in queue {
    if !assigned.contains(glyph) {
      rest.push(glyph)
    }
  }
  rest.sort()
  for glyph in rest {
    if !assigned.contains(glyph) {
      assigned.set(glyph, true)
      order.push(glyph)
    }
  }

  // 旧编号 → 新编号
  let old_to_new : Array[Int] = Array::make(font.num_glyphs, -1)
  let mut i = 0
  while i < order.length() {
    old_to_new[order[i]] = i
    i = i + 1
  }

  // glyf + loca
  let glyf_old = require_table(font.tables, "glyf")
  let glyf_out : Array[Byte] = []
  let loca_out : Array[Int] = [0]
  i = 0
  while i < order.length() {
    let old = order[i]
    let start = glyf_old.offset + font.loca[old]
    let length = font.loca[old + 1] - font.loca[old]
    append_glyph(glyf_out, font, start, length, old_to_new)
    while glyf_out.length() % 4 != 0 {
      glyf_out.push(Byte::default())
    }
    loca_out.push(glyf_out.length())
    i = i + 1
  }
  let new_count = order.length()

  // hmtx：统一写成 (advance, lsb)，因此 numberOfHMetrics = 新字形数
  let hmtx_out : Array[Byte] = []
  i = 0
  while i < new_count {
    let old = order[i]
    push_u16(hmtx_out, font.advances[old])
    push_u16(hmtx_out, font.lsbs[old] & 0xFFFF)
    i = i + 1
  }

  // loca（固定使用长格式）
  let loca_bytes : Array[Byte] = []
  for offset in loca_out {
    push_u32(loca_bytes, offset)
  }

  // cmap：码点 → 新字形
  let new_pairs : Array[(Int, Int)] = []
  for pair in pairs {
    new_pairs.push((pair.0, old_to_new[pair.1]))
  }
  let cmap_bytes = build_cmap(new_pairs)

  // head：checkSumAdjustment 置零，indexToLocFormat 改为 1
  let head_old = require_table(font.tables, "head")
  let head_out : Array[Byte] = []
  push_range(head_out, font.bytes, head_old.offset, head_old.length)
  head_out[8] = Byte::default()
  head_out[9] = Byte::default()
  head_out[10] = Byte::default()
  head_out[11] = Byte::default()
  head_out[50] = Byte::default()
  head_out[51] = Int::to_byte(1)

  // maxp：numGlyphs
  let maxp_old = require_table(font.tables, "maxp")
  let maxp_out : Array[Byte] = []
  push_range(maxp_out, font.bytes, maxp_old.offset, maxp_old.length)
  maxp_out[4] = ((new_count >> 8) & 0xFF).to_byte()
  maxp_out[5] = (new_count & 0xFF).to_byte()

  // hhea：numberOfHMetrics
  let hhea_old = require_table(font.tables, "hhea")
  let hhea_out : Array[Byte] = []
  push_range(hhea_out, font.bytes, hhea_old.offset, hhea_old.length)
  hhea_out[34] = ((new_count >> 8) & 0xFF).to_byte()
  hhea_out[35] = (new_count & 0xFF).to_byte()

  let tables_out : Array[(String, Bytes)] = []
  tables_out.push(("head", bytes_of(head_out)))
  tables_out.push(("maxp", bytes_of(maxp_out)))
  tables_out.push(("hhea", bytes_of(hhea_out)))
  tables_out.push(("hmtx", bytes_of(hmtx_out)))
  tables_out.push(("loca", bytes_of(loca_bytes)))
  tables_out.push(("glyf", bytes_of(glyf_out)))
  tables_out.push(("cmap", cmap_bytes))

  // 可选表按策略保留；post 统一写成格式 3（无字形名）。
  if options.keeps_table("name") {
    copy_if_present(font, "name", tables_out)
  }
  if options.keeps_table("OS/2") {
    copy_os2(font, tables_out, pairs)
  }
  if options.keeps_table("cvt ") {
    copy_if_present(font, "cvt ", tables_out)
  }
  if options.keeps_table("fpgm") {
    copy_if_present(font, "fpgm", tables_out)
  }
  if options.keeps_table("prep") {
    copy_if_present(font, "prep", tables_out)
  }
  if options.keeps_table("gasp") {
    copy_if_present(font, "gasp", tables_out)
  }
  // 调用方显式追加保留的表（例如 GSUB）；字形编号是否需要重写由调用方负责。
  for tag in options.keep_optional {
    if !default_optional_tables().contains(tag) && font.tables.contains(tag) {
      copy_if_present(font, tag, tables_out)
    }
  }
  if options.keeps_table("post") {
    let post = require_table_optional(font.tables, "post")
    match post {
      Some(record) =>
        if record.length >= 32 && ru32(font.bytes, record.offset) == 0x00030000 {
          let data : Array[Byte] = []
          push_range(data, font.bytes, record.offset, record.length)
          tables_out.push(("post", bytes_of(data)))
        } else {
          tables_out.push(("post", synth_post()))
        }
      None => tables_out.push(("post", synth_post()))
    }
  }
  assemble_sfnt(tables_out)
}

///|
/// 按字符集合做子集化，使用默认表策略。
pub fn subset_by_chars(
  font : Font,
  chars : Array[Int],
) -> Bytes raise FontError {
  subset_by_chars_with(font, chars, SubsetOptions::default())
}

///|
/// 按文本做子集化，使用默认表策略。
pub fn subset_by_text(font : Font, text : String) -> Bytes raise FontError {
  subset_by_text_with(font, text, SubsetOptions::default())
}

///|
/// 按文本做子集化，并应用自定义策略。
pub fn subset_by_text_with(
  font : Font,
  text : String,
  options : SubsetOptions,
) -> Bytes raise FontError {
  let chars : Array[Int] = []
  for ch in text {
    chars.push(ch.to_int())
  }
  subset_by_chars_with(font, chars, options)
}

///|
fn require_table_optional(
  tables : Map[String, TableRecord],
  tag : String,
) -> TableRecord? {
  tables.get(tag)
}

///|
fn copy_if_present(
  font : Font,
  tag : String,
  out : Array[(String, Bytes)],
) -> Unit raise FontError {
  match font.tables.get(tag) {
    Some(record) => {
      let data : Array[Byte] = []
      push_range(data, font.bytes, record.offset, record.length)
      out.push((tag, bytes_of(data)))
    }
    None => ()
  }
}

///|
/// OS/2 表：复制原表，并把 usFirstCharIndex / usLastCharIndex 收敛到新字符集。
fn copy_os2(
  font : Font,
  out : Array[(String, Bytes)],
  pairs : Array[(Int, Int)],
) -> Unit raise FontError {
  match font.tables.get("OS/2") {
    Some(record) => {
      let data : Array[Byte] = []
      push_range(data, font.bytes, record.offset, record.length)
      if data.length() >= 68 && pairs.length() > 0 {
        let mut first = 0xFFFF
        let mut last = 0
        for pair in pairs {
          if pair.0 <= 0xFFFF {
            if pair.0 < first {
              first = pair.0
            }
            if pair.0 > last {
              last = pair.0
            }
          }
        }
        if first <= last {
          data[64] = ((first >> 8) & 0xFF).to_byte()
          data[65] = (first & 0xFF).to_byte()
          data[66] = ((last >> 8) & 0xFF).to_byte()
          data[67] = (last & 0xFF).to_byte()
        }
      }
      out.push(("OS/2", bytes_of(data)))
    }
    None => ()
  }
}

///|
/// 32 字节的 post 格式 3 表：不携带字形名，避免删减字形后名字表错位。
fn synth_post() -> Bytes {
  let out : Array[Byte] = []
  push_u32(out, 0x00030000)
  push_u32(out, 0)
  push_u16(out, -100 & 0xFFFF)
  push_u16(out, 50)
  push_u32(out, 0)
  push_u32(out, 0)
  push_u32(out, 0)
  push_u32(out, 0)
  push_u32(out, 0)
  bytes_of(out)
}

///|
fn assemble_sfnt(tables : Array[(String, Bytes)]) -> Bytes raise FontError {
  tables.sort_by(fn(a, b) { a.0.compare(b.0) })
  let count = tables.length()
  let mut power = 1
  let mut selector = 0
  while power * 2 <= count {
    power = power * 2
    selector = selector + 1
  }
  let search_range = power * 16
  let range_shift = count * 16 - search_range

  let out : Array[Byte] = []
  push_u32(out, 0x00010000)
  push_u16(out, count)
  push_u16(out, search_range)
  push_u16(out, selector)
  push_u16(out, range_shift)

  let header_length = 12 + count * 16
  let offsets : Array[Int] = []
  let mut cursor = header_length
  for entry in tables {
    offsets.push(cursor)
    cursor = cursor + pad4(entry.1.length())
  }
  let mut i = 0
  while i < count {
    push_tag(out, tables[i].0)
    push_u32(out, 0) // checksum 占位
    push_u32(out, offsets[i])
    push_u32(out, tables[i].1.length())
    i = i + 1
  }
  i = 0
  while i < count {
    let data = tables[i].1
    let mut k = 0
    while k < data.length() {
      out.push(data.at(k))
      k = k + 1
    }
    push_zeros(out, pad4(data.length()) - data.length())
    i = i + 1
  }

  // 逐表校验和
  let snapshot = bytes_of(out)
  i = 0
  while i < count {
    let sum = checksum_range(snapshot, offsets[i], tables[i].1.length())
    write_u32u_at(out, 12 + i * 16 + 4, sum)
    i = i + 1
  }

  // 整字体校验和：adjustment = 0xB1B0AFBA - sum
  let snapshot2 = bytes_of(out)
  let total = checksum_range(snapshot2, 0, snapshot2.length())
  let magic : UInt64 = 0xB1B0AFBAUL
  let adjustment = ((magic - total.to_uint64()) & 0xFFFFFFFFUL).to_uint()
  let mut head_index = -1
  i = 0
  while i < count {
    if tables[i].0 == "head" {
      head_index = i
    }
    i = i + 1
  }
  if head_index < 0 {
    raise FontMissingTable("head")
  }
  write_u32u_at(out, offsets[head_index] + 8, adjustment)
  bytes_of(out)
}
