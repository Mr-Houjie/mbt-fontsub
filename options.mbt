// 子集化扩展点。
//
// 默认行为等价于 `SubsetOptions::default()`：保留名称/度量/提示相关表，
// 丢弃布局表。调用方可以通过三种方式扩展，而不需要改库代码：
//   1. `keep_table` / `drop_table`：调整表保留策略；
//   2. `with_collector`：为某个字形补充额外依赖（例如 GSUB 连字闭包）；
//   3. `with_validator`：追加自定义验收规则。

///|
pub(all) struct SubsetOptions {
  /// 在默认白名单之外强制保留的表。
  keep_optional : Array[String]
  /// 从结果中额外丢弃的表。
  drop_extra : Array[String]
  /// 自定义字形收集器：给定字体与字形，返回额外需要收录的字形编号。
  collector : ((Font, Int) -> Array[Int])?
  /// 自定义验证器：输入原字体、子集字体与字符集，返回失败描述。
  validators : Array[(Font, Font, Array[Int]) -> Array[String]]
}

///|
pub fn SubsetOptions::default() -> SubsetOptions {
  { keep_optional: [], drop_extra: [], collector: None, validators: [], }
}

///|
/// 强制保留某张表。适用于 `GSUB` 这类需要调用方自行处理字形编号的表。
pub fn SubsetOptions::keep_table(
  self : SubsetOptions,
  tag : String,
) -> SubsetOptions {
  let next = self.keep_optional.copy()
  next.push(tag)
  {
    keep_optional: next,
    drop_extra: self.drop_extra,
    collector: self.collector,
    validators: self.validators,
  }
}

///|
/// 额外丢弃某张表。
pub fn SubsetOptions::drop_table(
  self : SubsetOptions,
  tag : String,
) -> SubsetOptions {
  let next = self.drop_extra.copy()
  next.push(tag)
  {
    keep_optional: self.keep_optional,
    drop_extra: next,
    collector: self.collector,
    validators: self.validators,
  }
}

///|
/// 注册自定义字形收集器。
///
/// 收集器会对每个已选字形调用一次，返回的字形会继续参与闭包与编号重排。
/// 这为 GSUB 连字、数学字形变体等「字符之外的字形依赖」提供了扩展入口。
pub fn SubsetOptions::with_collector(
  self : SubsetOptions,
  collector : (Font, Int) -> Array[Int],
) -> SubsetOptions {
  {
    keep_optional: self.keep_optional,
    drop_extra: self.drop_extra,
    collector: Some(collector),
    validators: self.validators,
  }
}

///|
/// 注册自定义验证器。
pub fn SubsetOptions::with_validator(
  self : SubsetOptions,
  validator : (Font, Font, Array[Int]) -> Array[String],
) -> SubsetOptions {
  let next = self.validators.copy()
  next.push(validator)
  {
    keep_optional: self.keep_optional,
    drop_extra: self.drop_extra,
    collector: self.collector,
    validators: next,
  }
}

///|
/// 默认保留的可选表（必需表始终重建）。
pub fn default_optional_tables() -> Array[String] {
  ["name", "OS/2", "cvt ", "fpgm", "prep", "gasp", "post"]
}

///|
/// `tag` 是否应出现在子集结果中。
pub fn SubsetOptions::keeps_table(self : SubsetOptions, tag : String) -> Bool {
  if self.drop_extra.contains(tag) {
    false
  } else if self.keep_optional.contains(tag) {
    true
  } else {
    default_optional_tables().contains(tag)
  }
}
