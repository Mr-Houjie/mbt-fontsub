#!/usr/bin/env python3
"""按 corpus/manifest.tsv 下载并校验字体语料。

字体不进仓库（体积大、许可证需随附），只提交清单：URL + SHA-256。
下载结果放在 corpus/fonts/，已存在且哈希一致时跳过。

用法：
  python tools/fetch_corpus.py
  python tools/fetch_corpus.py --manifest corpus/manifest.tsv --dest corpus/fonts
退出码：0 全部就绪；1 有下载或校验失败。
"""

import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", default=str(ROOT / "corpus" / "manifest.tsv"))
    parser.add_argument("--dest", default=str(ROOT / "corpus" / "fonts"))
    args = parser.parse_args()

    manifest = Path(args.manifest)
    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    failures = 0
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            print(f"FAIL 清单行格式错误：{line}")
            failures += 1
            continue
        name, url, expected, license_name = fields
        target = dest / name
        if target.exists() and sha256_of(target) == expected:
            print(f"OK   {name}（已缓存，{license_name}）")
            continue
        print(f"下载 {name} ...")
        try:
            urllib.request.urlretrieve(url, target)
        except Exception as exc:  # noqa: BLE001 - 网络错误需要原样报告
            print(f"FAIL {name}：下载失败 {exc}")
            failures += 1
            continue
        actual = sha256_of(target)
        if actual != expected:
            print(f"FAIL {name}：sha256 不匹配\n  期望 {expected}\n  实际 {actual}")
            failures += 1
            continue
        print(f"OK   {name}（{target.stat().st_size} 字节，{license_name}）")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
