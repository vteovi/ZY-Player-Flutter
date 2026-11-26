#!/usr/bin/env bash
# 生成 GitHub Release 的正文：从 更新记录.MD 里抓出当前版本那一节。
#
# 用法: bash tools/release-notes.sh <版本号> <输出文件> [仓库根目录]
#   例: bash tools/release-notes.sh 1.44.1 /tmp/notes.md .
#
# 可选环境变量：
#   NOTES_REF  链接要指向的 ref（默认取 GITHUB_REF_NAME，再退到 v<版本号>）。
#              补写历史 Release 正文时用它指定那个 tag。
#
# 抓取规则：以「## v<版本号>」开头的行算本节起点，遇到下一个「## v」结束。
# 版本号做行首精确比较（避免 v1.44.1 误命中 v1.44.10）。
#
# 为什么要脚本：Release 页面直接展示更新记录，用户点进来就知道这版改了什么，
# 不用再翻仓库里的 md 文件。取不到时写一段兜底说明，绝不让发布步骤失败。
set -euo pipefail

VER="${1:-}"
OUT="${2:-release-notes.md}"
ROOT="${3:-.}"

if [ -z "$VER" ]; then
  echo "用法: $0 <版本号> <输出文件> [仓库根目录]" >&2
  exit 2
fi

# 文件名带中文，个别环境大小写/编码不一致，两种写法都试一下
MD=""
for candidate in "$ROOT/更新记录.MD" "$ROOT/更新记录.md"; do
  if [ -f "$candidate" ]; then
    MD="$candidate"
    break
  fi
done

BODY=""
if [ -n "$MD" ]; then
  # index()==1 保证从行首匹配；再看紧跟版本号的那个字符是不是分隔符
  # （空格 / 全角破折号的首字节 0xE2 / 行尾），防止 v1.44.1 命中 v1.44.10
  BODY=$(awk -v want="## v$VER" '
    {
      if (inside) {
        if ($0 ~ /^## v/) exit
        print
        next
      }
      if (index($0, want) == 1) {
        rest = substr($0, length(want) + 1)
        if (rest == "" || substr(rest, 1, 1) == " " || substr(rest, 1, 1) == "\342") {
          inside = 1
          print
        }
      }
    }
  ' "$MD")
fi

if [ -z "$BODY" ]; then
  echo "::warning::更新记录.MD 里没有找到 v$VER 的条目，Release 正文只写通用说明"
  BODY="## v$VER

本版更新内容请见仓库根目录的 \`更新记录.MD\`。"
fi

# 正文里再给一个**可点击**的链接，用户不想只看这一版时能直接跳到完整更新
# 记录（含所有历史版本）。指向当前 tag 而不是 main：老版本的 Release 点进
# 去看到的仍是当时的记录，不会被后续改动带偏。
# 仓库名优先取 Actions 的 GITHUB_REPOSITORY，本地跑脚本时从 remote 反推。
REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO" ]; then
  REPO=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@[^:]*:##' -e 's#^ssh://git@[^/]*/##' \
          -e 's#^https\{0,1\}://[^/]*/##' -e 's#\.git$##' || true)
fi
# 文件名带中文，链接里用百分号编码（%E6%9B%B4... = 更新记录.MD），
# 各家 markdown 渲染器都能认。
REF="${NOTES_REF:-${GITHUB_REF_NAME:-v$VER}}"
NOTES_LINK=""
if [ -n "$REPO" ]; then
  NOTES_LINK="**完整更新记录（含全部历史版本）**：[更新记录.MD](https://github.com/$REPO/blob/$REF/%E6%9B%B4%E6%96%B0%E8%AE%B0%E5%BD%95.MD)"
fi

{
  printf '%s\n\n' "$BODY"
  if [ -n "$NOTES_LINK" ]; then
    printf '%s\n\n' "$NOTES_LINK"
  fi
  cat <<'EOF'
---

### 下载哪个包

| 文件 | 用在哪儿 |
| --- | --- |
| `ZY-Player-arm64-latest.apk` | 绝大多数手机（应用内更新也是取这个名字） |
| `ZY-Player-*-armv7.apk` | 老机型 / 32 位设备 |
| `ZY-Player-*-x86_64.apk` | 模拟器 |
| `ZY-Player-*-windows-x64.zip` | Windows 桌面版，解压后运行 `zy_player.exe` |

> 安装时若提示「应用未安装」：1.18.0 更换过正式签名，卸载旧版再装即可。
> Android 8 及以上需要在系统设置里允许「安装未知应用」。
EOF
} > "$OUT"

echo "已生成 Release 正文: $OUT （$VER）"
