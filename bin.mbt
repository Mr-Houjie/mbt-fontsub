// SFNT 字节层：大端读写、边界检查与校验和。
//
// 约定：
//   - 所有多字节整数按大端读取；
//   - 所有读取先做边界检查，任意输入都只会得到 FontError，不会越界；
//   - 校验和按 OpenType 规范以 32 位无符号累加，不足 4 字节的部分补 0。

///|
pub suberror FontError {
  FontTruncated
  FontNotSfnt
  FontUnsupported(String)
  FontMissingTable(String)
  FontBadTable(String)
  FontIo(String)
}

///|
pub fn font_error_message(error : FontError) -> String {
  match error {
    FontTruncated => "文件被截断：所需字节超出数据长度"
    FontNotSfnt =>
      "不是 TrueType/OpenType 字体（sfnt 版本号不匹配）"
    FontUnsupported(what) => "暂不支持：\{what}"
    FontMissingTable(tag) => "缺少必需表：\{tag}"
    FontBadTable(tag) => "表结构非法：\{tag}"
    FontIo(path) => "读取字体失败：\{path}"
  }
}

///|
fn need(bytes : Bytes, off : Int, len : Int) -> Unit raise FontError {
  if off < 0 || len < 0 || off + len > bytes.length() {
    raise FontTruncated
  }
}

///|
fn ru16(bytes : Bytes, off : Int) -> Int raise FontError {
  need(bytes, off, 2)
  (bytes.at(off).to_int() << 8) | bytes.at(off + 1).to_int()
}

///|
fn ri16(bytes : Bytes, off : Int) -> Int raise FontError {
  let value = ru16(bytes, off)
  if value >= 0x8000 {
    value - 0x10000
  } else {
    value
  }
}

///|
fn ru32(bytes : Bytes, off : Int) -> Int raise FontError {
  need(bytes, off, 4)
  (ru16(bytes, off) << 16) | ru16(bytes, off + 2)
}

///|
fn ru32u(bytes : Bytes, off : Int) -> UInt raise FontError {
  (ru16(bytes, off).reinterpret_as_uint() << 16) |
  ru16(bytes, off + 2).reinterpret_as_uint()
}

///|
fn tag_at(bytes : Bytes, off : Int) -> String raise FontError {
  need(bytes, off, 4)
  let mut tag = ""
  let mut i = 0
  while i < 4 {
    tag = tag + Int::unsafe_to_char(bytes.at(off + i).to_int()).to_string()
    i = i + 1
  }
  tag
}

// ---------------------------------------------------------------------------
// 写入
// ---------------------------------------------------------------------------

///|
fn push_u8(out : Array[Byte], value : Int) -> Unit {
  out.push((value & 0xFF).to_byte())
}

///|
fn push_u16(out : Array[Byte], value : Int) -> Unit {
  push_u8(out, value >> 8)
  push_u8(out, value)
}

///|
fn push_u32(out : Array[Byte], value : Int) -> Unit {
  push_u16(out, value >> 16)
  push_u16(out, value & 0xFFFF)
}

///|
fn write_u32u_at(out : Array[Byte], at : Int, value : UInt) -> Unit {
  let mask : UInt = 0xFF
  out[at] = ((value >> 24) & mask).to_byte()
  out[at + 1] = ((value >> 16) & mask).to_byte()
  out[at + 2] = ((value >> 8) & mask).to_byte()
  out[at + 3] = (value & mask).to_byte()
}

///|
fn push_zeros(out : Array[Byte], count : Int) -> Unit {
  let mut i = 0
  while i < count {
    out.push(Byte::default())
    i = i + 1
  }
}

///|
fn push_range(
  out : Array[Byte],
  bytes : Bytes,
  start : Int,
  length : Int,
) -> Unit raise FontError {
  need(bytes, start, length)
  let mut i = 0
  while i < length {
    out.push(bytes.at(start + i))
    i = i + 1
  }
}

///|
fn push_tag(out : Array[Byte], tag : String) -> Unit {
  let mut written = 0
  for ch in tag {
    if written < 4 {
      out.push(ch.to_int().to_byte())
      written = written + 1
    }
  }
  while written < 4 {
    out.push(Int::to_byte(0x20))
    written = written + 1
  }
}

///|
fn pad4(length : Int) -> Int {
  (length + 3) / 4 * 4
}

///|
fn bytes_of(out : Array[Byte]) -> Bytes {
  Bytes::from_iter(out.iter())
}

// ---------------------------------------------------------------------------
// 校验和
// ---------------------------------------------------------------------------

///|
fn checksum_range(bytes : Bytes, start : Int, length : Int) -> UInt {
  let mut sum : UInt64 = 0UL
  let mut i = 0
  while i < length {
    let mut word : UInt64 = 0UL
    let mut k = 0
    while k < 4 {
      let index = i + k
      let value = if index < length {
        bytes.at(start + index).to_int()
      } else {
        0
      }
      word = (word << 8) | value.to_uint64()
      k = k + 1
    }
    sum = sum + word
    i = i + 4
  }
  (sum & 0xFFFFFFFFUL).to_uint()
}
