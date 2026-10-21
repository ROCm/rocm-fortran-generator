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

# Shared helpers for the scripts at the repo root and in tests/. Source it, never
# execute it. It sets no `set` flags: several callers inspect $? after commands
# allowed to fail, so each script chooses its own.

[ -n "${_ROCM_FORTRAN_COMMON:-}" ] && return 0
_ROCM_FORTRAN_COMMON=1

shopt -s nullglob   # an unmatched *.f90 glob must expand to nothing

# ---------------------------------------------------------------- errors, temp

die() { local c="$1"; shift; printf '%s: %s\n' "${0##*/}" "$*" >&2; exit "$c"; }

TMPDIRS=()
make_tmpdir() {   # sets $TMP, removed on exit; safe to call more than once
  TMP="$(mktemp -d)" || die 1 "mktemp failed"
  TMPDIRS+=("$TMP")
  trap 'rm -rf "${TMPDIRS[@]}"' EXIT
}

# Refuse, rather than silently generate (which takes minutes), when fortran/ is absent.
die_need_gen() {   # die_need_gen <first line of the message>
  printf '%s\n' "$*" >&2
  printf 'fortran/ is a build artifact (gitignored). Generate it first:\n  ./gen.sh\n' >&2
  exit 1
}

# ------------------------------------------------------------------- locating

# Capture first, then match: piping into `grep -q` under pipefail fails on a match
# (grep exits early, rocminfo dies of SIGPIPE).
rocm_have_gpu() {   # rocm_have_gpu [rocm-prefix]
  local info
  info="$("${1:-/opt/rocm}/bin/rocminfo" 2>/dev/null)" || return 1
  grep -q "Device Type:.*GPU" <<<"$info"
}

# -------------------------------------------------------- Fortran build engine
#
# A session (the globals below), then fort_build_tree compiles every scanned module.

FORT_FC=gfortran
FORT_FLAGS=()
FORT_SRCDIRS=()
# One -I per source dir, so any textual include in a generated source resolves.
FORT_INCS=()
# -I/-J: all .mod land in ONE directory so `use` resolves across libraries. Empty
# means cwd, the only portable choice (-J is GNU-only).
FORT_MODDIR=""
FORT_OBJDIR=""
FORT_ERRDIR="."
FORT_ON_PASS=fort_report_pass
FORT_ON_FAIL=fort_report_fail
FORT_PASS=0
FORT_FAIL=0

fort_session() {   # [--fc C] [--flags "..."] [--moddir D] [--objdir D] [--errdir D]
                   # [--on-pass FN] [--on-fail FN]
  FORT_FC=gfortran; FORT_FLAGS=(); FORT_MODDIR=""; FORT_OBJDIR=""; FORT_ERRDIR="."
  FORT_ON_PASS=fort_report_pass; FORT_ON_FAIL=fort_report_fail
  FORT_PASS=0; FORT_FAIL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fc)        FORT_FC="$2"; shift 2 ;;
      --flags)     FORT_FLAGS=(); [ -n "$2" ] && read -r -a FORT_FLAGS <<<"$2"; shift 2 ;;
      --moddir)    FORT_MODDIR="$2"; shift 2 ;;
      --objdir)    FORT_OBJDIR="$2"; shift 2 ;;
      --errdir)    FORT_ERRDIR="$2"; shift 2 ;;
      --on-pass)   FORT_ON_PASS="$2"; shift 2 ;;
      --on-fail)   FORT_ON_FAIL="$2"; shift 2 ;;
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

# Every module of the scanned dirs. Modules `use` one another (rocsolver uses
# rocblas), so iterate to a fixpoint instead of a single alphabetical pass; only
# the last attempt's errors are meaningful.
fort_build_tree() {
  local d f rc=0 progressed
  local -a mods=() remaining=() next=()
  for d in "${FORT_SRCDIRS[@]}"; do
    for f in "$d"/*.f90 "$d"/*.F90; do mods+=("$f"); done
  done
  remaining=("${mods[@]}")
  while [ "${#remaining[@]}" -gt 0 ]; do
    next=(); progressed=0
    for f in "${remaining[@]}"; do
      if fort_compile "$f"; then
        "$FORT_ON_PASS" "$f"; progressed=1
      else
        next+=("$f")
      fi
    done
    if [ "$progressed" = 0 ]; then
      for f in "${next[@]}"; do "$FORT_ON_FAIL" "$f"; done
      rc=1; break
    fi
    remaining=("${next[@]}")
  done
  return $rc
}

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
