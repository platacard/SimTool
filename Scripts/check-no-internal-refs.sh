#!/usr/bin/env bash
# Fails when the tree names something that belongs to the organization that
# develops SimTool rather than to SimTool: its apps, hosts, internal tools,
# issue keys, people. SimTool ships to everyone, so none of that may reach it.
#
# Usage: Scripts/check-no-internal-refs.sh [DIR | -]
#
#   DIR  what to scan, this repository by default. A git checkout is scanned by
#        its tracked and untracked-but-not-ignored files; any other directory by
#        every file outside hidden directories (a `git archive` snapshot, say).
#        File names are scanned too.
#   -    scans standard input instead, e.g. the commits about to be published:
#          git log --format='%an %ae%n%cn %ce%n%B' main | Scripts/check-no-internal-refs.sh -
#
# What counts as internal:
#
# - The organization's own terms, from the file SIMTOOL_INTERNAL_DENYLIST points
#   at: one case-insensitive extended regular expression (grep -E) per line,
#   blank lines and `#` comments ignored. The list names the organization, so
#   it never lives in this repository; keep it in private config. Unset, those
#   terms are not checked and a notice says so.
# - Always: issue-tracker keys, home directories of real users, and email
#   addresses other than example ones.
#
# The repository's own coordinates are allowed: install and package URLs cannot
# avoid naming the owner. They come from release-config.sh — the GitHub repo,
# the Homebrew tap repo and the tap's short name.
#
# Exit status: 0 nothing found, 1 something found, 2 the check could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release-config.sh"

usage() {
  sed -n '6,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

TARGET="${1:-$SCRIPT_DIR/..}"
if [[ "$TARGET" == "-h" || "$TARGET" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/simtool-internal-refs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Terms: the denylist without its comments and blank lines.
PATTERNS="$WORK/patterns"
: > "$PATTERNS"
if [[ -n "${SIMTOOL_INTERNAL_DENYLIST:-}" ]]; then
  if [[ ! -r "$SIMTOOL_INTERNAL_DENYLIST" || -d "$SIMTOOL_INTERNAL_DENYLIST" ]]; then
    echo "SIMTOOL_INTERNAL_DENYLIST names $SIMTOOL_INTERNAL_DENYLIST, which is not a readable file." >&2
    exit 2
  fi
  grep -v -E '^[[:space:]]*(#|$)' "$SIMTOOL_INTERNAL_DENYLIST" > "$PATTERNS" || true
  # A pattern grep cannot read would otherwise match nothing, quietly.
  if ! { grep -E -f "$PATTERNS" /dev/null 2>"$WORK/error" || [[ $? == 1 ]]; }; then
    echo "SIMTOOL_INTERNAL_DENYLIST has a pattern grep -E cannot read: $(cat "$WORK/error")" >&2
    exit 2
  fi
else
  echo "notice: SIMTOOL_INTERNAL_DENYLIST is not set, so the organization's own terms were not checked." >&2
fi

# The repository's coordinates, lowercased: the denylist matches regardless of case.
lowercase() { tr '[:upper:]' '[:lower:]'; }
ALLOWED=(
  "$(printf '%s/%s' "$SIMTOOL_TAP_OWNER" "$SIMTOOL_TAP_REPO" | lowercase)"
  "$(printf '%s/%s' "$SIMTOOL_GITHUB_OWNER" "$SIMTOOL_GITHUB_REPO" | lowercase)"
  "$(printf '%s/%s' "$SIMTOOL_TAP_OWNER" "${SIMTOOL_TAP_REPO#homebrew-}" | lowercase)"
)

# What to scan, as paths relative to the current directory.
FILES=()
if [[ "$TARGET" == "-" ]]; then
  cd "$WORK"
  cat > stdin
  FILES=(stdin)
else
  if [[ ! -d "$TARGET" ]]; then
    echo "Not a directory: $TARGET" >&2
    exit 2
  fi
  cd "$TARGET"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' path; do
      [[ -f "$path" ]] && FILES+=("$path")
    done < <(git ls-files -z --cached --others --exclude-standard)
  else
    while IFS= read -r -d '' path; do
      FILES+=("${path#./}")
    done < <(find . -type d -name '.?*' -prune -o -type f -print0)
  fi
  # File names are part of what gets published.
  NAMES="$WORK/file names"
  printf '%s\n' "${FILES[@]+"${FILES[@]}"}" > "$NAMES"
  FILES+=("$NAMES")
fi

HITS="$WORK/hits"
: > "$HITS"
report() {  # path:line:text, why
  local location="$1" why="$2"
  printf '%s  [%s]\n' "$(printf '%s' "$location" | sed "s#^$WORK/##" | cut -c1-200)" "$why" >> "$HITS"
}

# grep over every file; silent and successful when nothing matches.
scan() {
  if (( ${#FILES[@]} > 0 )); then
    grep -H -n -I "$@" -- "${FILES[@]}" 2>/dev/null || true
  fi
}

# 1. The organization's terms, outside the repository's own coordinates.
if [[ -s "$PATTERNS" ]]; then
  while IFS= read -r candidate; do
    text="${candidate#*:*:}"
    stripped="$(printf '%s' "$text" | lowercase)"
    for allowed in "${ALLOWED[@]}"; do
      stripped="${stripped//"$allowed"/}"
    done
    if printf '%s\n' "$stripped" | grep -q -i -E -f "$PATTERNS"; then
      report "$candidate" "denylist"
    fi
  done < <(scan -i -E -f "$PATTERNS")
fi

# 2. Issue keys. A key-shaped word is skipped when its letters are all hex
# digits (a piece of a UUID) or it names a standard (a hash, an ISO number).
while IFS= read -r match; do
  key="${match##*:}"
  prefix="${key%%-*}"
  if [[ "$prefix" =~ ^[0-9A-F]+$ || "$prefix" =~ ^(SHA|ISO|UTF|RFC|AES)$ ]]; then
    continue
  fi
  report "$match" "issue key"
done < <(scan -o -E '\b[A-Z][A-Z0-9]+-[0-9]{3,}\b')

# 3. Home directories of real users; placeholder names are fine.
while IFS= read -r match; do
  user="${match##*/Users/}"
  case "$user" in
    x|xy|me|dev|user|you|example|Shared) continue ;;
  esac
  report "$match" "home directory"
done < <(scan -o -E '/Users/[A-Za-z0-9._-]+')

# 4. Email addresses, except reserved example domains and git's own user.
while IFS= read -r match; do
  address="$(printf '%s' "${match#*:*:}" | lowercase)"
  case "$address" in
    git@github.com|*@example.com|*@example.org|*@example.net|*.example|*.test|*.invalid|*.localhost) continue ;;
    *.png|*.jpg|*.jpeg|*.gif|*.pdf|*.svg|*.heic|*.webp) continue ;;  # an image's @2x
  esac
  report "$match" "email"
done < <(scan -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')

if [[ -s "$HITS" ]]; then
  count="$(wc -l < "$HITS" | tr -d ' ')"
  echo "Internal references found ($count):" >&2
  sort -u "$HITS" >&2
  echo "SimTool is published as is: describe the thing instead of naming it, or use an example.com / placeholder value." >&2
  exit 1
fi

echo "No internal references in ${#FILES[@]} scanned files."
