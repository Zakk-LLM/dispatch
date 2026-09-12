#!/usr/bin/env bash
# Install this skill for Claude Code, Codex, OpenCode, omp, or an Agents-compatible host.
set -euo pipefail

SOURCE=$(cd "$(dirname "$0")" && pwd)
NAME=dispatch
operation=install
transport=link
targets=()

usage() {
  printf '%s\n' \
    "Usage: ./install.sh [claude|codex|opencode|omp|agents ...] [--copy|--link]" \
    "       ./install.sh [targets ...] --status" \
    "       ./install.sh [targets ...] --uninstall" \
    "" \
    "Default: symlink the skill for all five supported targets."
}

for argument in "$@"; do
  case "$argument" in
    --copy) transport=copy ;;
    --link) transport=link ;;
    --status) operation=status ;;
    --uninstall) operation=uninstall ;;
    -h|--help) usage; exit 0 ;;
    claude|codex|opencode|omp|agents) targets+=("$argument") ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

[ "${#targets[@]}" -eq 0 ] && targets=(claude codex opencode omp agents)

skill_base() {
  case "$1" in
    claude) printf '%s\n' "${CLAUDE_HOME:-$HOME/.claude}/skills" ;;
    codex) printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills" ;;
    opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
    omp) printf '%s\n' "${OMP_CONFIG_DIR:-$HOME/.omp/agent}/skills" ;;
    agents) printf '%s\n' "$HOME/.agents/skills" ;;
  esac
}

for target in "${targets[@]}"; do
  base=$(skill_base "$target")
  dest="$base/$NAME"
  case "$operation" in
    status)
      if [ -L "$dest" ]; then
        printf '%-9s link  -> %s\n' "$target" "$(readlink "$dest")"
      elif [ -d "$dest" ]; then
        printf '%-9s copy  %s\n' "$target" "$dest"
      else
        printf '%-9s absent\n' "$target"
      fi
      ;;
    uninstall)
      if [ -L "$dest" ]; then
        if [ "$(readlink "$dest")" = "$SOURCE" ] || [ "$dest" -ef "$SOURCE" ]; then
          rm "$dest"; printf '%-9s removed link\n' "$target"
        else
          printf '%-9s left alone: %s is not this skill\n' "$target" "$dest" >&2
        fi
      elif [ -d "$dest" ]; then
        # Refuse to delete a directory this installer did not create.
        if [ -f "$dest/SKILL.md" ] && grep -q "^name: $NAME\$" "$dest/SKILL.md"; then
          rm -rf "$dest"; printf '%-9s removed copy\n' "$target"
        else
          printf '%-9s left alone: %s is not this skill\n' "$target" "$dest" >&2
        fi
      else
        printf '%-9s absent\n' "$target"
      fi
      ;;
    install)
      if [ "$dest" = "$SOURCE" ]; then
        printf '%-9s source already lives at the install path\n' "$target"; continue
      fi
      mkdir -p "$base"
      # Only replace a directory that is this skill. Another package's SKILL.md is not ours.
      if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        if ! { [ -f "$dest/SKILL.md" ] && grep -q "^name: $NAME\$" "$dest/SKILL.md"; }; then
          printf '%-9s refusing to overwrite %s (not this skill)\n' "$target" "$dest" >&2; exit 1
        fi
      fi
      rm -rf "$dest"
      if [ "$transport" = link ]; then
        ln -s "$SOURCE" "$dest"; printf '%-9s linked  %s\n' "$target" "$dest"
      else
        cp -r "$SOURCE" "$dest"; rm -rf "$dest/.git"; printf '%-9s copied  %s\n' "$target" "$dest"
      fi
      ;;
  esac
done
