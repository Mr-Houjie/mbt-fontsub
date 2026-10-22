// 字体模型。
//
// 解析结果只保留子集化真正需要的字段：表目录、度量、loca 与 cmap。
// 原始字节一直保留，后续按需切片，避免重复拷贝大字体。

///|
pub(all) struct TableRecord {
  tag : String
  checksum : UInt
  offset : Int
  length : Int
}

///|
pub(all) struct Font {
  bytes : Bytes
  tables : Map[String, TableRecord]
  units_per_em : Int
  num_glyphs : Int
  index_to_loc_format : Int
  loca : Array[Int]
  advances : Array[Int]
  lsbs : Array[Int]
  num_h_metrics : Int
  ascender : Int
  descender : Int
  cmap : Map[Int, Int]
  cmap_formats : Array[Int]
}
