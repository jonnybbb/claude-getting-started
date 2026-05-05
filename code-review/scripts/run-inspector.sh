#!/usr/bin/env bash
# run-inspector.sh — JetBrains command-line code inspector wrapper for /code-review:review.
#
# Contract: specs/20260503-163219-add-idea-inspections/contracts/inspector-subprocess.md
# Emits a single JSON manifest to stdout per `Inspector run` (data-model.md Entity 3).
# Human-readable diagnostics go to stderr.
#
# v1 — skeleton. Discovery, invocation, parsing, filter, severity-mapping, profile
# selection, and budget timer are layered on by tasks T009–T034. This skeleton
# covers arg parsing, the `--no-inspector` skip path, and a stub manifest so the
# dispatcher integration can land independently.

set -euo pipefail

# Optional debug tracing — set CODE_REVIEW_INSPECT_DEBUG=1 to enable.
if [[ "${CODE_REVIEW_INSPECT_DEBUG:-}" == "1" ]]; then
  set -x
fi

# ----- Prerequisites -----

if ! command -v jq >/dev/null 2>&1; then
  echo '{"status":"failed","warning":"jq is required but not found on PATH","findings":[]}'
  exit 0
fi

# ----- Top-level error trap -----
# Ensures a valid JSON manifest is always emitted, even on unexpected errors.
# ERR fires before EXIT, so the manifest is emitted while stdout is still open.
_unhandled_error() {
  local line="$1"
  echo "run-inspector.sh: unhandled error at line ${line}" >&2
  # Emit a well-formed failed manifest so the dispatcher never sees raw stderr.
  jq -n --arg w "inspector wrapper crashed at line ${line}; see stderr" \
    '{ status: "failed", warning: $w, findings: [] }' 2>/dev/null \
    || printf '{"status":"failed","warning":"inspector wrapper crashed at line %s","findings":[]}' "${line}"
  exit 0
}
trap '_unhandled_error ${LINENO}' ERR

# ----- Argument parsing -----

PROJECT_ROOT=""
DIFF_SCOPE=""
BUDGET_S=""
PROFILE=""
NO_INSPECTOR=0

_need_value() {
  if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
    echo "run-inspector.sh: $1 requires a value" >&2
    printf '{"status":"failed","warning":"%s requires a value","findings":[]}' "$1"
    exit 0
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)   _need_value "$@"; PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*) PROJECT_ROOT="${1#*=}"; shift ;;
    --diff-scope)     _need_value "$@"; DIFF_SCOPE="$2"; shift 2 ;;
    --diff-scope=*)   DIFF_SCOPE="${1#*=}"; shift ;;
    --budget-seconds) _need_value "$@"; BUDGET_S="$2"; shift 2 ;;
    --budget-seconds=*) BUDGET_S="${1#*=}"; shift ;;
    --profile)        _need_value "$@"; PROFILE="$2"; shift 2 ;;
    --profile=*)      PROFILE="${1#*=}"; shift ;;
    --no-inspector)   NO_INSPECTOR=1; shift ;;
    *)
      echo "run-inspector.sh: unknown argument: $1" >&2
      printf '{"status":"failed","warning":"unknown argument: %s","findings":[]}' "$1"
      exit 0
      ;;
  esac
done

# ----- Argument validation -----
# Early exits emit JSON to stdout so the dispatcher always gets parseable output.

_arg_error() {
  local msg="$1"
  echo "run-inspector.sh: ${msg}" >&2
  printf '{"status":"failed","warning":"%s","findings":[]}' "$msg"
  exit 0
}

if [[ -z "$PROJECT_ROOT" ]]; then
  _arg_error "--project-root is required"
fi
if [[ -z "$DIFF_SCOPE" ]]; then
  _arg_error "--diff-scope is required"
fi
if [[ -z "$BUDGET_S" ]]; then
  _arg_error "--budget-seconds is required"
fi

# Resolve PROJECT_ROOT to an absolute path.
PROJECT_ROOT=$(cd "$PROJECT_ROOT" && pwd)

# Compute scope counts EARLY — they are used by every manifest-emitting code
# path (skipped, ok, failed, budget-exceeded). Computing them up front means
# the failed / budget-exceeded paths surface accurate scope counts even when
# the inspector subprocess never gets to run.
if [[ -f "${DIFF_SCOPE}" ]]; then
  DIFF_PATHS_JSON_EARLY="$(jq -R -s 'split("\n") | map(select(. != ""))' "${DIFF_SCOPE}")"
  FILES_CHANGED="$(printf '%s' "${DIFF_PATHS_JSON_EARLY}" | jq 'length')"
  LINES_CHANGED="$(wc -l < "${DIFF_SCOPE}" 2>/dev/null | tr -d ' ' || echo 0)"
else
  DIFF_PATHS_JSON_EARLY='[]'
  FILES_CHANGED=0
  LINES_CHANGED=0
fi

# ----- Helper: emit a manifest and exit 0 -----

emit_manifest() {
  local status="$1"
  local warning="$2"
  shift 2

  local jq_args=(
    --arg status "$status"
    --arg budget "$BUDGET_S"
  )
  local jq_filter='{
    status: $status,
    budget_s: ($budget | tonumber),
    scope: { files_changed: 0, lines_changed: 0 },
    findings: []
  }'

  if [[ -n "$warning" ]]; then
    jq_args+=(--arg warning "$warning")
    jq_filter='{ status: $status, warning: $warning, budget_s: ($budget | tonumber), scope: { files_changed: 0, lines_changed: 0 }, findings: [] }'
  fi

  if ! jq -n "${jq_args[@]}" "$jq_filter" 2>/dev/null; then
    printf '{"status":"%s","warning":"%s","findings":[]}' "$status" "$warning"
  fi
  exit 0
}

# ----- Helper: emit a full failed manifest (used after binary is discovered) -----
#
# Uses variables in scope; tolerates undefined ones via :- defaults.

emit_full_manifest_failed() {
  local warning="$1"
  if ! jq -n \
    --arg status "failed" \
    --arg warning "${warning}" \
    --arg binary "${INSPECT_BIN:-}" \
    --arg version "${INSPECT_VERSION_NUM:-}" \
    --arg profile_source "${PROFILE_SOURCE:-default}" \
    --arg profile_path "${PROFILE_PATH:-}" \
    --arg profile_name "${PROFILE_NAME:-IntelliJ defaults}" \
    --arg duration "${DURATION_S:-0}" \
    --arg budget "${BUDGET_S}" \
    --arg files_changed "${FILES_CHANGED:-0}" \
    --arg lines_changed "${LINES_CHANGED:-0}" '
    {
      status: $status,
      warning: $warning,
      binary: (if $binary == "" then null else $binary end),
      binary_version: (if $version == "" then null else $version end),
      profile: { source: $profile_source, path: $profile_path, name: $profile_name },
      duration_s: ($duration | tonumber),
      budget_s: ($budget | tonumber),
      scope: { files_changed: ($files_changed | tonumber), lines_changed: ($lines_changed | tonumber) },
      findings: []
    }
  ' 2>/dev/null; then
    printf '{"status":"failed","warning":"%s","findings":[]}' "$warning"
  fi
  exit 0
}

# ----- Helper: emit a requires-prompt manifest (US3 multi-profile path) -----
#
# Args: profile-basenames as positional args. Sorted alphabetically before
# emission so the dispatcher's prompt order is deterministic.

emit_requires_prompt_manifest() {
  local sorted
  sorted=$(printf '%s\n' "$@" | sort)
  jq -n \
    --arg status "requires-prompt" \
    --arg budget "${BUDGET_S}" \
    --rawfile profiles <(printf '%s' "${sorted}") '
    {
      status: $status,
      budget_s: ($budget | tonumber),
      available_profiles: (
        if ($profiles | length) == 0
        then []
        else ($profiles | rtrimstr("\n") | split("\n"))
        end
      )
    }
  '
  exit 0
}

# ----- --no-inspector short-circuit (T024 — full implementation in US2) -----

if [[ "$NO_INSPECTOR" == "1" ]]; then
  emit_manifest "skipped" "Inspector skipped by --no-inspector flag"
fi

# ----- T009: Layered binary discovery -----
#
# Order: env override → `idea` on PATH → macOS .app → Toolbox apps dir → JETBRAINS_IDE_HOME.

discover_binary() {
  # Echo path on stdout, return 0 on success; print nothing and return 1 on miss.
  local candidate uname_s
  uname_s="$(uname -s)"

  # 1. Explicit override
  if [[ -n "${CODE_REVIEW_INSPECT_BIN:-}" ]] && [[ -x "${CODE_REVIEW_INSPECT_BIN}" ]]; then
    printf '%s\n' "${CODE_REVIEW_INSPECT_BIN}"
    return 0
  fi

  # 2. macOS .app bundles — checked BEFORE the PATH lookup because the Toolbox
  #    `idea` wrapper script on PATH uses `open -na` to background the GUI app
  #    and is unsuitable for headless `inspect`. Search both /Applications and
  #    ~/Applications (Toolbox 3.x default install location for IDE apps).
  if [[ "${uname_s}" == "Darwin" ]]; then
    for search_root in "/Applications" "${HOME}/Applications"; do
      [[ -d "${search_root}" ]] || continue
      shopt -s nullglob
      for app in "${search_root}"/*.app; do
        case "$(basename "${app}")" in
          IntelliJ\ IDEA*|WebStorm*|GoLand*|PyCharm*) ;;
          *) continue ;;
        esac
        for inner in idea webstorm goland pycharm; do
          if [[ -x "${app}/Contents/MacOS/${inner}" ]]; then
            printf '%s\n' "${app}/Contents/MacOS/${inner}"
            shopt -u nullglob
            return 0
          fi
        done
      done
      shopt -u nullglob
    done
  fi

  # 3. PATH lookup — fallback for non-macOS hosts and for users whose `idea`
  #    on PATH points at an inspectable binary (rare but valid). Reject Toolbox
  #    `open -na` wrappers detected by content sniff.
  if candidate="$(command -v idea 2>/dev/null)"; then
    if [[ -f "${candidate}" ]] && grep -qE '^[[:space:]]*open .*-na' "${candidate}" 2>/dev/null; then
      echo "run-inspector.sh: skipping ${candidate} — Toolbox GUI wrapper, not headless-inspectable" >&2
    else
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  # 4. JetBrains Toolbox apps dir
  local toolbox_root=""
  if [[ "${uname_s}" == "Darwin" ]]; then
    toolbox_root="${HOME}/Library/Application Support/JetBrains/Toolbox/apps"
  else
    toolbox_root="${HOME}/.local/share/JetBrains/Toolbox/apps"
  fi
  if [[ -d "${toolbox_root}" ]]; then
    for candidate in "${toolbox_root}"/*/bin/idea.sh "${toolbox_root}"/*/bin/idea; do
      [[ -x "${candidate}" ]] || continue
      printf '%s\n' "${candidate}"
      return 0
    done
  fi

  # 5. JETBRAINS_IDE_HOME
  if [[ -n "${JETBRAINS_IDE_HOME:-}" ]]; then
    for candidate in "${JETBRAINS_IDE_HOME}/bin/idea.sh" "${JETBRAINS_IDE_HOME}/bin/idea"; do
      [[ -x "${candidate}" ]] || continue
      printf '%s\n' "${candidate}"
      return 0
    done
  fi

  return 1
}

INSPECT_BIN="$(discover_binary || true)"
if [[ -z "${INSPECT_BIN}" ]]; then
  emit_manifest "skipped" "JetBrains CLI inspector binary not found; install or set CODE_REVIEW_INSPECT_BIN"
fi
echo "run-inspector.sh: discovered binary: ${INSPECT_BIN}" >&2

# Version check — require 2025.1+ per code-review/README.md prereq.
# Typical --version output: "IntelliJ IDEA 2025.1.4 (Build #IU-251.x.y)"
INSPECT_VERSION_RAW="$("${INSPECT_BIN}" --version 2>&1 | head -n1 || echo unknown)"
INSPECT_VERSION_NUM="$(printf '%s' "${INSPECT_VERSION_RAW}" | sed -nE 's/.*([0-9]{4}\.[0-9]+).*/\1/p' | head -n1)"
if [[ -z "${INSPECT_VERSION_NUM}" ]]; then
  emit_manifest "skipped" "JetBrains CLI inspector at ${INSPECT_BIN}: cannot determine version (got '${INSPECT_VERSION_RAW}')"
fi
INSPECT_MAJOR="${INSPECT_VERSION_NUM%%.*}"
INSPECT_MINOR="${INSPECT_VERSION_NUM##*.}"
if (( INSPECT_MAJOR < 2025 )) || (( INSPECT_MAJOR == 2025 && INSPECT_MINOR < 1 )); then
  emit_manifest "skipped" "JetBrains CLI inspector at ${INSPECT_BIN} is too old (${INSPECT_VERSION_NUM}); requires 2025.1+"
fi
echo "run-inspector.sh: version ${INSPECT_VERSION_NUM}" >&2

# ----- Profile selection (T031-T034 + T036) -----
#
# 1. --profile <basename> arg → lock to that file (T036)
# 2. exactly 1 *.xml in .idea/inspectionProfiles/ → auto-single (T032)
# 3. >1 *.xml → emit requires-prompt manifest, exit 0 (T033)
# 4. dir missing or empty → IntelliJ defaults (T034)

PROFILE_DIR="${PROJECT_ROOT}/.idea/inspectionProfiles"

if [[ -n "${PROFILE}" ]]; then
  # T036: --profile <basename> locks to a specific profile XML.
  # Race-condition guard: validate the file still exists at expected path.
  PROFILE_PATH="${PROFILE_DIR}/${PROFILE}"
  if [[ ! -f "${PROFILE_PATH}" ]]; then
    emit_full_manifest_failed "selected profile ${PROFILE} no longer present at expected path"
  fi
  PROFILE_SOURCE="user-prompted"
  PROFILE_NAME="${PROFILE%.xml}"
elif [[ -d "${PROFILE_DIR}" ]]; then
  # T031: enumerate *.xml in .idea/inspectionProfiles/, excluding the
  # profiles_settings.xml metadata file.
  shopt -s nullglob
  PROFILE_CANDIDATES=()
  for p in "${PROFILE_DIR}"/*.xml; do
    base="$(basename "${p}")"
    [[ "${base}" == "profiles_settings.xml" ]] && continue
    PROFILE_CANDIDATES+=( "${base}" )
  done
  shopt -u nullglob

  case "${#PROFILE_CANDIDATES[@]}" in
    0)
      # T034: dir exists but contains no usable profile XML → defaults.
      PROFILE_PATH=""
      PROFILE_SOURCE="default"
      PROFILE_NAME="IntelliJ defaults"
      ;;
    1)
      # T032: exactly one profile XML → auto-use.
      PROFILE_PATH="${PROFILE_DIR}/${PROFILE_CANDIDATES[0]}"
      PROFILE_SOURCE="auto-single"
      PROFILE_NAME="${PROFILE_CANDIDATES[0]%.xml}"
      echo "run-inspector.sh: profile (auto-single): ${PROFILE_NAME}" >&2
      ;;
    *)
      # T033: multiple profiles → emit requires-prompt manifest and exit.
      # The dispatcher (Phase 2.5) will prompt the user via AskUserQuestion
      # and re-invoke this wrapper with --profile <chosen>.
      emit_requires_prompt_manifest "${PROFILE_CANDIDATES[@]}"
      ;;
  esac
else
  # T034: dir missing entirely → IntelliJ defaults.
  PROFILE_PATH=""
  PROFILE_SOURCE="default"
  PROFILE_NAME="IntelliJ defaults"
fi

# ----- T010: Sandboxed inspector subprocess invocation -----

CFG_DIR="${TMPDIR:-/tmp}/code-review-inspect-cfg-$$"
SYS_DIR="${TMPDIR:-/tmp}/code-review-inspect-sys-$$"
LOG_DIR="${TMPDIR:-/tmp}/code-review-inspect-log-$$"
OUT_DIR="${TMPDIR:-/tmp}/code-review-inspect-out-$$"
mkdir -p "${CFG_DIR}" "${SYS_DIR}" "${LOG_DIR}" "${OUT_DIR}"

cleanup() {
  rm -rf "${CFG_DIR}" "${SYS_DIR}" "${LOG_DIR}" "${OUT_DIR}"
}
# Ctrl-C / SIGTERM handler: kill the inspector + watchdog before cleanup so
# orphaned `java` / `idea inspect` processes don't survive the wrapper.
interrupt() {
  echo "run-inspector.sh: interrupted; killing inspector subprocess..." >&2
  if [[ -n "${INSPECT_PID:-}" ]] && kill -0 "${INSPECT_PID}" 2>/dev/null; then
    kill -TERM "${INSPECT_PID}" 2>/dev/null || true
    sleep 1
    kill -KILL "${INSPECT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    kill -KILL "${WATCHDOG_PID}" 2>/dev/null || true
  fi
  cleanup
  exit 130
}
trap cleanup EXIT
trap interrupt INT TERM

# IDEA picks up sandboxed config/system/log paths via IDEA_PROPERTIES file.
# Sandboxing the config dir is required to avoid the directory lock the
# running IDE holds on its real config dir.
#
# Note: in a fully-sandboxed config the inspector has NO registered JDKs.
# Real-world reviews work fine because the user's project under review has
# its own .idea/misc.xml referring to a project SDK that the user's IDEA
# has set up — the inspector reads project-jdk-name from misc.xml and the
# JDK definition flows from the user's REAL config dir at startup (IDEA
# does merge plugin defaults with user config). For synthetic fixtures
# without IDEA-bootstrapped .idea/, the JDK lookup fails — the fixture's
# README explains the bootstrap step.
IDEA_PROPS_FILE="${CFG_DIR}/idea.properties"
cat > "${IDEA_PROPS_FILE}" <<EOF
idea.config.path=${CFG_DIR}
idea.system.path=${SYS_DIR}
idea.log.path=${LOG_DIR}
EOF
export IDEA_PROPERTIES="${IDEA_PROPS_FILE}"

START_S=$(date +%s)

# T021 (US2) — Background the inspector subprocess with a watchdog timer so
# we can terminate cleanly when the budget is exhausted. SIGTERM first; SIGKILL
# after a 5-second grace if the inspector ignores SIGTERM.
INSPECT_EXIT=0
BUDGET_KILLED=0
if [[ -n "${PROFILE_PATH}" ]]; then
  "${INSPECT_BIN}" inspect "${PROJECT_ROOT}" "${PROFILE_PATH}" "${OUT_DIR}" -format json \
    > "${LOG_DIR}/inspect-stdout.log" 2> "${LOG_DIR}/inspect-stderr.log" &
else
  "${INSPECT_BIN}" inspect "${PROJECT_ROOT}" "" "${OUT_DIR}" -format json \
    > "${LOG_DIR}/inspect-stdout.log" 2> "${LOG_DIR}/inspect-stderr.log" &
fi
INSPECT_PID=$!
echo "run-inspector.sh: inspector running (pid=${INSPECT_PID}, budget=${BUDGET_S}s); first-run Maven imports + indexing can take 30-90s..." >&2

# Watchdog: sleep budget, then SIGTERM. A second sub-shell escalates to SIGKILL
# 5 seconds later if the inspector hasn't exited.
(
  sleep "${BUDGET_S}"
  if kill -0 "${INSPECT_PID}" 2>/dev/null; then
    kill -TERM "${INSPECT_PID}" 2>/dev/null || true
    sleep 5
    if kill -0 "${INSPECT_PID}" 2>/dev/null; then
      kill -KILL "${INSPECT_PID}" 2>/dev/null || true
    fi
  fi
) &
WATCHDOG_PID=$!

# Block on the inspector. set -e is in effect, so we have to swallow
# wait's non-zero exit (the inspector exits non-zero on SIGTERM, which
# is normal here).
wait "${INSPECT_PID}" 2>/dev/null || INSPECT_EXIT=$?

# Cleanup the watchdog if it didn't fire.
kill -KILL "${WATCHDOG_PID}" 2>/dev/null || true
wait "${WATCHDOG_PID}" 2>/dev/null || true

END_S=$(date +%s)
DURATION_S=$((END_S - START_S))

# Did the watchdog fire? If duration ≥ budget AND the inspector exited
# non-zero (SIGTERM exit codes vary by shell — 143 on bash POSIX, 137 on
# SIGKILL), assume budget-exceeded.
if (( DURATION_S >= BUDGET_S )) && (( INSPECT_EXIT != 0 )); then
  BUDGET_KILLED=1
fi

# Persist stderr log path BEFORE cleanup runs (cleanup is on EXIT). On failed
# / budget-exceeded paths we want the manifest to point at the log; copy it to
# a stable location.
PERSIST_STDERR_LOG="${TMPDIR:-/tmp}/code-review-inspect-stderr-$$.log"
cp "${LOG_DIR}/inspect-stderr.log" "${PERSIST_STDERR_LOG}" 2>/dev/null || true

# T022 (US2) — budget-exceeded path: parse partial output and emit
# what we have. The parser at T011 below handles partial / truncated
# JSON files (jq -e returns empty on malformed; we filter via try/catch).
if (( BUDGET_KILLED == 1 )); then
  # Continue past the inspector block; the partial findings are surfaced
  # via the same parsing pipeline as the ok path. We tag with a flag the
  # final emit checks.
  STATUS_OVERRIDE="budget-exceeded"
elif (( INSPECT_EXIT != 0 )); then
  # T023 (US2) — failure path: non-zero inspector exit (not budget-killed).
  emit_full_manifest_failed "JetBrains inspector exited ${INSPECT_EXIT}; see stderr log at ${PERSIST_STDERR_LOG}"
fi

# ----- T011: JSON output parsing -----

# JetBrains inspect emits one JSON file per inspection short-name into ${OUT_DIR}.
# Each file shape (JSON):
#   { "version": "...", "problems": [ { "file": "...", "line": N, "severity": "WARNING",
#                                       "problem_class": { "id": "NullableProblems", "severity": "WARNING", "name": "..." },
#                                       "description": "..." }, ... ] }
# Some inspections emit empty arrays; the *.json glob handles missing-files (no matches → empty input).
shopt -s nullglob
RAW_FILES=( "${OUT_DIR}"/*.json )
shopt -u nullglob

if (( ${#RAW_FILES[@]} == 0 )); then
  echo "run-inspector.sh: inspector produced 0 output files — normal for diffs without JVM/inspectable source files" >&2
fi

# Normalise each inspection's *.json into a flat stream of problem-objects.
#
# Most inspections emit `{problems: [ {file, line, severity, problem_class, description}, ... ]}`.
# "Aggregate" inspections (filename pattern `<short>_aggregate.json`, e.g. `DuplicatedCode_aggregate.json`)
# emit `{problems: [ [ {file, line, start, end}, ... ], ... ]}` — each entry is an ARRAY of N
# location objects describing N related fragments (e.g. duplicate-code groups). The downstream
# diff-scope filter expects each entry to be an object with a `.file` key, so aggregate-aware
# unpacking is required here. We unpack array entries into one problem-object per fragment, and
# synthesise a `problem_class` / `severity` / `description` from the filename's short-name so
# severity-mapping and the [INSPECTOR:<name>] tag work uniformly.
#
# Guard: bash 3.2 (macOS default) treats empty arrays as "unbound" under set -u.
# All array expansions below are guarded with length checks before iterating.
RAW_PROBLEMS_PARTS=()
if (( ${#RAW_FILES[@]} > 0 )); then
  for f in "${RAW_FILES[@]}"; do
    base="$(basename "$f" .json)"
    short_name="${base%_aggregate}"
    if part="$(jq --arg short "$short_name" '
      [
        .problems[]? |
        if type == "object" then
          .
        elif type == "array" then
          length as $group_size |
          .[] |
          select(type == "object") |
          ({
            "problem_class": { "id": $short, "severity": "WEAK_WARNING", "name": $short },
            "severity": "WEAK_WARNING",
            "description": ("Aggregate finding (\($short)) — one of \($group_size) related locations")
          } + .)
        else
          empty
        end
      ]
    ' "$f" 2>/dev/null)"; then
      RAW_PROBLEMS_PARTS+=( "$part" )
    else
      echo "run-inspector.sh: warning: jq failed to parse $(basename "$f"); skipping" >&2
    fi
  done
fi

if (( ${#RAW_PROBLEMS_PARTS[@]} == 0 )); then
  RAW_PROBLEMS='[]'
else
  RAW_PROBLEMS="$(printf '%s\n' "${RAW_PROBLEMS_PARTS[@]}" | jq -s 'add // []' 2>/dev/null || echo '[]')"
fi

# T023 (US2) — malformed-output path
if ! printf '%s' "${RAW_PROBLEMS}" | jq -e . >/dev/null 2>&1; then
  emit_full_manifest_failed "JetBrains inspector emitted unparseable JSON; see stderr log at ${PERSIST_STDERR_LOG}"
fi

RAW_COUNT="$(printf '%s' "${RAW_PROBLEMS}" | jq 'length')"

# ----- T012: Diff-scope filter -----
#
# Read --diff-scope file into a jq array of repo-relative paths. Reject any
# inspector finding whose .file (after normalization to repo-relative) is not
# in the array.

# DIFF_PATHS_JSON / FILES_CHANGED / LINES_CHANGED were computed early, near
# the top of the script. Reuse them here.
DIFF_PATHS_JSON="${DIFF_PATHS_JSON_EARLY}"

if ! FILTERED_PROBLEMS="$(printf '%s' "${RAW_PROBLEMS}" | jq \
    --argjson scope "${DIFF_PATHS_JSON}" \
    --arg root "${PROJECT_ROOT}" '
      [
        .[] |
        select(type == "object") |
        . as $p |
        ($p.file // "") as $f |
        # JetBrains inspect emits .file in three observed forms:
        #   1. "file://$PROJECT_DIR$/relative/path"  (most common — IDEA macro form)
        #   2. "file:///absolute/filesystem/path"    (URL form with literal abs path)
        #   3. "/absolute/filesystem/path"           (legacy; original wrapper assumed this)
        # We normalise all three to a repo-relative path before matching against $scope.
        (
          if   ($f | startswith("file://$PROJECT_DIR$/")) then ($f | ltrimstr("file://$PROJECT_DIR$/"))
          elif ($f | startswith("file://" + $root + "/")) then ($f | ltrimstr("file://" + $root + "/"))
          elif ($f | startswith($root + "/"))             then ($f | ltrimstr($root + "/"))
          else $f end
        ) as $rel |
        if ($scope | index($rel)) != null then ($p + {"_relfile": $rel}) else empty end
      ]
    ' 2>>"${PERSIST_STDERR_LOG}")"; then
  emit_full_manifest_failed "JetBrains inspector emitted unexpected JSON shape that the diff-scope filter could not process; see stderr log at ${PERSIST_STDERR_LOG}"
fi

# ----- T013: Severity mapping -----
# Implemented inline in the jq pipeline below (T014). The mapping table is
# documented in references/advanced-patterns.md § "Severity mapping".

# ----- T014: Final JSON manifest emission -----

FINDINGS_JSON="$(printf '%s' "${FILTERED_PROBLEMS}" | jq '
  def severity_to_tier($s):
    if   $s == "ERROR"        then "🔴 Blocking"
    elif $s == "WARNING"      then "🟡 Important"
    elif $s == "WEAK_WARNING" then "🟢 Suggestion"
    elif ($s == "INFO" or $s == "TYPO" or $s == "GRAMMAR_ERROR") then "DROP"
    else "🟢 Suggestion"
    end;
  [
    to_entries[] |
    .key as $idx |
    .value as $p |
    ($p.problem_class.id // "Unknown") as $short |
    ($p.severity // $p.problem_class.severity // "INFO") as $sev |
    severity_to_tier($sev) as $tier |
    if $tier == "DROP" then empty else
      ($p.description // "") as $msg_raw |
      (if ($msg_raw | length) > 400 then (($msg_raw[0:400]) + "…") else $msg_raw end) as $msg |
      (($msg_raw | length) > 400) as $truncated |
      {
        id: ("INS-" + ((($idx + 1) | tostring) | if length < 3 then (("0" * (3 - length)) + .) else . end)),
        inspector_severity: $sev,
        review_tier: $tier,
        inspection_short_name: $short,
        tag: ("[INSPECTOR:" + $short + "]"),
        file: ($p._relfile // $p.file // ""),
        line_start: ($p.line // 1),
        line_end: ($p.line // 1),
        message: $msg,
        truncated: $truncated,
        dedup_state: "top-level"
      }
    end
  ]
' 2>/dev/null)" || FINDINGS_JSON='[]'

# Validate FINDINGS_JSON is parseable before passing to --argjson.
if ! printf '%s' "${FINDINGS_JSON}" | jq -e . >/dev/null 2>&1; then
  echo "run-inspector.sh: severity-mapping jq produced invalid JSON; resetting to []" >&2
  FINDINGS_JSON='[]'
fi

# T022 (US2) — final-emit status branching:
#   - STATUS_OVERRIDE="budget-exceeded" if the watchdog killed the inspector;
#     emit partial findings + the prescribed warning.
#   - Otherwise "ok".
FINAL_STATUS="${STATUS_OVERRIDE:-ok}"
FINAL_WARNING=""
if [[ "${FINAL_STATUS}" == "budget-exceeded" ]]; then
  FINDINGS_COUNT_PARTIAL="$(printf '%s' "${FINDINGS_JSON}" | jq 'length' 2>/dev/null || echo 0)"
  FINAL_WARNING="JetBrains inspector exceeded ${BUDGET_S}s budget; ${FINDINGS_COUNT_PARTIAL} partial findings emitted; raise budget with --inspector-budget=Ns"
fi

FINDINGS_COUNT="$(printf '%s' "${FINDINGS_JSON}" | jq 'length' 2>/dev/null || echo 0)"
echo "run-inspector.sh: ${RAW_COUNT} raw findings → ${FINDINGS_COUNT} after diff-scope filter + severity mapping (${#RAW_FILES[@]} JSON files parsed)" >&2

# Unified final-emit helper. Wraps the jq call with a last-resort printf fallback
# so stdout always receives valid JSON even if jq itself crashes (e.g., OOM on a
# giant findings array).
emit_final_manifest() {
  local jq_args=(
    --arg status "${FINAL_STATUS}"
    --arg binary "${INSPECT_BIN}"
    --arg version "${INSPECT_VERSION_NUM}"
    --arg profile_source "${PROFILE_SOURCE}"
    --arg profile_path "${PROFILE_PATH:-}"
    --arg profile_name "${PROFILE_NAME}"
    --arg duration "${DURATION_S}"
    --arg budget "${BUDGET_S}"
    --arg files_changed "${FILES_CHANGED}"
    --arg files_covered "${RAW_COUNT}"
    --arg lines_changed "${LINES_CHANGED}"
    --argjson findings "${FINDINGS_JSON}"
  )
  local jq_filter='{
    status: $status,
    binary: $binary,
    binary_version: $version,
    profile: { source: $profile_source, path: $profile_path, name: $profile_name },
    duration_s: ($duration | tonumber),
    budget_s: ($budget | tonumber),
    scope: {
      files_changed: ($files_changed | tonumber),
      files_inspector_covered: ($files_covered | tonumber),
      lines_changed: ($lines_changed | tonumber)
    },
    findings: $findings
  }'
  if [[ -n "${FINAL_WARNING}" ]]; then
    jq_args+=(--arg warning "${FINAL_WARNING}")
    jq_filter='{
      status: $status,
      warning: $warning,
      binary: $binary,
      binary_version: $version,
      profile: { source: $profile_source, path: $profile_path, name: $profile_name },
      duration_s: ($duration | tonumber),
      budget_s: ($budget | tonumber),
      scope: {
        files_changed: ($files_changed | tonumber),
        files_inspector_covered: ($files_covered | tonumber),
        lines_changed: ($lines_changed | tonumber)
      },
      findings: $findings
    }'
  fi

  if ! jq -n "${jq_args[@]}" "${jq_filter}" 2>/dev/null; then
    echo "run-inspector.sh: final jq emit failed; falling back to minimal manifest" >&2
    printf '{"status":"failed","warning":"final manifest emission failed — jq error on %s findings","findings":[]}' \
      "${FINDINGS_COUNT}"
  fi
}

emit_final_manifest
exit 0
