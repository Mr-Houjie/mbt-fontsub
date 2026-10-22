// 子集结果自检：不依赖外部工具，用同一套解析器回读并逐项比对。
//
// 这是项目的「终点」判据：子集字体必须能被重新解析、覆盖请求的字符、
// 度量与原字体一致、复合字形组件编号合法、目录校验和与整字体校验和自洽。
// 调用方还可以通过 `SubsetOptions::with_validator` 追加自己的验收规则。

///|
pub(all) struct VerifyReport {
  ok : Bool
  chars_checked : Int
  glyphs : Int
  original_size : Int
  subset_size : Int
  savings_percent : Double
  failures : Array[String]
}

///|
/// 用默认策略子集化并自检。
pub fn verify_subset(
  original : Font,
  subset_bytes : Bytes,
  chars : Array[Int],
) -> VerifyReport {
  verify_subset_with(original, subset_bytes, chars, SubsetOptions::default())
}

///|
/// 子集化自检；`options.validators` 中的规则会在内建检查之后执行。
pub fn verify_subset_with(
  original : Font,
  subset_bytes : Bytes,
  chars : Array[Int],
  options : SubsetOptions,
) -> VerifyReport {
  let failures : Array[String] = []
  let subset_opt : Font? = Some(parse_font(subset_bytes)) catch { _ => None }
  let mut glyphs = 0
  let mut checked = 0
  match subset_opt {
    None => failures.push("子集字体无法被重新解析")
    Some(subset) => {
      glyphs = subset.num_glyphs
      if subset.units_per_em != original.units_per_em {
        failures.push("unitsPerEm 与原字体不一致")
      }
      let mut i = 0
      let seen : Map[Int, Bool] = Map([])
      while i < chars.length() {
        let code = chars[i]
        i = i + 1
        if seen.contains(code) {
          continue
        }
        seen.set(code, true)
        match original.cmap.get(code) {
          Some(glyph) =>
            if glyph > 0 {
              checked = checked + 1
              match subset.cmap.get(code) {
                None => failures.push("缺少字符 U+\{hex(code)}")
                Some(new_glyph) =>
                  if new_glyph <= 0 || new_glyph >= subset.num_glyphs {
                    failures.push("字符 U+\{hex(code)} 的字形编号越界")
                  } else {
                    if new_glyph >= subset.advances.length() {
                      failures.push("字符 U+\{hex(code)} 缺少水平度量")
                    } else if subset.advances[new_glyph] !=
                      original.advances[glyph] {
                      failures.push(
                        "字符 U+\{hex(code)} 的前进宽度被改变",
                      )
                    }
                    let original_length = original.loca[glyph + 1] -
                      original.loca[glyph]
                    let new_length = subset.loca[new_glyph + 1] -
                      subset.loca[new_glyph]
                    if original_length > 0 && new_length == 0 {
                      failures.push(
                        "字符 U+\{hex(code)} 的字形数据为空",
                      )
                    }
                  }
              }
            }
          None => ()
        }
      }
      // 复合字形闭包：所有组件编号必须落在新字体范围内
      let mut glyph = 0
      while glyph < subset.num_glyphs {
        let components = component_gids(subset, glyph) catch { _ => [] }
        for component in components {
          if component >= subset.num_glyphs {
            failures.push(
              "复合字形 \{glyph} 引用了越界组件 \{component}",
            )
          }
        }
        glyph = glyph + 1
      }
      verify_checksums(subset, failures) catch {
        _ => failures.push("校验和复核失败")
      }
      for validator in options.validators {
        for failure in validator(original, subset, chars) {
          failures.push(failure)
        }
      }
    }
  }
  let original_size = original.bytes.length()
  let subset_size = subset_bytes.length()
  let savings = if original_size == 0 {
    0.0
  } else {
    (1.0 - subset_size.to_double() / original_size.to_double()) * 100.0
  }
  {
    ok: failures.length() == 0,
    chars_checked: checked,
    glyphs,
    original_size,
    subset_size,
    savings_percent: savings,
    failures,
  }
}

///|
/// 复核表目录校验和与整字体校验和。
///
/// `head.checkSumAdjustment` 在计算 head 表校验和时必须视为 0，
/// 而整字体校验和必须等于 0xB1B0AFBA——这两条是「文件结构自洽」的硬判据。
fn verify_checksums(
  subset : Font,
  failures : Array[String],
) -> Unit raise FontError {
  for entry in subset.tables {
    let tag = entry.0
    let record = entry.1
    let sum = if tag == "head" {
      let copy : Array[Byte] = []
      push_range(copy, subset.bytes, record.offset, record.length)
      if copy.length() >= 12 {
        copy[8] = Byte::default()
        copy[9] = Byte::default()
        copy[10] = Byte::default()
        copy[11] = Byte::default()
      }
      checksum_range(bytes_of(copy), 0, copy.length())
    } else {
      checksum_range(subset.bytes, record.offset, record.length)
    }
    if sum != record.checksum {
      failures.push("表 \{tag} 的校验和与目录不一致")
    }
  }
  let total = checksum_range(subset.bytes, 0, subset.bytes.length())
  let magic : UInt = 0xB1B0AFBA
  if total != magic {
    failures.push("整字体校验和不等于 0xB1B0AFBA")
  }
}

///|
/// 码点的十六进制表示，用于稳定的错误信息。
pub fn hex(code : Int) -> String {
  code.to_string(radix=16)
}
