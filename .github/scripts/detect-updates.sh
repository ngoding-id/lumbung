#!/usr/bin/env bash
# detect-updates.sh <previous_dir>
#
# Determines which package directories (siblings with a PKGBUILD) need to be
# rebuilt by comparing their current pkgver-pkgrel against the versions recorded
# in <previous_dir>/lumbung.db.tar.zst.
#
# For packages whose PKGBUILD defines a `pkgver()` function, the script runs
# `makepkg -od --nodeps --nobuild --noprepare --skippgpcheck` (as user `builder`)
# to fetch sources and then `makepkg --printsrcinfo` to obtain the live
# pkgver-pkgrel.
#
# Env:
#   FORCE_REBUILD=true    - flag every package regardless of version comparison.
#   GITHUB_OUTPUT         - when set, `pkgs_to_build`, `built_any`,
#                           `current_pkg_names`, `removed_pkg_names`, and
#                           `release_changed` are appended here.
#   DRY_RUN=true          - print decisions to stdout and skip writing to
#                           GITHUB_OUTPUT (useful for local debugging).
#
# The script must run from the repository root (where package directories live).

set -euo pipefail

PREV_DIR="${1:-previous}"
FORCE_REBUILD="${FORCE_REBUILD:-false}"
DRY_RUN="${DRY_RUN:-false}"

repo_root="$(pwd)"

# Extract previous versions map from the previous db, if present.
declare -A prev_ver=()
prev_db="${PREV_DIR}/lumbung.db.tar.zst"
if [ -f "$prev_db" ]; then
  tmp_db="$(mktemp -d)"
  trap 'rm -rf "$tmp_db"' EXIT
  tar -xf "$prev_db" -C "$tmp_db"
  for d in "$tmp_db"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/desc" ] || continue
    name=$(awk '/^%NAME%$/{getline; print; exit}' "$d/desc")
    ver=$(awk '/^%VERSION%$/{getline; print; exit}' "$d/desc")
    if [ -n "$name" ] && [ -n "$ver" ]; then
      prev_ver["$name"]="$ver"
    fi
  done
  echo "Parsed ${#prev_ver[@]} package(s) from previous db:"
  for k in "${!prev_ver[@]}"; do
    echo "  $k => ${prev_ver[$k]}"
  done
else
  echo "No previous db at $prev_db — treating every package as new."
fi

# Parse pkgname/pkgver/pkgrel from a .SRCINFO-like stream on stdin.
# Prints: <pkgname> <pkgver>-<pkgrel>
parse_srcinfo() {
  awk '
    /^pkgbase =/ { base=$3 }
    /^pkgname =/ { if (!name) name=$3 }
    /^[[:space:]]*pkgver =/ { ver=$3 }
    /^[[:space:]]*pkgrel =/ { rel=$3 }
    END {
      n = (name != "") ? name : base
      printf "%s %s-%s\n", n, ver, rel
    }
  '
}

join_sorted_unique() {
  if [ "$#" -eq 0 ]; then
    echo ""
    return
  fi

  printf '%s\n' "$@" | sort -u | paste -sd' ' -
}

pkgs_to_build=()
current_pkg_names=()
removed_pkg_names=()
declare -A current_pkg_set=()

for pkgbuild in */PKGBUILD; do
  [ -f "$pkgbuild" ] || continue
  dir="${pkgbuild%/PKGBUILD}"
  echo "::group::Detecting $dir"

  cur_info=""
  if grep -qE '^[[:space:]]*pkgver[[:space:]]*\(\)[[:space:]]*\{' "$pkgbuild"; then
    echo "$dir has pkgver(); fetching sources to compute live version..."
    chown -R builder:builder "$dir" 2>/dev/null || true
    su builder -c "cd '${repo_root}/${dir}' && makepkg -od --nodeps --nobuild --noprepare --skippgpcheck" >&2
    cur_info=$(su builder -c "cd '${repo_root}/${dir}' && makepkg --printsrcinfo" | parse_srcinfo)
  else
    srcinfo="$dir/.SRCINFO"
    if [ ! -f "$srcinfo" ]; then
      echo "::error::$dir has no .SRCINFO and no pkgver() function; cannot determine version." >&2
      exit 1
    fi
    cur_info=$(parse_srcinfo < "$srcinfo")
  fi

  pkgname=$(echo "$cur_info" | awk '{print $1}')
  cur_ver=$(echo "$cur_info" | awk '{print $2}')

  if [ -z "$pkgname" ] || [ -z "$cur_ver" ] || [ "$cur_ver" = "-" ]; then
    echo "::error::Failed to parse pkgname/pkgver-pkgrel for $dir (got: '$cur_info')." >&2
    exit 1
  fi

  current_pkg_set["$pkgname"]=1
  current_pkg_names+=("$pkgname")

  prev="${prev_ver[$pkgname]:-}"
  reason=""
  if [ "$FORCE_REBUILD" = "true" ]; then
    reason="force_rebuild=true"
  elif [ -z "$prev" ]; then
    reason="new package (not in previous db)"
  elif [ "$prev" != "$cur_ver" ]; then
    reason="version changed: $prev -> $cur_ver"
  fi

  if [ -n "$reason" ]; then
    echo "FLAGGED $dir ($pkgname): $reason"
    pkgs_to_build+=("$dir")
  else
    echo "SKIP    $dir ($pkgname): up to date at $cur_ver"
  fi
  echo "::endgroup::"
done

built_any=false
[ ${#pkgs_to_build[@]} -gt 0 ] && built_any=true

for pkgname in "${!prev_ver[@]}"; do
  if [ -z "${current_pkg_set[$pkgname]:-}" ]; then
    removed_pkg_names+=("$pkgname")
  fi
done

release_changed=false
if [ "$built_any" = "true" ] || [ ${#removed_pkg_names[@]} -gt 0 ]; then
  release_changed=true
fi

joined="${pkgs_to_build[*]:-}"
current_joined="$(join_sorted_unique "${current_pkg_names[@]:-}")"
removed_joined="$(join_sorted_unique "${removed_pkg_names[@]:-}")"

echo ""
echo "=== Summaries ==="
echo "built_any=$built_any"
echo "pkgs_to_build=$joined"
echo "current_pkg_names=$current_joined"
echo "removed_pkg_names=$removed_joined"
echo "release_changed=$release_changed"

if [ "$DRY_RUN" = "true" ]; then
  exit 0
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "pkgs_to_build=$joined"
    echo "built_any=$built_any"
    echo "current_pkg_names=$current_joined"
    echo "removed_pkg_names=$removed_joined"
    echo "release_changed=$release_changed"
  } >> "$GITHUB_OUTPUT"
fi
