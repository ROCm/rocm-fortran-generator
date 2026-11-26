#!/usr/bin/env bash
###############################################################################
# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

# Shared helpers for the gate and build scripts at the repo root and in tests/.
#
# Source it, never execute it:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"      # root
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/common.sh"   # tests/
#
# It sets no `set` flags on purpose: several callers are incompatible with -e
# (they inspect $? after a command that is allowed to fail), so each script keeps
# its own line and says why in a comment next to it.

[ -n "${_ROCM_FORTRAN_COMMON:-}" ] && return 0
_ROCM_FORTRAN_COMMON=1

shopt -s nullglob   # an unmatched *_enums.F90 glob must expand to nothing

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"

# ---------------------------------------------------------------- errors, temp

die() { local c="$1"; shift; printf '%s: %s\n' "${0##*/}" "$*" >&2; exit "$c"; }

# A gate that cannot run has not passed: 127, never a green tick nobody earned.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 127 "$c not installed"
  done
}

TMPDIRS=()
make_tmpdir() {   # sets $TMP, removed on exit; safe to call more than once
  TMP="$(mktemp -d)" || die 1 "mktemp failed"
  TMPDIRS+=("$TMP")
  trap 'rm -rf "${TMPDIRS[@]}"' EXIT
}

# fortran/ is a build artifact (gitignored), so an absent tree is the normal state
# of a fresh clone. Refuse with the command that creates it: generating takes
# minutes, and a compile gate silently turning into a generation is worse than a
# clear refusal.
die_need_gen() {   # die_need_gen <packaged|hipfort> <first line of the message>
  local tree="$1"; shift
  printf '%s\n' "$*" >&2
  printf 'fortran/ is a build artifact (gitignored). Generate it first:\n  ./gen.sh %s\n' "$tree" >&2
  exit 1
}

# ------------------------------------------------------------------- locating

# hipfort may sit inside this checkout or beside it; take whichever exists so the
# no-argument form works in both layouts.
hipfort_checkout() {   # hipfort_checkout <repo-root> [explicit-path]
  local root="$1" hf="${2:-}"
  if [ -z "$hf" ]; then
    hf="$root/hipfort"
    [ -d "$hf" ] || hf="$(dirname "$root")/hipfort"
  fi
  printf '%s\n' "$hf"
}

# Capture first, then match. Piping into `grep -q` under `set -o pipefail` makes
# this check fail exactly when it SUCCEEDS: grep -q exits at the first match,
# rocminfo dies of SIGPIPE, and pipefail propagates 141.
rocm_have_gpu() {   # rocm_have_gpu [rocm-prefix]
  local info
  info="$("${1:-/opt/rocm}/bin/rocminfo" 2>/dev/null)" || return 1
  grep -q "Device Type:.*GPU" <<<"$info"
}

# -------------------------------------------------------- Fortran build engine
#
# A session (the globals below) plus composable stages. Not one do-everything
# function: tests/build_vecadd.sh wants stages 1-2 and then an explicit module
# list with no fixpoint, and tests/build_symbols.sh wants only fort_compile.

FORT_FC=gfortran
FORT_FLAGS=()
FORT_SRCDIRS=()
# One -I per source dir: a wrapper's `include "<name>_interfaces.f90"` is resolved
# textually, so the fragment's own directory must be on the include path.
FORT_INCS=()
# -I/-J: all .mod land in ONE directory so `use` resolves across libraries. Empty
# means the compiler's default (cwd), which is what the portability gate needs:
# -J is GNU-only (nvfortran spells it -module, ifx -module), while every compiler
# both writes and searches .mod in cwd.
FORT_MODDIR=""
FORT_OBJDIR=""
FORT_ERRDIR="."
FORT_ON_PASS=fort_report_pass
FORT_ON_FAIL=fort_report_fail
FORT_FAIL_FAST=0
FORT_PASS=0
FORT_FAIL=0
declare -A FORT_DONE=()

fort_session() {   # [--fc C] [--flags "..."] [--moddir D] [--objdir D] [--errdir D]
                   # [--on-pass FN] [--on-fail FN] [--fail-fast]
  FORT_FC=gfortran; FORT_FLAGS=(); FORT_MODDIR=""; FORT_OBJDIR=""; FORT_ERRDIR="."
  FORT_ON_PASS=fort_report_pass; FORT_ON_FAIL=fort_report_fail
  FORT_FAIL_FAST=0; FORT_PASS=0; FORT_FAIL=0; FORT_DONE=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fc)        FORT_FC="$2"; shift 2 ;;
      --flags)     FORT_FLAGS=(); [ -n "$2" ] && read -r -a FORT_FLAGS <<<"$2"; shift 2 ;;
      --moddir)    FORT_MODDIR="$2"; shift 2 ;;
      --objdir)    FORT_OBJDIR="$2"; shift 2 ;;
      --errdir)    FORT_ERRDIR="$2"; shift 2 ;;
      --on-pass)   FORT_ON_PASS="$2"; shift 2 ;;
      --on-fail)   FORT_ON_FAIL="$2"; shift 2 ;;
      --fail-fast) FORT_FAIL_FAST=1; shift ;;
      *) die 2 "fort_session: unknown option $1" ;;
    esac
  done
  return 0   # never let the option test above become this function's exit status
}

fort_modname() { local b="${1##*/}"; printf '%s\n' "${b%.[fF]90}"; }
fort_errfile() { printf '%s/err_%s\n' "$FORT_ERRDIR" "$(fort_modname "$1")"; }

fort_scan_srcdirs() {   # <root>... -> FORT_SRCDIRS, FORT_INCS; returns 1 if none
  local r d
  FORT_SRCDIRS=(); FORT_INCS=()
  for r in "$@"; do
    [ -d "$r" ] || continue
    while IFS= read -r d; do FORT_SRCDIRS+=("$d"); done < <(
      find "$r" -type f \( -name '*.f90' -o -name '*.F90' \) -printf '%h\n' 2>/dev/null | sort -u)
  done
  for d in "${FORT_SRCDIRS[@]}"; do FORT_INCS+=(-I"$d"); done
  [ "${#FORT_SRCDIRS[@]}" -gt 0 ]
}

fort_set_srcdirs() {   # a flat directory already known to hold the sources
  local d
  FORT_SRCDIRS=("$@"); FORT_INCS=()
  for d in "$@"; do FORT_INCS+=(-I"$d"); done
  return 0
}

fort_compile() {   # <source> -> 0/1, stderr in $(fort_errfile "<source>")
  local f="$1" n cmd=()
  n="$(fort_modname "$f")"
  cmd=("$FORT_FC" -c ${FORT_FLAGS[@]+"${FORT_FLAGS[@]}"} ${FORT_INCS[@]+"${FORT_INCS[@]}"})
  [ -n "$FORT_MODDIR" ] && cmd+=(-I"$FORT_MODDIR" -J"$FORT_MODDIR")
  [ -n "$FORT_OBJDIR" ] && cmd+=(-o "$FORT_OBJDIR/$n.o")
  "${cmd[@]}" "$f" 2>"$(fort_errfile "$f")"
}

fort_report_pass() { FORT_PASS=$((FORT_PASS + 1)); printf 'PASS  %s\n' "$(fort_modname "$1")"; }
fort_report_fail() { FORT_FAIL=$((FORT_FAIL + 1)); printf 'FAIL  %s\n' "$(fort_modname "$1")"
                     cat "$(fort_errfile "$1")"; }
fort_quiet_pass()  { FORT_PASS=$((FORT_PASS + 1)); return 0; }

_fort_run() {
  local f="$1"
  if fort_compile "$f"; then FORT_DONE["$f"]=1; "$FORT_ON_PASS" "$f"; return 0; fi
  "$FORT_ON_FAIL" "$f"
  return 1
}

# Dependency order is always:
#   *_enums -> *_types -> hipfort_auxiliary, hipfort_check -> the rest
# *_interfaces and *_wrappers are `include`d fragments, never compiled standalone.

fort_stage_suffix() {   # fort_stage_suffix _enums
  local sfx="$1" d f rc=0
  for d in "${FORT_SRCDIRS[@]}"; do
    for f in "$d"/*"$sfx".f90 "$d"/*"$sfx".F90; do
      _fort_run "$f" || { rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1; }
    done
  done
  return $rc
}

fort_stage_named() {   # fort_stage_named [--required] <modname>...
  local required=0 n d e f rc=0 found
  [ "${1:-}" = --required ] && { required=1; shift; }
  for n in "$@"; do
    found=0
    for d in "${FORT_SRCDIRS[@]}"; do
      for e in f90 F90; do
        f="$d/$n.$e"; [ -f "$f" ] || continue
        found=1
        _fort_run "$f" || { rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1; }
      done
    done
    if [ "$found" = 0 ] && [ "$required" = 1 ]; then
      printf 'missing module source: %s.[fF]90\n' "$n" >&2
      rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1
    fi
  done
  return $rc
}

fort_stage_fixpoint() {
  local d f rc=0 progressed
  local -a mods=() remaining=() next=()
  for d in "${FORT_SRCDIRS[@]}"; do
    for f in "$d"/*.f90 "$d"/*.F90; do
      case "${f##*/}" in
        *_enums.[fF]90|*_types.[fF]90|*_interfaces.[fF]90|*_wrappers.[fF]90) continue ;;
        hipfort_check.[fF]90|hipfort_auxiliary.[fF]90) continue ;;
      esac
      [ -n "${FORT_DONE[$f]:-}" ] && continue
      mods+=("$f")
    done
  done
  # Modules `use` one another (hipfort_hipmalloc needs hipfort_hipmemcpy), so a
  # single alphabetical pass compiles them in the wrong order: iterate to a
  # fixpoint instead. Per-module stderr is kept because a module is retried until
  # the stall, so only the last attempt's errors are meaningful.
  remaining=("${mods[@]}")
  while [ "${#remaining[@]}" -gt 0 ]; do
    next=(); progressed=0
    for f in "${remaining[@]}"; do
      if fort_compile "$f"; then
        FORT_DONE["$f"]=1; "$FORT_ON_PASS" "$f"; progressed=1
      else
        next+=("$f")
      fi
    done
    # The fixpoint stopping is not success: whatever is left never compiled.
    if [ "$progressed" = 0 ]; then
      for f in "${next[@]}"; do "$FORT_ON_FAIL" "$f"; done
      rc=1; break
    fi
    remaining=("${next[@]}")
  done
  return $rc
}

# --fail-fast applies to the ordered stages only: inside the fixpoint a first-pass
# failure is expected, that is the whole point of iterating.
fort_build_tree() {
  local rc=0
  fort_stage_suffix _enums || { rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1; }
  fort_stage_suffix _types || { rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1; }
  fort_stage_named hipfort_auxiliary hipfort_check \
    || { rc=1; [ "$FORT_FAIL_FAST" = 1 ] && return 1; }
  fort_stage_fixpoint || rc=1
  return $rc
}

# --------------------------------------------------------------------- doxygen

# CI is Read the Docs, and .readthedocs.yaml installs Ubuntu 24.04's apt doxygen.
# Whether a link resolves is a property of the resolver VERSION, not of the source
# (1.9.8 fails on ::rocfft_execution_info_set_load_callback_data, 1.18 resolves
# it), so prefer /usr/bin/doxygen, which is that same package, over whatever a
# developer has first in PATH. Override with DOXYGEN=/path/to/doxygen when CI moves.
doxygen_bin() {
  local d="${DOXYGEN:-}"
  if [ -z "$d" ]; then
    if [ -x /usr/bin/doxygen ]; then d=/usr/bin/doxygen
    else d="$(command -v doxygen 2>/dev/null || true)"; fi
  fi
  [ -n "$d" ] && [ -x "$d" ] || return 1
  printf '%s\n' "$d"
}

# Flatten and preprocess ONE tree into a single input dir. Basenames are unique
# within a tree, which is why the source must name one tree and never fortran/
# itself: the two trees share module file names and would overwrite each other.
doxygen_preprocess() {   # <srcdir> <inputdir> -> 1 if nothing was produced
  local src="$1" out="$2" f
  mkdir -p "$out"
  while IFS= read -r f; do
    gfortran -E -cpp -P -DUSE_FPOINTER_INTERFACES=1 -UUSE_CUDA_NAMES "$f" \
      -o "$out/${f##*/}" 2>/dev/null || true
  done < <(find "$src" -type f \( -name '*.f90' -o -name '*.F90' \))
  [ -n "$(ls -A "$out" 2>/dev/null)" ]
}

doxyfile_write() {   # <doxyfile> <outdir> <inputdir> <warnlog> [GENERATE_HTML]
  local file="$1" out="$2" input="$3" warn="$4" html="${5:-YES}"
  cat > "$file" <<EOF
# Without OUTPUT_DIRECTORY Doxygen writes xml/, latex/ ... into the cwd, which is
# the repo root for every documented invocation: 200+ MB of untracked artifacts.
OUTPUT_DIRECTORY     = $out
INPUT                = $input
FILE_PATTERNS        = *.f90 *.F90
RECURSIVE            = NO
OPTIMIZE_FOR_FORTRAN = YES
EXTENSION_MAPPING    = f90=FortranFree F90=FortranFree
EXTRACT_ALL          = YES
# HTML must be ON to see broken links: Doxygen resolves explicit link requests
# (\ref X, ::X, #X) only while GENERATING output. With GENERATE_HTML=NO that phase
# never runs and a broken link sails through, which is how a ::roctx_range_id_t
# link once passed this gate and then aborted hipfort's Read-the-Docs build.
# The output itself is thrown away; only the warning log matters.
GENERATE_HTML        = $html
HTML_OUTPUT          = $out/html
GENERATE_LATEX       = NO
GENERATE_XML         = NO
QUIET                = YES
# Mirror hipfort's Doxyfile so this sees what its WARN_AS_ERROR=YES build sees.
WARNINGS             = YES
WARN_IF_UNDOCUMENTED = YES
WARN_IF_DOC_ERROR    = YES
WARN_IF_INCOMPLETE_DOC = YES
WARN_NO_PARAMDOC     = NO
WARN_IF_UNDOC_ENUM_VAL = NO
AUTOLINK_SUPPORT     = YES
MARKDOWN_SUPPORT     = YES
WARN_AS_ERROR        = NO
WARN_LOGFILE         = $warn
EOF
}

doxygen_run() { "$1" "$2" >/dev/null 2>&1 || true; }   # the warn log is the output

# ---------------------------------------------------------------- usage engine
#
# Each script defines usage_spec() as a QUOTED heredoc, one `key: value` per line,
# columns separated by `|`. Quoted so a description may contain $, backticks or *
# with no escaping. Then: usage_peek "$@" gives -h/--help, usage_error gives the
# same block on stderr with exit 2.
#
#   name:  <script.sh>                        once
#   brief: <one line>                         once
#   usage: <synopsis>                         repeatable
#   arg:   <name> | <description>             repeatable; empty name continues the previous
#   flag:  <spelling> | <description>
#   env:   <NAME> | <default or -> | <description>
#   exit:  <code> | <meaning>
#   note:  <free text>

_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

_usage_rows() {   # <title> <row>...
  local title="$1"; shift
  [ $# -gt 0 ] || return 0
  local r l w=0
  for r in "$@"; do l="$(_trim "${r%%|*}")"; [ "${#l}" -gt "$w" ] && w="${#l}"; done
  printf '%s:\n' "$title"
  for r in "$@"; do printf '  %-*s  %s\n' "$w" "$(_trim "${r%%|*}")" "$(_trim "${r#*|}")"; done
  printf '\n'
}

usage() {
  local line key val def name="${0##*/}" brief="" s n
  local -a syn=() args=() flags=() envs=() exits=() notes=()
  while IFS= read -r line; do
    [ -n "$(_trim "$line")" ] || continue
    key="$(_trim "${line%%:*}")"; val="$(_trim "${line#*:}")"
    case "$key" in
      name)  name="$val" ;;
      brief) brief="$val" ;;
      usage) syn+=("$val") ;;
      arg)   args+=("$val") ;;
      flag)  flags+=("$val") ;;
      env)   def="$(_trim "$(cut -d'|' -f2 <<<"$val")")"
             if [ -z "$def" ] || [ "$def" = "-" ]; then
               envs+=("$(cut -d'|' -f1 <<<"$val")|$(_trim "$(cut -d'|' -f3- <<<"$val")")")
             else
               envs+=("$(cut -d'|' -f1 <<<"$val")|$(_trim "$(cut -d'|' -f3- <<<"$val")") [default: $def]")
             fi ;;
      exit)  exits+=("$val") ;;
      *)     notes+=("$val") ;;
    esac
  done < <(usage_spec)

  if [ -n "$brief" ]; then printf '%s - %s\n\n' "$name" "$brief"; else printf '%s\n\n' "$name"; fi
  if [ "${#syn[@]}" -gt 0 ]; then
    printf 'usage:\n'
    for s in "${syn[@]}"; do printf '  %s\n' "$s"; done
    printf '\n'
  fi
  _usage_rows arguments     ${args[@]+"${args[@]}"}
  _usage_rows options       ${flags[@]+"${flags[@]}"}
  _usage_rows environment   ${envs[@]+"${envs[@]}"}
  _usage_rows "exit status" ${exits[@]+"${exits[@]}"}
  if [ "${#notes[@]}" -gt 0 ]; then
    printf 'notes:\n'
    for n in "${notes[@]}"; do
      if [ -n "$n" ]; then printf '  %s\n' "$n"; else printf '\n'; fi
    done
  fi
  return 0
}

usage_peek() {
  local a
  for a in "$@"; do case "$a" in -h|--help) usage; exit 0 ;; esac; done
  return 0
}

usage_error() { printf '%s: %s\n\n' "${0##*/}" "$*" >&2; usage >&2; exit 2; }
