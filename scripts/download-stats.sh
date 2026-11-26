#!/bin/bash
# README のバッジ（Mac 版のダウンロード数）と「1 日ごとのダウンロード」のグラフを数え直して、stats ブランチに書く
# （stats.json と、scripts/download-chart.py が作る downloads-ja.svg・downloads-en.svg・downloads-zh.svg を 1 つのコミットで）。
#   scripts/download-stats.sh            数え直して、変わっていれば stats ブランチに書く（無ければ作る）
#   scripts/download-stats.sh --dry-run  書かずに、数え直した stats.json を出すだけ
#   scripts/download-stats.sh --force    数が変わっていなくても書く（グラフの見た目を変えたときに）
# 数えるもの：リリースに付けた .zip（と .dmg）のダウンロード（= Mac 版。紹介ページのボタンは最新のリリースの Hotaru.zip）。
#   GitHub は累計しか出さないので、その日（UTC）の累計と数えた時刻を daily に貯め、版ごとの数（公開した時刻つき）を releases に置く。
#   グラフ（download-chart.py）は、記録の間に増えた分と、記録を始める前の版ごとの数を、時間に比例して日に分ける（推定）。
# stats ブランチは main とは履歴を共有しない、データだけのブランチ（main の README と配布物には触れない）。
# 自分の clone を数に入れないよう、リポジトリは clone しない（GitHub の API で読み書きする）。
# 書くには、このリポジトリの contents: write が要る（GitHub Actions では .github/workflows/stats.yml が宣言する GITHUB_TOKEN、手元では gh のログイン）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${HOTARU_REPO:-Rhizobium-gits/hotaru-mac}"
BRANCH="${HOTARU_STATS_BRANCH:-stats}"
DRY=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh（GitHub CLI）が要ります" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq が要ります" >&2; exit 1; }

# 貯めてある分（stats ブランチや stats.json が無いときは空から）
OLD='{}'
BRANCH_EXISTS=0
if gh api "repos/$REPO/branches/$BRANCH" --silent 2>/dev/null; then
  BRANCH_EXISTS=1
  if gh api "repos/$REPO/contents/stats.json?ref=$BRANCH" --silent 2>/dev/null; then
    OLD="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/stats.json?ref=$BRANCH")"
    printf '%s' "$OLD" | jq -e 'type == "object"' >/dev/null || { echo "stats.json を読めません" >&2; exit 1; }
  fi
fi

TODAY="$(date -u +%Y-%m-%d)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 版ごとの Mac 版（.zip・.dmg）のダウンロード数と公開した時刻（下書きは除く）
RELEASES="$(gh api "repos/$REPO/releases" --paginate --jq '.[] | select(.draft | not) | {tag: .tag_name, published: .published_at,
  mac: ([.assets[] | select(.name | test("\\.(zip|dmg)$"; "i")) | .download_count] | add // 0)}' | jq -s 'sort_by(.published)')"

# auralune.tech のダウンロードのボタンが押された数（https://auralune.tech/dl/hotaru-mac を通った数）。
# リリースのファイルへ送るので、上のダウンロード数の内訳（total には足さない）。シークレット AURALUNE_STATS_KEY で読む。
# 読めないときは貯めてある数のまま
SITE=null
if [[ -n "${AURALUNE_STATS_KEY:-}" ]]; then
  SITE="$(curl -fsS --max-time 30 "https://auralune.tech/api/dl-stats?key=$AURALUNE_STATS_KEY&format=json" |
    jq --arg ids "${AURALUNE_SITE_IDS:-hotaru-mac}" '($ids | split(",")) as $w | [.products[] | select(.id as $i | $w | index($i)) | .total] | add // 0')" || SITE=null
  [[ "$SITE" =~ ^[0-9]+$ ]] || { echo "auralune.tech の数を読めませんでした。貯めてある数のままにします" >&2; SITE=null; }
fi

NEW="$(jq -n --argjson site "$SITE" --argjson old "$OLD" --argjson releases "$RELEASES" --arg today "$TODAY" --arg now "$NOW" '
  ([$releases[] | .mac] | add // 0) as $mac
  | ($old.daily // {}) as $daily
  # 今日の累計：数が変わったときだけ時刻を新しくする（リリースがまだ無い日は記録しない）
  | (if ($releases | length) == 0 then $daily
     else ($daily + {($today): (if ($daily[$today].mac == $mac) then $daily[$today] else {mac: $mac, at: $now} end)})
     end | to_entries | sort_by(.key) | from_entries) as $days
  | {total: $mac, mac: $mac, daily: $days, releases: $releases, site: (if $site == null then ($old.site // 0) else $site end)}')"

if [[ $DRY == 1 ]]; then
  printf '%s\n' "$NEW" | jq .
  exit 0
fi

# 数が変わっていなければ書かない（書くたびに stats ブランチにコミットが 1 つ増えるので）。初めての日は書く
if [[ $FORCE == 0 && $BRANCH_EXISTS == 1 && "$(printf '%s' "$OLD" | jq -S 'del(.updated)')" == "$(printf '%s' "$NEW" | jq -S .)" ]]; then
  echo "変わっていません: $(printf '%s' "$NEW" | jq -c '{total, releases: (.releases | length)}')"
  exit 0
fi

if [[ $BRANCH_EXISTS == 0 ]]; then
  # 履歴を持たない、データだけのブランチを作る（main の履歴とは別）
  TREE="$(jq -n '{tree: [{path: "README.md", mode: "100644", type: "blob",
    content: "Data for the download badge and chart in the README of the main branch (written by scripts/download-stats.sh and .github/workflows/stats.yml). Not part of the website.\n"}]}' |
    gh api -X POST "repos/$REPO/git/trees" --input - --jq .sha)"
  COMMIT="$(jq -n --arg tree "$TREE" '{message: "Start the download stats branch", tree: $tree, parents: []}' |
    gh api -X POST "repos/$REPO/git/commits" --input - --jq .sha)"
  jq -n --arg ref "refs/heads/$BRANCH" --arg sha "$COMMIT" '{ref: $ref, sha: $sha}' |
    gh api -X POST "repos/$REPO/git/refs" --input - --silent
fi

BODY="$(printf '%s' "$NEW" | jq --arg now "$NOW" '{updated: $now} + .')"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
printf '%s\n' "$BODY" > "$WORK/stats.json"
python3 "$HERE/download-chart.py" "$WORK/stats.json" "$WORK"

HEAD_SHA="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
BASE_TREE="$(gh api "repos/$REPO/git/commits/$HEAD_SHA" --jq .tree.sha)"
TREE="$(jq -n --arg base "$BASE_TREE" \
  --rawfile stats "$WORK/stats.json" --rawfile ja "$WORK/downloads-ja.svg" \
  --rawfile en "$WORK/downloads-en.svg" --rawfile zh "$WORK/downloads-zh.svg" '
  {base_tree: $base, tree: [
    {path: "stats.json", mode: "100644", type: "blob", content: $stats},
    {path: "downloads-ja.svg", mode: "100644", type: "blob", content: $ja},
    {path: "downloads-en.svg", mode: "100644", type: "blob", content: $en},
    {path: "downloads-zh.svg", mode: "100644", type: "blob", content: $zh}]}' |
  gh api -X POST "repos/$REPO/git/trees" --input - --jq .sha)"
MSG="Download stats: $(printf '%s' "$NEW" | jq -r '"\(.total) Mac downloads"')"
COMMIT="$(jq -n --arg msg "$MSG" --arg tree "$TREE" --arg parent "$HEAD_SHA" '{message: $msg, tree: $tree, parents: [$parent]}' |
  gh api -X POST "repos/$REPO/git/commits" --input - --jq .sha)"
jq -n --arg sha "$COMMIT" '{sha: $sha}' | gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" --input - --silent
echo "書きました: $(printf '%s' "$NEW" | jq -c '{total, releases: (.releases | length)}')"
