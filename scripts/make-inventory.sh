#!/usr/bin/env bash
# 在仓库根目录运行：生成 INVENTORY.txt（md5 + 字节数 + 相对路径），便于重装后核对文件完整性
cd "$(dirname "$0")/.." || exit 1
find . -type f ! -name INVENTORY.txt ! -path './.git/*' | sort | while read -r f; do   # 排除 INVENTORY.txt 自身与 .git（否则在 clone 里跑会多算几十个 git 内部文件）
  printf '%s  %8d  %s\n' "$(md5sum "$f" | cut -c1-32)" "$(stat -c%s "$f")" "${f#./}"
done > INVENTORY.txt
echo "INVENTORY.txt: $(wc -l < INVENTORY.txt) files"
