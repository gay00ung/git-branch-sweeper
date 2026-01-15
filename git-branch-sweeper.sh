#!/usr/bin/env bash
set -euo pipefail

# git-branch-sweeper.sh
# Safely prune merged branches (local + remote) by pattern. Dry-run by default.

REMOTE="${REMOTE:-origin}"
PATTERN="${PATTERN:-feature/*}"
# Space-separated list in env is allowed too (e.g. BASES="main dev")
BASES_ENV="${BASES:-}"

# Default bases if none provided via env/args
DEFAULT_BASES=("main" "dev")
PROTECTED_DEFAULT=("main" "dev" "master" "release" "staging" "production")

APPLY=false
FORCE=false
LOCAL_ONLY=false
REMOTE_ONLY=false
VERBOSE=false

declare -a BASES=()
declare -a PROTECTED=()

usage() {
  cat <<'EOF'
Usage:
  git-branch-sweeper.sh [options]

Options:
  --apply                 Actually delete branches (default: dry-run)
  --force                 Force delete local branches (-D) instead of -d (only with --apply)
  --pattern <glob>        Branch glob to match (default: feature/*)  (also via PATTERN env)
  --remote <name>         Remote name (default: origin)             (also via REMOTE env)
  --base <branch>         Base branch to check merged into. Can be repeated.
                           Example: --base main --base dev
                           (also via BASES env: BASES="main dev")
  --protected <name>      Protected branch name to never delete. Can be repeated.
                           (also via PROTECTED env: PROTECTED="main dev")
  --local-only            Only prune local branches
  --remote-only           Only prune remote branches
  -v, --verbose           Verbose output
  -h, --help              Show help

Examples (dry-run):
  ./git-branch-sweeper.sh
  PATTERN="feature/*" ./git-branch-sweeper.sh
  ./git-branch-sweeper.sh --pattern "bugfix/*" --base main

Apply deletions:
  ./git-branch-sweeper.sh --apply --pattern "feature/*" --base main --base dev

Notes:
  - PATTERN is a bash glob, not a regex.
  - Remote deletion uses: git push <remote> --delete <branch>
EOF
}

log() { $VERBOSE && echo "[git-branch-sweeper] $*"; }

die() { echo "Error: $*" >&2; exit 1; }

# ---- arg parsing ----
# Allow env-provided lists
if [[ -n "${PROTECTED-}" ]]; then
  # shellcheck disable=SC2206
  PROTECTED=(${PROTECTED})
else
  PROTECTED=("${PROTECTED_DEFAULT[@]}")
fi

if [[ -n "$BASES_ENV" ]]; then
  # shellcheck disable=SC2206
  BASES=($BASES_ENV)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --force) FORCE=true; shift ;;
    --local-only) LOCAL_ONLY=true; shift ;;
    --remote-only) REMOTE_ONLY=true; shift ;;
    --pattern) PATTERN="${2-}"; [[ -n "${PATTERN}" ]] || die "--pattern requires a value"; shift 2 ;;
    --remote) REMOTE="${2-}"; [[ -n "${REMOTE}" ]] || die "--remote requires a value"; shift 2 ;;

    --base)
      [[ -n "${2-}" ]] || die "--base requires a value"
      BASES+=("$2")
      shift 2
      ;;

    --protected)
      [[ -n "${2-}" ]] || die "--protected requires a value"
      PROTECTED+=("$2")
      shift 2
      ;;

    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

$LOCAL_ONLY && $REMOTE_ONLY && die "--local-only and --remote-only cannot be used together"

if [[ ${#BASES[@]} -eq 0 ]]; then
  BASES=("${DEFAULT_BASES[@]}")
fi

# ---- helpers ----
has_local_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

has_remote_branch() {
  git show-ref --verify --quiet "refs/remotes/$REMOTE/$1"
}

is_protected() {
  local name="$1"
  for p in "${PROTECTED[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

matches_pattern() {
  local name="$1"
  [[ "$name" == $PATTERN ]]
}

# Remove lines like "origin/HEAD -> origin/main"
filter_symbolic_refs() {
  grep -v -- '->' || true
}

# ---- safety checks ----
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository"

log "REMOTE=$REMOTE"
log "PATTERN=$PATTERN"
log "BASES=${BASES[*]}"
log "PROTECTED=${PROTECTED[*]}"
log "MODE=$( $APPLY && echo apply || echo dry-run )"

# Fetch/prune once (unless remote-only false? still useful for merged checks)
git fetch "$REMOTE" --prune

CUR="$(current_branch)"

# ---- collect merged local branches ----
delete_local_list=()

if ! $REMOTE_ONLY; then
  for base in "${BASES[@]}"; do
    if has_local_branch "$base"; then
      # list branches merged into base
      while IFS= read -r b; do
        [[ -n "$b" ]] || continue
        delete_local_list+=("$b")
      done < <(
        git branch --merged "$base" \
          | sed 's/^[* ]\+//' \
          | filter_symbolic_refs
      )
    else
      log "Local base branch not found: $base (skipping local merged check for it)"
    fi
  done

  # uniq
  if [[ ${#delete_local_list[@]} -gt 0 ]]; then
    printf "%s\n" "${delete_local_list[@]}" | sort -u | while IFS= read -r branch; do
      [[ -n "$branch" ]] || continue
      matches_pattern "$branch" || continue
      is_protected "$branch" && continue
      [[ "$branch" == "$CUR" ]] && { log "Skip current branch: $branch"; continue; }

      if $APPLY; then
        if $FORCE; then
          git branch -D "$branch"
        else
          git branch -d "$branch"
        fi
      else
        echo "would delete local $branch"
      fi
    done
  fi
fi

# ---- collect merged remote branches ----
delete_remote_list=()

if ! $LOCAL_ONLY; then
  for base in "${BASES[@]}"; do
    if has_remote_branch "$base"; then
      while IFS= read -r rb; do
        [[ -n "$rb" ]] || continue
        delete_remote_list+=("$rb")
      done < <(
        git branch -r --merged "$REMOTE/$base" \
          | sed 's/^[* ]\+//' \
          | filter_symbolic_refs
      )
    else
      log "Remote base branch not found: $REMOTE/$base (skipping remote merged check for it)"
    fi
  done

  if [[ ${#delete_remote_list[@]} -gt 0 ]]; then
    printf "%s\n" "${delete_remote_list[@]}" \
      | sed "s|^$REMOTE/||" \
      | sort -u \
      | while IFS= read -r branch; do
          [[ -n "$branch" ]] || continue
          matches_pattern "$branch" || continue
          is_protected "$branch" && continue

          # Never attempt to delete bases themselves if pattern accidentally matches
          for base in "${BASES[@]}"; do
            [[ "$branch" == "$base" ]] && continue 2
          done

          if $APPLY; then
            git push "$REMOTE" --delete "$branch"
          else
            echo "would delete remote $REMOTE/$branch"
          fi
        done
  fi
fi