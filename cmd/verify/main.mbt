// 一致性自检：不依赖 `moon test` 的嵌套进程，直接在目标平台运行。
//
// 每个用例走完整链路：解析 → 子集化 → 回读 → 度量/覆盖/闭包/校验和比对。
// 用法：
//   moon run cmd/verify                    # 跑仓库自带样本
//   moon run cmd/verify -- <字体> [字体...] # 对语料逐字体巡检

///|
fn chars_of(text : String) -> Array[Int] {
  let chars : Array[Int] = []
  for ch in text {
    chars.push(ch.to_int())
  }
  chars
}

///|
fn load_font(path : String) -> Result[@lib.Font, String] {
  match (Some(@fs.read_file_to_bytes(path)) catch { _ => None }) {
    None => Err("无法读取字体：\{path}")
    Some(data) =>
      Ok(@lib.parse_font(data)) catch {
        error => Err("解析失败：\{@lib.font_error_message(error)}")
      }
  }
}

///|
fn run_case(font : @lib.Font, name : String, text : String) -> Bool {
  let chars = chars_of(text)
  match (Some(@lib.subset_by_text(font, text)) catch { _ => None }) {
    None => {
      println("FAIL  \{name}：子集化失败")
      false
    }
    Some(subset) => {
      let report = @lib.verify_subset(font, subset, chars)
      if report.ok {
        println(
          "PASS  \{name}：\{report.chars_checked} 字符 / \{report.glyphs} 字形 / " +
          "\{report.original_size} → \{report.subset_size} 字节（省 \{report.savings_percent}%）",
        )
        true
      } else {
        println("FAIL  \{name}：\{report.failures.length()} 项不一致")
        for failure in report.failures {
          println("        - \{failure}")
        }
        false
      }
    }
  }
}

///|
fn run_font(path : String) -> Int {
  match load_font(path) {
    Err(message) => {
      println(message)
      1
    }
    Ok(font) => {
      println(
        "\n字体：\{path}（\{font.glyph_count()} 字形，\{font.units()} units/em，" +
        "\{font.bytes.length()} 字节）",
      )
      let mut failures = 0
      for case in @lib.default_cases() {
        if !run_case(font, case.name, case.text) {
          failures = failures + 1
        }
      }
      // 有 CJK 字形时才跑中文用例，避免对缺字字体做无意义断言
      let cjk = @lib.cjk_case()
      if font.has_glyph('你') {
        if !run_case(font, cjk.name, cjk.text) {
          failures = failures + 1
        }
      }
      failures
    }
  }
}

///|
fn main {
  let args = @env.args()
  let paths : Array[String] = []
  let mut i = 1
  while i < args.length() {
    paths.push(args[i])
    i = i + 1
  }
  if paths.length() == 0 {
    paths.push("tests/fixtures/VT323-Regular.ttf")
  }
  let mut failures = 0
  for path in paths {
    failures = failures + run_font(path)
  }
  if failures == 0 {
    println("\n全部用例通过。")
    @sys.exit(0)
  } else {
    println("\n\{failures} 个用例失败。")
    @sys.exit(1)
  }
}
