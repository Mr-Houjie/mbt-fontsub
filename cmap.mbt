// cmap：解析 format 4 / format 12，并为子集重建这两张表。
//
// 解析时把编码记录按「覆盖面优先」排序（3/10 → 0/6 → 0/4 → 3/1 → …），
// 先写入的映射不会被后面的表覆盖，因此 format 12 优先于 format 4。

///|
fn cmap_preference(platform : Int, encoding : Int) -> Int {
  if platform == 3 && encoding == 10 {
    0
  } else if platform == 0 && encoding == 6 {
    1
  } else if platform == 0 && encoding == 4 {
    2
  } else if platform == 3 && encoding == 1 {
    3
  } else if platform == 0 && encoding == 3 {
    4
  } else if platform == 0 && encoding == 2 {
    5
  } else if platform == 0 && encoding == 1 {
    6
  } else if platform == 0 && encoding == 0 {
    7
  } else {
    99
  }
}

///|
fn parse_cmap(
  bytes : Bytes,
  record : TableRecord,
) -> (Map[Int, Int], Array[Int]) raise FontError {
  let base = record.offset
  need(bytes, base, 4)
  let count = ru16(bytes, base + 2)
  let records : Array[(Int, Int, Int, Int)] = []
  let mut i = 0
  while i < count {
    let at = base + 4 + i * 8
    need(bytes, at, 8)
    let platform = ru16(bytes, at)
    let encoding = ru16(bytes, at + 2)
    let offset = ru32(bytes, at + 4)
    records.push(
      (cmap_preference(platform, encoding), platform, encoding, offset),
    )
    i = i + 1
  }
  records.sort_by(fn(a, b) { a.0 - b.0 })
  let map : Map[Int, Int] = Map([])
  let formats : Array[Int] = []
  for entry in records {
    if entry.0 < 99 {
      let sub = base + entry.3
      let format = ru16(bytes, sub)
      if format == 4 {
        parse_format4(bytes, sub, map)
        if !formats.contains(4) {
          formats.push(4)
        }
      } else if format == 12 {
        parse_format12(bytes, sub, map)
        if !formats.contains(12) {
          formats.push(12)
        }
      }
    }
  }
  (map, formats)
}

///|
fn parse_format4(
  bytes : Bytes,
  sub : Int,
  map : Map[Int, Int],
) -> Unit raise FontError {
  let seg_count_x2 = ru16(bytes, sub + 6)
  let seg_count = seg_count_x2 / 2
  let end_base = sub + 14
  let start_base = sub + 16 + seg_count_x2
  let delta_base = sub + 16 + seg_count_x2 * 2
  let range_base = sub + 16 + seg_count_x2 * 3
  let mut segment = 0
  let mut steps = 0
  while segment < seg_count && steps < 200000 {
    let end_code = ru16(bytes, end_base + segment * 2)
    let start_code = ru16(bytes, start_base + segment * 2)
    let delta = ru16(bytes, delta_base + segment * 2)
    let range_offset = ru16(bytes, range_base + segment * 2)
    if start_code <= end_code && start_code != 0xFFFF {
      let mut code = start_code
      while code <= end_code && steps < 200000 {
        let mut glyph = 0
        if range_offset == 0 {
          glyph = (code + delta) & 0xFFFF
        } else {
          let glyph_at = range_base +
            segment * 2 +
            range_offset +
            (code - start_code) * 2
          glyph = ru16(bytes, glyph_at)
          if glyph != 0 {
            glyph = (glyph + delta) & 0xFFFF
          }
        }
        if glyph != 0 && !map.contains(code) {
          map.set(code, glyph)
        }
        code = code + 1
        steps = steps + 1
      }
    }
    segment = segment + 1
  }
}

///|
fn parse_format12(
  bytes : Bytes,
  sub : Int,
  map : Map[Int, Int],
) -> Unit raise FontError {
  let groups = ru32(bytes, sub + 12)
  let mut i = 0
  let mut steps = 0
  while i < groups && steps < 400000 {
    let at = sub + 16 + i * 12
    let start_code = ru32(bytes, at)
    let end_code = ru32(bytes, at + 4)
    let start_glyph = ru32(bytes, at + 8)
    if start_code <= end_code && end_code <= 0x10FFFF {
      let mut code = start_code
      while code <= end_code && steps < 400000 {
        let glyph = start_glyph + (code - start_code)
        if glyph != 0 && !map.contains(code) {
          map.set(code, glyph)
        }
        code = code + 1
        steps = steps + 1
      }
    }
    i = i + 1
  }
}

// ---------------------------------------------------------------------------
// 重建
// ---------------------------------------------------------------------------

///|
/// 把有序的 (码点, 字形) 对压缩成连续段：相邻码点且字形也连续时合并。
/// 返回 (start_code, end_code, start_glyph)。
fn build_segments(pairs : Array[(Int, Int)]) -> Array[(Int, Int, Int)] {
  let segments : Array[(Int, Int, Int)] = []
  let mut i = 0
  while i < pairs.length() {
    let start = pairs[i].0
    let glyph = pairs[i].1
    let mut j = i
    let mut contiguous = true
    while contiguous && j + 1 < pairs.length() {
      if pairs[j + 1].0 == pairs[j].0 + 1 && pairs[j + 1].1 == pairs[j].1 + 1 {
        j = j + 1
      } else {
        contiguous = false
      }
    }
    segments.push((start, pairs[j].0, glyph))
    i = j + 1
  }
  segments
}

///|
/// 计算格式 4 头部里的 searchRange / entrySelector / rangeShift。
fn format4_search_fields(seg_count : Int) -> (Int, Int, Int) {
  let mut power = 1
  let mut selector = 0
  while power * 2 <= seg_count {
    power = power * 2
    selector = selector + 1
  }
  let search_range = power * 2
  (search_range, selector, seg_count * 2 - search_range)
}

///|
fn build_format4(pairs : Array[(Int, Int)]) -> Array[Byte] {
  let bmp : Array[(Int, Int)] = []
  for pair in pairs {
    if pair.0 <= 0xFFFF {
      bmp.push(pair)
    }
  }
  let segments = build_segments(bmp)
  let seg_count = segments.length() + 1
  let (search_range, selector, range_shift) = format4_search_fields(seg_count)
  let out : Array[Byte] = []
  push_u16(out, 4)
  push_u16(out, 16 + 8 * seg_count)
  push_u16(out, 0)
  push_u16(out, seg_count * 2)
  push_u16(out, search_range)
  push_u16(out, selector)
  push_u16(out, range_shift)
  for segment in segments {
    push_u16(out, segment.1)
  }
  push_u16(out, 0xFFFF)
  push_u16(out, 0) // reservedPad
  for segment in segments {
    push_u16(out, segment.0)
  }
  push_u16(out, 0xFFFF)
  for segment in segments {
    push_u16(out, (segment.2 - segment.0) & 0xFFFF)
  }
  push_u16(out, 1)
  let mut i = 0
  while i < seg_count {
    push_u16(out, 0)
    i = i + 1
  }
  out
}

///|
fn build_format12(pairs : Array[(Int, Int)]) -> Array[Byte] {
  let segments = build_segments(pairs)
  let out : Array[Byte] = []
  push_u16(out, 12)
  push_u16(out, 0)
  push_u32(out, 16 + 12 * segments.length())
  push_u32(out, 0)
  push_u32(out, segments.length())
  for segment in segments {
    push_u32(out, segment.0)
    push_u32(out, segment.1)
    push_u32(out, segment.2)
  }
  out
}

///|
/// 生成 cmap 表：一组 (3,1) 格式 4，加一组覆盖全平面的 (3,10) 格式 12。
fn build_cmap(pairs : Array[(Int, Int)]) -> Bytes {
  let sub4 = build_format4(pairs)
  let sub12 = build_format12(pairs)
  let header_length = 4 + 8 * 2
  let out : Array[Byte] = []
  push_u16(out, 0)
  push_u16(out, 2)
  push_u16(out, 3)
  push_u16(out, 1)
  push_u32(out, header_length)
  push_u16(out, 3)
  push_u16(out, 10)
  push_u32(out, header_length + sub4.length())
  for value in sub4 {
    out.push(value)
  }
  for value in sub12 {
    out.push(value)
  }
  bytes_of(out)
}
