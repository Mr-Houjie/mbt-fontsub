// 共享用例：`moon test` 与 `cmd/verify` 使用同一份输入，
// 避免测试与自检各写一套、结论不一致。

///|
pub(all) struct SubsetCase {
  name : String
  text : String
}

///|
pub fn default_cases() -> Array[SubsetCase] {
  [
    { name: "latin", text: "Hello, MoonBit!", },
    { name: "pangram", text: "The quick brown fox jumps over the lazy dog", },
    { name: "digits", text: "0123456789", },
    { name: "punct", text: "!@#$%^&*()_+-=[]{};':\",./<>?", },
    { name: "empty", text: "", },
  ]
}

///|
/// 中文字符集，供带 CJK 字形的语料使用；字体缺字时不会强行断言。
pub fn cjk_case() -> SubsetCase {
  {
    name: "cjk",
    text: "你好，世界！这是一个中文字体子集化测试。",
  }
}
