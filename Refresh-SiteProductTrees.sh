#!/usr/bin/env bash
# Copy product trees onto a site root without touching site-owned files.
# Usage: Refresh-SiteProductTrees.sh <upstream-dir> <site-root>
set -euo pipefail

UPSTREAM="${1:?upstream dir}"
SITE_ROOT="${2:?site root}"

copy_tree() {
  local src="$1" dest="$2" skip_prefix="${3:-}"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dest"
  local file rel
  while IFS= read -r file; do
    rel="${file#"$src"/}"
    rel="${rel#./}"
    if [[ -n "$skip_prefix" ]]; then
      case "$rel" in
        "$skip_prefix"|"$skip_prefix"/*) continue ;;
      esac
    fi
    mkdir -p "$dest/$(dirname "$rel")"
    cp -a "$file" "$dest/$rel"
  done < <(find "$src" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*')
}

copy_docker_examples() {
  local src="$1" dest="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dest"
  local file rel name
  while IFS= read -r file; do
    rel="${file#"$src"/}"
    name="$(basename "$file")"
    case "$name" in
      README.md|.gitkeep|*.example) ;;
      *) continue ;;
    esac
    mkdir -p "$dest/$(dirname "$rel")"
    cp -a "$file" "$dest/$rel"
  done < <(find "$src" -type f)
}

copy_missing() {
  local src="$1" dest="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dest"
  local file rel target
  while IFS= read -r file; do
    rel="${file#"$src"/}"
    rel="${rel#./}"
    target="$dest/$rel"
    [[ -e "$target" ]] && continue
    mkdir -p "$(dirname "$target")"
    cp -a "$file" "$target"
  done < <(find "$src" -type f ! -name '*.pyc' ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*')
}

copy_missing "$UPSTREAM/plugins" "$SITE_ROOT/plugins"
copy_missing "$UPSTREAM/site-catalog" "$SITE_ROOT/site-catalog"
if [[ ! -f "$SITE_ROOT/site-plugins.json" ]]; then
  if [[ -f "$UPSTREAM/site-plugins.json" ]]; then
    cp -a "$UPSTREAM/site-plugins.json" "$SITE_ROOT/site-plugins.json"
  elif [[ -f "$UPSTREAM/site-catalog/site-plugins.json" ]]; then
    cp -a "$UPSTREAM/site-catalog/site-plugins.json" "$SITE_ROOT/site-plugins.json"
  fi
fi

copy_tree "$UPSTREAM/scriptkit" "$SITE_ROOT/scriptkit"
copy_tree "$UPSTREAM/agent-context" "$SITE_ROOT/agent-context" "site"
copy_docker_examples "$UPSTREAM/docker" "$SITE_ROOT/docker"

if [[ -f "$UPSTREAM/docker-compose.apps.example.yml" ]]; then
  cp -a "$UPSTREAM/docker-compose.apps.example.yml" "$SITE_ROOT/docker-compose.apps.example.yml"
fi
if [[ -f "$UPSTREAM/docker-compose.custom.example.yml" ]]; then
  cp -a "$UPSTREAM/docker-compose.custom.example.yml" "$SITE_ROOT/docker-compose.custom.example.yml"
fi

mkdir -p "$SITE_ROOT/cli" "$SITE_ROOT/agent-context/site" "$SITE_ROOT/docker/pkm-backend"
if [[ -f "$UPSTREAM/cli/README.md" && ! -f "$SITE_ROOT/cli/README.md" ]]; then
  cp -a "$UPSTREAM/cli/README.md" "$SITE_ROOT/cli/README.md"
fi
if [[ -f "$UPSTREAM/agent-context/site/README.md" && ! -f "$SITE_ROOT/agent-context/site/README.md" ]]; then
  mkdir -p "$SITE_ROOT/agent-context/site"
  cp -a "$UPSTREAM/agent-context/site/README.md" "$SITE_ROOT/agent-context/site/README.md"
fi
