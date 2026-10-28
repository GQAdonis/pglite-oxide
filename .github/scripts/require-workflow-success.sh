#!/usr/bin/env bash
set -euo pipefail

workflow="${1:?usage: require-workflow-success.sh <workflow> <sha> [timeout-seconds] [--job <name>] [--artifact <name>...]}"
sha="${2:?usage: require-workflow-success.sh <workflow> <sha> [timeout-seconds] [--job <name>] [--artifact <name>...]}"
timeout="${3:-7200}"
if [[ $# -ge 3 ]]; then
  shift 3
else
  shift "$#"
fi

required_artifacts=()
required_job=""
expected_run_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      expected_run_id="${2:?--run-id requires a run id}"
      shift 2
      ;;
    --job)
      required_job="${2:?--job requires a name}"
      shift 2
      ;;
    --artifact)
      required_artifacts+=("${2:?--artifact requires a name}")
      shift 2
      ;;
    --gate-artifact)
      gate_artifacts+=("${2:?--gate-artifact requires a name}")
      shift 2
      ;;
    --event)
      required_events+=("${2:?--event requires an event name}")
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$release_candidate" == true ]]; then
  if [[ "$workflow" != Release || ! "$expected_run_id" =~ ^[1-9][0-9]*$ ]]; then
    echo "--release-candidate requires Release and an explicit positive --run-id" >&2
    exit 2
  fi
  required_events=(workflow_dispatch)
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
if [[ ! "$sha" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "workflow gate SHA must be a full hexadecimal commit SHA" >&2
  exit 2
fi
if [[ -n "$qualification_products" ]]; then
  [[ "$workflow" == CI && ( -z "$expected_run_id" || ( "$qualification_wait" == true && "$qualification_plan" == false && "$qualification_dispatch" == false && "$expected_run_id" =~ ^[1-9][0-9]*$ ) ) ]] || {
    echo 'qualification selection requires CI; explicit --run-id is valid only with --qualification-products' >&2
    exit 2
  }
  qualification_scratch="$(mktemp -d)"
  trap 'rm -rf "$qualification_scratch"' EXIT
  QUALIFICATION_REQUEST_KEY="$(EXPECTED_SHA="$sha" PRODUCTS_JSON="$qualification_products" bun .github/scripts/workflow-run-metadata.mts qualification-key)"
  export QUALIFICATION_REQUEST_KEY
  required_events=(push workflow_dispatch)
fi

github_read() {
  local label="${1:?GitHub read label is required}"
  local response
  response="$(bun tools/release/github-read.mts --label "$label" -- "$2")" || return $?
  bun .github/scripts/workflow-run-metadata.mts "$3" <<<"$response"
}

github_paginated_json() {
  local label="${1:?GitHub paginated read label is required}"
  local field="${2:?GitHub paginated read field is required}"
  local endpoint="${3:?GitHub paginated read endpoint is required}"
  bun tools/release/github-read.mts \
    --label "$label" \
    --paginate-field "$field" \
    -- "$endpoint"
}

normalize_sha() {
  LC_ALL=C tr '[:upper:]' '[:lower:]'
}

emit_run_id() {
  local run_id="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "run_id=$run_id"
      echo "run_attempt=$selected_run_attempt"
      echo "artifact_metadata_json=$selected_artifacts_json"
      if [[ "$release_candidate" == true ]]; then
        ARTIFACTS_JSON="$selected_artifacts_json" bun .github/scripts/workflow-run-metadata.mts artifact-ids
      fi
      echo "gate_artifact_metadata_json=$selected_gate_artifacts_json"
    } >>"$GITHUB_OUTPUT"
  fi
  echo "selected $workflow run $run_id"
  if [[ "$qualification_plan" == true ]]; then echo 'qualification_request_required=false' >>"$GITHUB_OUTPUT"; fi
}

run_matches_request() {
  local run_id="$1"
  local row status
  row="$(
    github_read "$workflow run $run_id metadata" \
      "repos/$GH_REPO/actions/runs/$run_id" run-row
  )" || {
    status=$?
    echo "failed to inspect $workflow run $run_id" >&2
    return "$status"
  }

  local run_sha workflow_id run_event run_status run_conclusion run_attempt workflow_name
  IFS=$'\t' read -r run_sha workflow_id run_event run_status run_conclusion run_attempt <<<"$row"
  if [[ "$(printf '%s' "$run_sha" | normalize_sha)" != "$(printf '%s' "$sha" | normalize_sha)" ]]; then
    # A preparation recovery freezes the original source under a later Release
    # controller. Its lock/capsule still verify that source and approval run.
    if [[ "$release_candidate" != true ]] || ! bash tools/release/publication-controller.sh --changes-only \
      "$(printf '%s' "$sha" | normalize_sha)" "$(printf '%s' "$run_sha" | normalize_sha)"; then
      echo "$workflow run $run_id belongs to $run_sha, not $sha" >&2
      return 1
    fi
  fi
  workflow_name="$(
    github_read "workflow $workflow_id metadata" \
      "repos/$GH_REPO/actions/workflows/$workflow_id" workflow-name
  )" || {
    status=$?
    return "$status"
  }
  if [[ "$workflow_name" != "$workflow" ]]; then
    echo "run $run_id is workflow $workflow_name, not $workflow" >&2
    return 1
  fi
  if [[ "${#required_events[@]}" -gt 0 ]]; then
    local expected_event matched_event=false
    for expected_event in "${required_events[@]}"; do
      if [[ "$run_event" == "$expected_event" ]]; then
        matched_event=true
        break
      fi
    done
    if [[ "$matched_event" != true ]]; then
      echo "$workflow run $run_id has event $run_event; expected one of: ${required_events[*]}" >&2
      return 1
    fi
  fi
  # Publication may fail after preparation. Recovery accepts that completed run
  # only when its frozen candidate producer succeeded; CI still needs success.
  if [[ "$release_candidate" == true && "$run_status" == completed && "$run_conclusion" == failure ]]; then
    required_jobs+=("Prepare frozen publication candidate")
  elif [[ "$run_status" != "completed" || "$run_conclusion" != "success" ]]; then
    echo "$workflow run $run_id is $run_status/${run_conclusion:-<none>}, not completed/success" >&2
    return 1
  fi
  if [[ ! "$run_attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "$workflow run $run_id has an invalid run attempt" >&2
    return 64
  fi
  selected_run_attempt="$run_attempt"
}

emit_run_id() {
  local run_id="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "run_id=$run_id" >> "$GITHUB_OUTPUT"
  fi
  echo "selected $workflow run $run_id"
}

required_artifacts_present() {
  local run_id="$1"
  if [[ "${#required_artifacts[@]}" -eq 0 ]]; then
    required_json='[]'
  else
    required_json="$(printf '%s\n' "${required_artifacts[@]}" | bun .github/scripts/workflow-run-metadata.mts names)"
  fi
  local gate_json
  if [[ "${#gate_artifacts[@]}" -eq 0 ]]; then
    gate_json='[]'
  else
    gate_json="$(printf '%s\n' "${gate_artifacts[@]}" | bun .github/scripts/workflow-run-metadata.mts names)"
  fi
  local selection status
  # shellcheck disable=SC2016
  if selection="$(
    REQUIRED_ARTIFACTS_JSON="$required_json" \
      GATE_ARTIFACTS_JSON="$gate_json" \
      bun .github/scripts/workflow-run-metadata.mts select-artifacts <<<"$artifacts_json"
  )"; then
    selected_artifacts_json="$(
      SELECTION_JSON="$selection" bun .github/scripts/workflow-run-metadata.mts selected-artifacts
    )"
    selected_gate_artifacts_json="$(
      SELECTION_JSON="$selection" bun .github/scripts/workflow-run-metadata.mts selected-gates
    )"
  else
    status=$?
    selected_artifacts_json='[]'
    selected_gate_artifacts_json='[]'
    return "$status"
  fi
}

required_jobs_success() {
  local run_id="$1"
  if [[ "${#required_jobs[@]}" -eq 0 ]]; then
    return 0
  fi

  local artifacts
  artifacts="$(
    gh api "repos/$GH_REPO/actions/runs/$run_id/artifacts?per_page=100" \
      --paginate \
      --jq '.artifacts[].name'
  )" || {
    echo "failed to list artifacts for $workflow run $run_id" >&2
    return 1
  }
  local expected
  for expected in "${required_artifacts[@]}"; do
    if ! printf '%s\n' "$artifacts" | grep -Fxq -- "$expected"; then
      return 1
    fi
    return
  fi
  local failed
  failed="$(awk -F '\t' '$2 == "completed" && $3 != "success" && $6 == "causal" { print $4; exit }' <<<"$runs")"
  if [[ -n "$failed" ]]; then
    echo "candidate qualification failed: $failed; fix the cause or rerun that run, rather than dispatching another qualification" >&2
    exit 1
  fi
  if [[ "$qualification_plan" == true ]]; then
    echo 'qualification_request_required=true' >>"$GITHUB_OUTPUT"
    exit 0
  fi
  if [[ "$qualification_wait" == true ]]; then return; fi
  if [[ "$qualification_dispatch" == true ]] && awk -F '\t' '$2 == "completed" && $3 == "success" && $7 == "requested" { found=1 } END { exit found ? 0 : 1 }' <<<"$runs"; then return; fi
  local main_sha response requested_id row run_sha run_workflow rest
  main_sha="$(github_read 'main ref before qualification request' "repos/$GH_REPO/git/ref/heads/main" main-sha)" || exit $?
  if [[ "$main_sha" != "$sha" ]]; then
    echo "cannot request missing qualification for $sha: main is $main_sha; reuse or rerun an existing exact-source CI run" >&2
    exit 1
  fi
  EXPECTED_SHA="$sha" PRODUCTS_JSON="$qualification_products" bun .github/scripts/workflow-run-metadata.mts qualification-request >"$qualification_scratch/request.json"
  # Dispatch is a mutation: never apply the read retry policy to an ambiguous POST.
  if ! response="$(gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' "repos/$GH_REPO/actions/workflows/$workflow_id/dispatches" --input "$qualification_scratch/request.json")"; then
    echo "qualification dispatch outcome is unknown; inspect CI request $QUALIFICATION_REQUEST_KEY before resuming" >&2
    exit 1
  fi
  requested_id="$(bun .github/scripts/workflow-run-metadata.mts dispatch-run-id <<<"$response")" || exit 1
  echo "requested qualification: https://github.com/$GH_REPO/actions/runs/$requested_id"
  row="$(github_read "requested qualification run $requested_id" "repos/$GH_REPO/actions/runs/$requested_id" run-row)" || exit $?
  IFS=$'\t' read -r run_sha run_workflow rest <<<"$row"
  if [[ "$run_sha" != "$sha" || "$run_workflow" != "$workflow_id" ]]; then
    echo "qualification dispatch source changed; refusing run $requested_id for $run_sha" >&2
    exit 1
  fi
}

resolve_workflow_id() {
  local workflows_json
  workflows_json="$(
    github_paginated_json \
      "$workflow workflow inventory" \
      workflows \
      "repos/$GH_REPO/actions/workflows"
  )" || return $?
  # Resolve the immutable workflow id from the exact display name. This avoids
  # gh run list's arbitrary latest-N truncation and refuses ambiguous names.
  # shellcheck disable=SC2016
  WORKFLOW_NAME="$workflow" bun .github/scripts/workflow-run-metadata.mts workflow-id <<<"$workflows_json" || return 64
}

exact_sha_workflow_runs() {
  local workflow_id="$1"
  local runs_json
  runs_json="$(
    github_paginated_json \
      "$workflow exact-SHA run inventory for $sha" \
      workflow_runs \
      "repos/$GH_REPO/actions/workflows/$workflow_id/runs?head_sha=$sha"
  )" || return $?
  # shellcheck disable=SC2016
  EXPECTED_SHA="$(printf '%s' "$sha" | normalize_sha)" bun .github/scripts/workflow-run-metadata.mts runs <<<"$runs_json" || return 64
}

required_job_success() {
  local run_id="$1"
  if [[ -z "$required_job" ]]; then
    return 0
  fi

  local jobs_file
  jobs_file="$(mktemp)"
  if ! gh run view "$run_id" --repo "$GH_REPO" --json jobs > "$jobs_file"; then
    rm -f "$jobs_file"
    return 1
  fi

  local conclusion
  if ! conclusion="$(
    bun -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(Bun.argv[1], "utf8"));
const required = Bun.argv[2] ?? "";
const job = (data.jobs ?? []).find((candidate) => candidate?.name === required);
console.log(job?.conclusion ?? "");
' "$jobs_file" "$required_job"
  )"; then
    rm -f "$jobs_file"
    return 1
  fi
  rm -f "$jobs_file"
  [[ "$conclusion" == "success" ]]
}

if [[ -n "$expected_run_id" ]]; then
  if required_job_success "$expected_run_id" && required_artifacts_present "$expected_run_id"; then
    emit_run_id "$expected_run_id"
    exit 0
  fi
  echo "$workflow run $expected_run_id does not satisfy the required job/artifact gate" >&2
  exit 1
fi

deadline=$((SECONDS + timeout))
workflow_id=""
while true; do
  runs="$(gh run list \
    --repo "$GH_REPO" \
    --workflow "$workflow" \
    --commit "$sha" \
    --limit 10 \
    --json databaseId,status,conclusion,url,event \
    --jq '.[] | [.databaseId, .status, (.conclusion // ""), .url, .event] | @tsv')"
  if [ -n "$runs" ]; then
    echo "$runs"
    if [[ -n "$required_job" ]]; then
      candidate_run_ids="$(echo "$runs" | awk -F '\t' '{ print $1 }')"
    else
      candidate_run_ids="$(echo "$runs" | awk -F '\t' '$2 == "completed" && $3 == "success" { print $1 }')"
    fi
    for run_id in $candidate_run_ids; do
      if required_job_success "$run_id" && required_artifacts_present "$run_id"; then
        emit_run_id "$run_id"
        exit 0
      else
        status=$?
      fi
      echo "$workflow run $run_id does not satisfy the required job/artifact gate"
    done
    if echo "$runs" | awk -F '\t' '$2 != "completed" { active=1 } END { exit active ? 0 : 1 }'; then
      echo "$workflow is still running for $sha"
    elif [[ -z "$required_job" ]] && echo "$runs" | awk -F '\t' '$2 == "completed" && $3 != "success" && $5 != "workflow_dispatch" { failed=1 } END { exit failed ? 0 : 1 }'; then
      echo "$workflow failed for $sha" >&2
      exit 1
    else
      echo "waiting for successful $workflow workflow for $sha"
    fi
  else
    echo "waiting for $workflow workflow for $sha"
  fi
  if [[ -n "$qualification_products" && "$inventory_ready" == true ]]; then
    request_missing_qualification
    [[ "$qualification_dispatch" == false ]] || exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "timed out waiting for successful $workflow workflow for $sha" >&2
    exit 1
  fi
  sleep 60
done
