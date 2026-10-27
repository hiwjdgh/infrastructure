#!/usr/bin/env bash
# COPY INTO EVERY APP REPO: .github/scripts/release-notes.sh  (pr-changelog.yml, release.yml 에서 사용)
# Usage: release-notes.sh <base-ref|""> <head-ref> <out-dir>
# base..head 사이의 커밋 메시지(Conventional Commits)로 다음 버전과 changelog 를 계산합니다. base 가 비어 있으면 전체 이력.
#   <out-dir>/current  직전 릴리스 태그 (없으면 v0.0.0)
#   <out-dir>/version  다음 버전 vX.Y.Z (반영할 커밋이 없으면 빈 파일)
#   <out-dir>/bump     major | minor | patch
#   <out-dir>/count    반영된 커밋 수
#   <out-dir>/notes.md changelog (Markdown)
# 버전 규칙: feat!: / 본문 BREAKING CHANGE: → major, feat: → minor, 그 외 → patch
# 머지 커밋(dev 당겨오기, PR 머지)은 제외합니다. dev 와 main 모두 merge commit 으로만 머지하므로 개별 커밋이 그대로 남습니다.
set -euo pipefail
BASE="${1:-}"; HEAD="${2:?head ref required}"; OUT="${3:?out dir required}"
mkdir -p "$OUT"
CURRENT=""
[[ -z "$BASE" ]] || CURRENT="$(git tag --merged "$BASE" --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | sed -n 1p)"
CURRENT="${CURRENT:-v0.0.0}"
RANGE="$HEAD"; [[ -z "$BASE" ]] || RANGE="$BASE..$HEAD"
REPO_URL=""; [[ -z "${GITHUB_REPOSITORY:-}" ]] || REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"

BREAKING=(); FEAT=(); FIX=(); PERF=(); OTHER=()
BUMP=""; COUNT=0
RE='^([a-z]+)(\(([^)]+)\))?(!)?:[[:space:]]*(.+)$'
while IFS= read -r -d $'\x1e' rec; do
  rec="${rec#$'\n'}"
  sha="${rec%%$'\x1f'*}"; rest="${rec#*$'\x1f'}"
  author="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
  subject="${rest%%$'\x1f'*}"; body="${rest#*$'\x1f'}"
  COUNT=$((COUNT + 1))
  if [[ "$subject" =~ $RE ]]; then
    type="${BASH_REMATCH[1]}"; scope="${BASH_REMATCH[3]}"; bang="${BASH_REMATCH[4]}"; desc="${BASH_REMATCH[5]}"
  else
    type=other; scope=""; bang=""; desc="$subject"
  fi
  ref="${sha:0:7}"; [[ -z "$REPO_URL" ]] || ref="[${sha:0:7}]($REPO_URL/commit/$sha)"
  line="- ${scope:+**$scope:** }$desc ($ref · $author)"
  if [[ -n "$bang" ]] || grep -qE '^BREAKING[ -]CHANGE:' <<< "$body"; then
    BREAKING+=("$line"); BUMP=major; continue
  fi
  case "$type" in
    feat) FEAT+=("$line"); [[ "$BUMP" == major ]] || BUMP=minor ;;
    fix)  FIX+=("$line") ;;
    perf) PERF+=("$line") ;;
    *)    OTHER+=("$line") ;;
  esac
  [[ -n "$BUMP" ]] || BUMP="patch"
done < <(git log --no-merges --reverse --format='%H%x1f%an%x1f%s%x1f%b%x1e' "$RANGE")

printf '%s\n' "$CURRENT" > "$OUT/current"
printf '%s\n' "$BUMP" > "$OUT/bump"
printf '%s\n' "$COUNT" > "$OUT/count"
if [[ -z "$BUMP" ]]; then
  : > "$OUT/version"
  printf '반영할 커밋이 없습니다.\n' > "$OUT/notes.md"
  exit 0
fi
IFS=. read -r MAJOR MINOR PATCH <<< "${CURRENT#v}"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac
printf 'v%s.%s.%s\n' "$MAJOR" "$MINOR" "$PATCH" > "$OUT/version"

section() { # $1=title, rest=lines
  local title="$1"; shift
  (( $# )) || return 0
  printf '### %s\n\n' "$title"; printf '%s\n' "$@"; printf '\n'
}
{
  section '⚠️ 호환성 깨짐 (Breaking Changes)' ${BREAKING[@]+"${BREAKING[@]}"}
  section '✨ 기능 추가' ${FEAT[@]+"${FEAT[@]}"}
  section '🐛 버그 수정' ${FIX[@]+"${FIX[@]}"}
  section '⚡ 성능 개선' ${PERF[@]+"${PERF[@]}"}
  section '🔧 기타' ${OTHER[@]+"${OTHER[@]}"}
} > "$OUT/notes.md"
