// mbt-fontsub 命令行入口。
//
// 核心逻辑全部在库包 `Mr-Houjie/mbt-fontsub`；这里只做参数解析、
// 文件读写、结果输出与退出码。

///|
const VERSION : String = "0.1.0"

///|
fn usage() -> String {
  let out = StringBuilder()
  out.write_string("mbt-fontsub \{VERSION} — TrueType 字体子集化\n\n")
  out.write_string("用法：\n")
  out.write_string("  mbt-fontsub info <字体> [--face N]\n")
  out.write_string(
    "  mbt-fontsub subset <字体> --text <文本> [-o 输出] [--face N]\n",
  )
  out.write_string(
    "  mbt-fontsub verify <字体> --text <文本> [--face N]\n\n",
  )
  out.write_string("说明：\n")
  out.write_string(
    "  info    打印 units/em、字形数、TTC 面数、表目录与 cmap 格式\n",
  )
  out.write_string(
    "  subset  按文本子集化并写出新字体，同时打印体积变化\n",
  )
  out.write_string(
    "  verify  在内存中完成子集化并自检，不写文件\n",
  )
  out.write_string("  --face  TTC 集合中的字体面下标，默认 0\n\n")
  out.write_string(
    "退出码：0 成功；1 自检失败；2 用法或读写错误\n",
  )
  out.to_string()
}

///|
fn flag_value(args : Array[String], name : String) -> String? {
  let mut i = 0
  while i + 1 < args.length() {
    if args[i] == name {
      return Some(args[i + 1])
    }
    i = i + 1
  }
  None
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
fn parse_face(args : Array[String]) -> Int {
  match flag_value(args, "--face") {
    Some(value) => @string.parse_int(value) catch { _ => 0 }
    None => 0
  }
}

///|
fn load_font(path : String, face : Int) -> Result[(@lib.Font, Int), String] {
  match (Some(@fs.read_file_to_bytes(path)) catch { _ => None }) {
    None => Err("无法读取字体：\{path}")
    Some(data) =>
      Ok((@lib.parse_font_face(data, face), @lib.ttc_face_count(data))) catch {
        error => Err("解析失败：\{@lib.font_error_message(error)}")
      }
  }
}

///|
fn print_info(font : @lib.Font, faces : Int) -> Unit {
  println("units/em     : \{font.units()}")
  println("字形数       : \{font.glyph_count()}")
  println("TTC 面数     : \{faces}")
  println("字符映射数   : \{font.cmap.length()}")
  let mut formats = ""
  for format in font.cmap_formats {
    if formats.length() > 0 {
      formats = formats + ", "
    }
    formats = formats + format.to_string()
  }
  println("cmap 格式    : \{formats}")
  println("文件大小     : \{font.bytes.length()} 字节")
  let tags = font.table_tags()
  let mut line = ""
  for tag in tags {
    line = line + tag + " "
  }
  println("表目录       : \{line}")
}

///|
fn run_subset(path : String, text : String, output : String, face : Int) -> Int {
  match load_font(path, face) {
    Err(message) => {
      println(message)
      2
    }
    Ok(pair) => {
      let font = pair.0
      let chars = chars_of(text)
      match (Some(@lib.subset_by_text(font, text)) catch { _ => None }) {
        None => {
          println("子集化失败")
          1
        }
        Some(subset) => {
          @fs.write_bytes_to_file(output, subset) catch {
            _ => {
              println("无法写入：\{output}")
              return 2
            }
          }
          let report = @lib.verify_subset(font, subset, chars)
          println("已写出       : \{output}")
          println(
            "体积         : \{report.original_size} → \{report.subset_size} 字节" +
            "（省 \{report.savings_percent}%）",
          )
          println(
            "字符 / 字形  : \{report.chars_checked} / \{report.glyphs}（原 \{font.glyph_count()}）",
          )
          if report.ok {
            println("自检         : 通过")
            0
          } else {
            println(
              "自检         : 失败（\{report.failures.length()} 项）",
            )
            for failure in report.failures {
              println("  - \{failure}")
            }
            1
          }
        }
      }
    }
  }
}

///|
fn run_verify(path : String, text : String, face : Int) -> Int {
  match load_font(path, face) {
    Err(message) => {
      println(message)
      2
    }
    Ok(pair) => {
      let font = pair.0
      let chars = chars_of(text)
      match (Some(@lib.subset_by_text(font, text)) catch { _ => None }) {
        None => {
          println("子集化失败")
          1
        }
        Some(subset) => {
          let report = @lib.verify_subset(font, subset, chars)
          println(
            "字符 / 字形  : \{report.chars_checked} / \{report.glyphs}（原 \{font.glyph_count()}）",
          )
          println(
            "体积         : \{report.original_size} → \{report.subset_size} 字节" +
            "（省 \{report.savings_percent}%）",
          )
          if report.ok {
            println("自检         : 通过")
            0
          } else {
            println(
              "自检         : 失败（\{report.failures.length()} 项）",
            )
            for failure in report.failures {
              println("  - \{failure}")
            }
            1
          }
        }
      }
    }
  }
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println(usage())
    @sys.exit(2)
  }
  let command = args[1]
  if command == "-h" || command == "--help" || command == "help" {
    println(usage())
    @sys.exit(0)
  }
  if command == "-v" || command == "--version" {
    println(VERSION)
    @sys.exit(0)
  }
  if args.length() < 3 {
    println(usage())
    @sys.exit(2)
  }
  let path = args[2]
  let face = parse_face(args)
  if command == "info" {
    match load_font(path, face) {
      Err(message) => {
        println(message)
        @sys.exit(2)
      }
      Ok(pair) => {
        print_info(pair.0, pair.1)
        @sys.exit(0)
      }
    }
  } else if command == "subset" {
    let text = match flag_value(args, "--text") {
      Some(value) => value
      None => ""
    }
    let output = match flag_value(args, "-o") {
      Some(value) => value
      None => path + ".subset.ttf"
    }
    @sys.exit(run_subset(path, text, output, face))
  } else if command == "verify" {
    let text = match flag_value(args, "--text") {
      Some(value) => value
      None => ""
    }
    @sys.exit(run_verify(path, text, face))
  } else {
    println(usage())
    @sys.exit(2)
  }
}
