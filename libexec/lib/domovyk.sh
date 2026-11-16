# shellcheck shell=bash
# Shared library for domovyk Commands (design.md, Shared library).
#
# A Read_Command builds one JSON body, then calls dv_emit, which adds the
# Envelope (schema, generated, host, unavailable), redacts it unless
# DOMOVYK_RAW=1, and prints it as JSON or renders it as text.
#
# Environment set by bin/domovyk: DOMOVYK_LIBEXEC, DOMOVYK_SHARE,
# DOMOVYK_ROUTE. Read here: DOMOVYK_FORMAT (text|json, also set by --json),
# DOMOVYK_RAW (0|1, also set by --raw), DOMOVYK_TIMEOUT (seconds, default 10),
# DOMOVYK_OS_RELEASE (tests), DOMOVYK_CACHE (default ~/.cache/domovyk).

DV_SCHEMA=""
DV_RENDER=""
DV_TMP=""
DV_UNAVAIL=""
DV_TMPDIRS=()
DV_OUT="" DV_ERR="" DV_RC=0
DV_ARGS=()

dv_cleanup() {
  local d
  for d in "${DV_TMPDIRS[@]}"; do
    [[ -n $d && -d $d ]] && rm -rf -- "$d"
  done
  [[ -n $DV_TMP && -d $DV_TMP ]] && rm -rf -- "$DV_TMP"
  return 0
}

# dv_init <schema> [renderer] [args...]: starts a Command. Strips the common
# options --json and --raw from the arguments; the rest are left in DV_ARGS.
dv_init() {
  DV_SCHEMA=$1
  DV_RENDER=${2:-}
  shift 2 || shift $#
  if [[ -z $DV_RENDER ]]; then
    DV_RENDER=${DV_SCHEMA#domovyk.}
    DV_RENDER=${DV_RENDER%.v*}
  fi
  : "${DOMOVYK_FORMAT:=text}" "${DOMOVYK_RAW:=0}" "${DOMOVYK_TIMEOUT:=10}"
  DV_ARGS=()
  local a
  for a in "$@"; do
    case $a in
    --json) DOMOVYK_FORMAT=json ;;
    --raw) DOMOVYK_RAW=1 ;;
    *) DV_ARGS+=("$a") ;;
    esac
  done
  DV_TMP=$(mktemp -d "${TMPDIR:-/tmp}/domovyk.XXXXXXXX")
  DV_UNAVAIL=$DV_TMP/unavailable.jsonl
  : >"$DV_UNAVAIL"
  trap dv_cleanup EXIT
  trap 'dv_cleanup; exit 130' INT
  trap 'dv_cleanup; exit 143' TERM
}

dv_route() { printf '%s' "${DOMOVYK_ROUTE:-${0##*/domovyk-}}"; }

# dv_die <step> <message>: internal failure, exit 1 (requirement 4.5).
dv_die() {
  printf 'domovyk %s: %s: %s\n' "$(dv_route)" "$1" "$2" >&2
  exit 1
}

# dv_usage <message>: usage error, exit 2.
dv_usage() {
  printf 'domovyk %s: %s\n' "$(dv_route)" "$1" >&2
  printf 'see: domovyk %s --help\n' "$(dv_route)" >&2
  exit 2
}

# dv_unavailable <source> <missing|permission|timeout> [package] [hint]
dv_unavailable() {
  jq -cn --arg s "$1" --arg r "$2" --arg p "${3:-}" --arg h "${4:-}" \
    '{source: $s, reason: $r} + (if $p != "" then {package: $p} else {} end)
      + (if $h != "" then {hint: $h} else {} end)' >>"$DV_UNAVAIL"
}

# dv_have <command> <apt-package>: 0 if the command exists, otherwise records
# it as missing (requirement 1.3) and returns 1.
dv_have() {
  command -v -- "$1" >/dev/null 2>&1 && return 0
  dv_unavailable "$1" missing "$2"
  return 1
}

# dv_readable <path> <source-name> [hint]: 0 if readable, otherwise records
# a permission problem and returns 1.
dv_readable() {
  [[ -r $1 ]] && return 0
  [[ -e $1 ]] || return 1
  dv_unavailable "$2" permission "" "${3:-}"
  return 1
}

# dv_source <name> [--timeout s] [--package p] -- <argv...>
# Runs argv with a timeout (requirement 3.3). Sets DV_OUT and DV_ERR (files)
# and DV_RC. Returns 1, after recording the Source as unavailable, when the
# program is missing, times out or is refused permission; otherwise 0, also
# for a nonzero exit, which the caller interprets.
dv_source() {
  local name=$1 t=$DOMOVYK_TIMEOUT pkg=""
  shift
  while (($#)); do
    case $1 in
    --timeout)
      t=$2
      shift 2
      ;;
    --package)
      pkg=$2
      shift 2
      ;;
    --) shift && break ;;
    *) dv_die source "dv_source $name: bad option $1" ;;
    esac
  done
  if ! command -v -- "$1" >/dev/null 2>&1; then
    dv_unavailable "$name" missing "$pkg"
    return 1
  fi
  DV_OUT=$(mktemp "$DV_TMP/out.XXXXXX")
  DV_ERR=$(mktemp "$DV_TMP/err.XXXXXX")
  DV_RC=0
  timeout --kill-after=2 "$t" "$@" >"$DV_OUT" 2>"$DV_ERR" </dev/null || DV_RC=$?
  if ((DV_RC == 124 || DV_RC == 137)); then
    dv_unavailable "$name" timeout "$pkg"
    return 1
  fi
  if ((DV_RC != 0)) && grep -qiE 'permission denied|access denied|not authori[sz]ed|EACCES|Operation not permitted' "$DV_ERR"; then
    dv_unavailable "$name" permission "$pkg"
    return 1
  fi
  return 0
}

# dv_mktemp_dir: a private temporary directory, deleted on exit, interrupt
# and termination (requirement 10.5).
dv_mktemp_dir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/domovyk-work.XXXXXXXX")
  chmod 0700 "$d"
  DV_TMPDIRS+=("$d")
  printf '%s' "$d"
}

# dv_host_json: the Envelope's host object. No hostname, machine ID or
# serial number, on purpose.
dv_host_json() {
  local file=${DOMOVYK_OS_RELEASE:-/etc/os-release} codename="" release=""
  if [[ -r $file ]]; then
    codename=$(sed -n 's/^VERSION_CODENAME=//p' "$file" | tr -d '"')
    release=$(sed -n 's/^VERSION=//p' "$file" | tr -d '"' | cut -d' ' -f1)
  fi
  jq -cn --arg c "$codename" --arg r "$release" --arg k "$(uname -r)" \
    '{codename: $c, release: $r, kernel: $k}'
}

# dv_emit <body-json-file>: prints the Fact_Output.
dv_emit() {
  local body=$1 doc=$DV_TMP/doc.json red=$DV_TMP/red.json
  jq --arg schema "$DV_SCHEMA" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson host "$(dv_host_json)" \
    --slurpfile unavailable "$DV_UNAVAIL" \
    '{schema: $schema, generated: $generated, host: $host, unavailable: $unavailable} + .' \
    "$body" >"$doc" || dv_die emit "body is not valid JSON"
  if [[ $DOMOVYK_RAW == 1 ]]; then
    printf 'unredacted output\n' >&2
    red=$doc
  else
    python3 -I "$DOMOVYK_LIBEXEC/py/redact.py" --json \
      --rules "$DOMOVYK_SHARE/redact.tsv" <"$doc" >"$red" || exit 1
  fi
  if [[ ${DV_CACHE_ROUTE:-} ]]; then
    dv_cache_put "$DV_CACHE_ROUTE" "$red"
  fi
  if [[ $DOMOVYK_FORMAT == json ]]; then
    cat "$red"
  else
    jq -r -L "$DOMOVYK_LIBEXEC/render" -f "$DOMOVYK_LIBEXEC/render/$DV_RENDER.jq" "$red" ||
      dv_die render "renderer $DV_RENDER failed"
  fi
}

# --- Facts_Cache: redacted JSON, valid for 60 s ------------------------------

dv_cache_dir() { printf '%s/facts' "${DOMOVYK_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/domovyk}"; }

# dv_cache_get <route>: prints the cached file's path if it is fresh.
dv_cache_get() {
  local f
  f="$(dv_cache_dir)/${1// /-}.json"
  [[ -f $f ]] || return 1
  (($(date +%s) - $(stat -c %Y "$f") < 60)) || return 1
  printf '%s' "$f"
}

dv_cache_put() {
  local dir f
  dir=$(dv_cache_dir)
  mkdir -p "$dir" && chmod 0700 "$dir"
  f="$dir/${1// /-}.json"
  (umask 077 && cp -- "$2" "$f.tmp.$$" && mv -f -- "$f.tmp.$$" "$f")
}

# --- small JSON helpers -------------------------------------------------------

# dv_json_lines <file>: turns a file of JSON lines into an array.
dv_json_lines() { jq -cs '.' "$1"; }

# dv_bytes_human is done in render/lib.jq; Commands emit raw numbers.
