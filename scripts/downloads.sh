#!/bin/bash
# Mac 版 Hotaru のダウンロード数を見る（GitHub が数えている、リリースに付けたファイルごとの download_count）。
#   scripts/downloads.sh            リリースごと・ファイルごとの数と合計
#   scripts/downloads.sh --traffic  あわせて、直近 14 日のリポジトリの閲覧数・clone 数（push できる人だけ見られる）
#   scripts/downloads.sh --json     リリースごと・ファイルごとの数を JSON で
# 数え方：
#   Mac 版 = リリースに付けた .zip（と .dmg）のダウンロード。紹介ページ（hotaru-ai.vercel.app）の「ダウンロード」のボタンは
#            releases/latest/download/Hotaru.zip を指すので、ボタンからのダウンロードは最新のリリースの Hotaru.zip に入る
#   SHA256SUMS.txt など、それ以外のファイルは「ほか」として別に数える（人数には数えない）
# GitHub は同じ人の 2 回目も数える。リポジトリの clone・ソースの zip（Source code）は数えない
# 1 日ごとのグラフと README のバッジは scripts/download-stats.sh が stats ブランチに書く
set -euo pipefail
REPO="${HOTARU_REPO:-Rhizobium-gits/hotaru-mac}"
TRAFFIC=0
JSON=0
for a in "$@"; do
  case "$a" in
    --traffic) TRAFFIC=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh（GitHub CLI）が要ります: brew install gh" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq が要ります: brew install jq" >&2; exit 1; }

# 下書きを除いた、リリースごとの数（新しい順）
RELEASES="$(gh api "repos/$REPO/releases" --paginate --jq '.[] | select(.draft | not) | {
  tag: .tag_name,
  published: (.published_at // ""),
  prerelease: .prerelease,
  assets: [.assets[] | {name, downloads: .download_count}]
}' | jq -s '
  map(. + {
    mac: ([.assets[] | select(.name | test("\\.(zip|dmg)$"; "i")) | .downloads] | add // 0),
    other: ([.assets[] | select(.name | test("\\.(zip|dmg)$"; "i") | not) | .downloads] | add // 0)
  }) | sort_by(.published) | reverse')"

if [[ $JSON == 1 ]]; then
  printf '%s' "$RELEASES" | jq '{
    repo: "'"$REPO"'",
    mac: ([.[].mac] | add // 0),
    other: ([.[].other] | add // 0),
    releases: .
  }'
  exit 0
fi

COUNT="$(printf '%s' "$RELEASES" | jq length)"
if [[ "$COUNT" == 0 ]]; then
  echo "$REPO にはまだリリースがありません（下書きは数えません）"
else
  printf '%s' "$RELEASES" | jq -r '.[] |
    "\(.tag)\t\(.published[0:10])\t\(.mac)\t\(.other)",
    (.assets[] | "  \(.name)\t\t\(.downloads)")' |
  awk -F'\t' '
    # 見出しと「合計」は全角を含むので、表示の幅で手で揃える（awk の幅はバイト数）
    BEGIN { print "版 / ファイル                      公開日        Mac 版     ほか" }
    /^  / { printf "  %-32s %-11s %8s\n", substr($1, 3), "", $3; next }
    { printf "%-34s %-11s %8d %8d\n", $1, $2, $3, $4; m += $3; o += $4 }
    END {
      printf "合計%30s %-11s %8d %8d\n", "", "", m, o
      print ""
      print "Mac 版 = リリースの .zip（と .dmg）のダウンロード。紹介ページのボタンは最新のリリースの Hotaru.zip"
    }'
fi

if [[ $TRAFFIC == 1 ]]; then
  echo
  if V="$(gh api "repos/$REPO/traffic/views" --jq '"\(.count)\t\(.uniques)"' 2>/dev/null)" &&
     C="$(gh api "repos/$REPO/traffic/clones" --jq '"\(.count)\t\(.uniques)"' 2>/dev/null)"; then
    printf '直近 14 日：リポジトリのページの閲覧 %s 回（%s 人）・clone %s 回（%s 人）\n' \
      "${V%%$'\t'*}" "${V##*$'\t'}" "${C%%$'\t'*}" "${C##*$'\t'}"
    echo "（紹介ページ rhizobium-gits.github.io/hotaru の閲覧数は GitHub から読めません）"
  else
    echo "閲覧数・clone 数は、このリポジトリに push できるアカウントでだけ見られます（gh auth status で確かめてください）"
  fi
fi
