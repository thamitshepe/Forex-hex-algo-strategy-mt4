#!/bin/bash
# Make the Dokploy side of the deployment exist, then deploy it.
#
# The server side of DEPLOY.md used to be clicks: new Compose app, paste the file,
# set eleven variables, press Deploy, then scp a tarball into the volume. Every one
# of those is something a machine can do, so this script does them and CI calls it.
# Run it twice and the second run changes nothing.
#
# The API calls (Dokploy's documented v1 API, x-api-key auth):
#
#   GET  /api/project.all                 find the project
#   POST /api/project.create              ... or make one (Dokploy adds "production")
#   GET  /api/project.one                 that project's environments and services
#   POST /api/compose.create              make the app
#   POST /api/compose.update              sourceType=raw + composeFile=<the YAML>
#   POST /api/compose.saveEnvironment     the values the YAML interpolates
#   POST /api/compose.deploy              pull ghcr.io/...:live and recreate
#
# Why a Compose app and not an Application. Dokploy's Application (Docker-image)
# type has no way to carry `cap_add: SYS_PTRACE` or `shm_size: 512m` - neither
# exists in its schema and neither exists in its UI. Both are load-bearing: Wine
# needs ptrace to attach to the processes it spawns (without it the EA quietly
# never loads) and Wine and Xvfb pass pixels through shared memory (too little
# shows up as `BadAccess (MIT-SHM)` and a dead desktop). Compose hands the YAML to
# `docker compose` untouched, so a Compose app is the only Dokploy service type
# that can express them. The image still comes from GHCR; nothing builds on the
# server.
#
# Why `raw` and not a Git source. With sourceType=raw, composeFile *is* the YAML,
# so what runs is `deploy/docker-compose.yml` from the commit being deployed, not
# a copy somebody pasted once and that then drifted. Same rule the Dockerfile
# follows for the EA source.
#
# Usage - every input is an environment variable:
#
#   DOKPLOY_URL=https://dokploy.example.com \
#   DOKPLOY_API_TOKEN=... \
#   DOKPLOY_ENV="$(cat deploy/.env)" \
#   deploy/scripts/dokploy-apply.sh
#
#   DOKPLOY_URL / DOKPLOY_API_TOKEN  required: the instance and an API key
#   DOKPLOY_PROJECT                  project name     (default forex-hex-mt4)
#   DOKPLOY_APP                      compose app name (default hex-mt4)
#   COMPOSE_FILE                     YAML to deploy   (default deploy/docker-compose.yml)
#   DOKPLOY_ENV                      KEY=VALUE lines for .env (default: leave as-is)
#   DOKPLOY_ENV_FILE                 a file holding those lines; used if set
#   DEPLOY=0                         provision and update only, do not deploy
#   DOKPLOY_DRY_RUN=1                print the requests, send nothing
#
# DOKPLOY_APP is not cosmetic. Dokploy runs `docker compose -p <appName>`, and a
# Compose project name prefixes every named volume - so this string decides whether
# `hex-mt4-data` is the volume holding the terminal, the profile and the HEX-Logs
# CSVs, or a fresh empty one. Changing it starts the demo over from zero.
set -euo pipefail

DOKPLOY_URL="${DOKPLOY_URL:-}"
DOKPLOY_API_TOKEN="${DOKPLOY_API_TOKEN:-}"
DOKPLOY_PROJECT="${DOKPLOY_PROJECT:-forex-hex-mt4}"
DOKPLOY_APP="${DOKPLOY_APP:-hex-mt4}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.yml}"
DOKPLOY_ENV="${DOKPLOY_ENV:-}"
DOKPLOY_ENV_FILE="${DOKPLOY_ENV_FILE:-}"
DO_DEPLOY="${DEPLOY:-1}"
DOKPLOY_DRY_RUN="${DOKPLOY_DRY_RUN:-0}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
case "$COMPOSE_FILE" in /*) ;; *) COMPOSE_FILE="$REPO/$COMPOSE_FILE" ;; esac

# The environment is what the YAML interpolates. Either pass it inline, or name the
# file holding it - CI writes one so that a password never appears in the process
# table of a `sh -c` line.
if [ -n "$DOKPLOY_ENV_FILE" ]; then
  [ -f "$DOKPLOY_ENV_FILE" ] || die "env file not found: ${DOKPLOY_ENV_FILE}"
  DOKPLOY_ENV="$(cat "$DOKPLOY_ENV_FILE")"
fi

log() { printf '[dokploy] %s\n' "$*"; }
die() { printf '[dokploy] FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "$DOKPLOY_URL" ] || die "DOKPLOY_URL is empty. Point it at the instance, e.g. https://dokploy.example.com (no trailing slash)."
[ -n "$DOKPLOY_API_TOKEN" ] || die "DOKPLOY_API_TOKEN is empty. Dokploy -> Settings -> API Keys, then keep it in a secret."
[ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
command -v jq >/dev/null || die "jq is required (brew install jq / apt-get install jq)."

# `api METHOD PATH [BODY]` -> response body on stdout. A non-2xx is fatal and
# prints what Dokploy said, because "401" alone does not say the key is scoped
# wrong and "400" alone does not say which field it disliked.
api() {
  local method="$1" path="$2" data="${3:-}"
  if [ "$DOKPLOY_DRY_RUN" = "1" ]; then
    log "DRY ${method} ${path} ${data:0:160}" >&2   # stderr: stdout is the body
    printf '{}'
    return 0
  fi
  local args=(-fsS -X "$method" "${DOKPLOY_URL%/}${path}"
              -H 'accept: application/json'
              -H "x-api-key: $DOKPLOY_API_TOKEN")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  local out rc=0
  out="$(curl "${args[@]}" 2>&1)" || rc=$?
  [ "$rc" = "0" ] || die "${method} ${path} failed (curl ${rc}): ${out}"
  printf '%s' "$out"
}

# `first [jq args]` -> the first line jq prints, or empty. Guards against a match
# count > 1 turning a field into a multi-line value, which would corrupt a URL.
first() { jq -r "$@" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- project ---

project_id="$(api GET /api/project.all | first --arg name "$DOKPLOY_PROJECT" '
  (if type == "object" then (.projects // []) else . end)
  | .[]? | select(.name == $name) | .projectId')"

environment_id=""
if [ -n "$project_id" ]; then
  log "project '${DOKPLOY_PROJECT}' is already there (${project_id})"
else
  log "project '${DOKPLOY_PROJECT}' is missing - creating it"
  created="$(api POST /api/project.create \
    "$(jq -nc --arg name "$DOKPLOY_PROJECT" '{name: $name}')")"
  project_id="$(first '.project.projectId // empty' <<<"$created")"
  environment_id="$(first '.environment.environmentId // empty' <<<"$created")"
  if [ -z "$project_id" ]; then
    if [ "$DOKPLOY_DRY_RUN" = "1" ]; then
      project_id="dry-run-project"
    else
      die "project.create came back without a project: ${created}"
    fi
  fi
  log "created project '${DOKPLOY_PROJECT}' (${project_id})"
fi

# `project.one` is the endpoint that returns a project's environments *and* the
# services inside them, so it is also how an app from an earlier run is found
# again. Dokploy creates each project with a "production" environment already in
# it, which is the one a service has to be created in.
detail="$(api GET "/api/project.one?projectId=${project_id}")"
if [ "$DOKPLOY_DRY_RUN" != "1" ]; then
  if [ -z "$environment_id" ]; then
    environment_id="$(first '
      (.environments // []) as $envs
      | ([$envs[] | select(.isDefault == true)] + $envs) | .[0].environmentId // empty' \
      <<<"$detail")"
  fi
  [ -n "$environment_id" ] || die "project '${DOKPLOY_PROJECT}' has no environment to hold the app."
  compose_id="$(first --arg name "$DOKPLOY_APP" '
    .environments[]? | .compose[]? | select(.name == $name) | .composeId' <<<"$detail")"
else
  environment_id="${environment_id:-dry-run-environment}"
  compose_id=""
fi

# ---------------------------------------------------------------- the app ---

if [ -n "$compose_id" ]; then
  log "app '${DOKPLOY_APP}' is already there (${compose_id})"
else
  log "app '${DOKPLOY_APP}' is missing - creating it in ${environment_id}"
  created="$(api POST /api/compose.create "$(jq -nc \
    --arg name "$DOKPLOY_APP" --arg appName "$DOKPLOY_APP" \
    --arg environmentId "$environment_id" \
    '{name: $name, appName: $appName, environmentId: $environmentId,
      composeType: "docker-compose"}')")"
  compose_id="$(first '.composeId // .compose.composeId // empty' <<<"$created")"
  if [ -z "$compose_id" ]; then
    if [ "$DOKPLOY_DRY_RUN" = "1" ]; then
      compose_id="dry-run-compose"
    else
      die "compose.create came back without an id: ${created}"
    fi
  fi
  log "created app '${DOKPLOY_APP}' (${compose_id})"
fi

# The compose file is shipped, not referenced: with sourceType=raw Dokploy writes
# this exact YAML beside the app and runs it. `--rawfile` hands jq the file itself,
# so the bytes arrive intact including the final newline (a $(cat ...) silently
# strips it) and a `$`, a quote or a newline in the file cannot break the envelope.
[ -s "$COMPOSE_FILE" ] || die "compose file is empty: ${COMPOSE_FILE}"
api POST /api/compose.update "$(jq -nc \
  --arg composeId "$compose_id" --arg appName "$DOKPLOY_APP" \
  --rawfile composeFile "$COMPOSE_FILE" \
  '{composeId: $composeId, appName: $appName, sourceType: "raw",
    composeType: "docker-compose", composeFile: $composeFile,
    autoDeploy: false}')" >/dev/null
log "compose file pushed from ${COMPOSE_FILE#"$REPO"/}"

# The compose file runs instance 2 (`mt4-doge`, the only service). Its
# identity is not in the environment - the service block hard-codes MT4_INSTANCE=2
# - but its *credentials* are, and this call replaces the whole environment. An
# environment without MT4_LOGIN2 therefore doesn't quietly deploy a DOGE instance
# that logs into the gold account: check_instance_env refuses to boot, and that
# service restart-loops. Better to say so in the run log than to leave someone
# reading a crash loop on the server.
if grep -qE '^  mt4-doge:' "$COMPOSE_FILE" && ! printf '%s\n' "${DOKPLOY_ENV-}" | grep -qE '^MT4_LOGIN2=..*'; then
  log "WARNING: ${DOKPLOY_APP} runs the mt4-doge instance and this environment has no MT4_LOGIN2 - that container will refuse to boot (by design) until it has its own account"
fi

# The YAML reads ${MT4_LOGIN} and friends, so without this the interpolations are
# empty and the container boots with no account - which is why the environment is
# part of provisioning rather than a later click. One env file feeds the service
# in the compose file: instance 1 reads the plain names, instance 2 reads the "2"
# copies, and the instance number never appears here at all.
#
# saveEnvironment REPLACES the app's stored environment. That is why a switch set
# by hand in the app's Environment tab - MT4_RECLAIM_VOLUME, say - would silently
# vanish on the next CI push, and the container would go back to refusing to boot
# with nobody the wiser. So the stored environment is read back first and every
# name CI does not itself send is carried over: CI forever owns its own names and
# updates them (a password change must land), a hand-set extra survives every
# deploy until it is removed in the same tab. The stored block is read out of the
# `project.one` answer fetched above - when that projection carries no env, from
# `compose.one`.
if [ -n "$DOKPLOY_ENV" ]; then
  stored=""
  if [ "$DOKPLOY_DRY_RUN" != "1" ]; then
    stored="$(printf '%s' "$detail" | jq -r --arg id "$compose_id" '
      ([.environments[]?.compose[]? | select(.composeId == $id)][0].env // "")' \
      2>/dev/null || true)"
    if [ -z "$stored" ] && [ -n "$compose_id" ]; then
      stored="$(api POST /api/compose.one \
        "$(jq -nc --arg composeId "$compose_id" '{composeId: $composeId}')" \
        | jq -r '.env // ""' 2>/dev/null || true)"
    fi
  fi
  extra=""
  kept=0
  if [ -n "$stored" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      key="${line%%=*}"
      # A key name only: anything else is not an env line this script should
      # carry (an encrypted-at-rest blob would fail this on purpose).
      case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
      [ "${#key}" -le 64 ] || continue
      printf '%s\n' "$DOKPLOY_ENV" | grep -qxE "${key}=.*|${key}" && continue
      extra="${extra}${line}"$'\n'
      kept=$((kept + 1))
    done <<EOF_STORED
${stored}
EOF_STORED
  fi
  if [ "$kept" -gt 0 ]; then
    DOKPLOY_ENV="${DOKPLOY_ENV%$'\n'}"$'\n'"${extra%$'\n'}"
    log "kept ${kept} variable(s) that only the stored environment had - a hand-set switch survives this deploy"
  fi
  api POST /api/compose.saveEnvironment "$(jq -nc \
    --arg composeId "$compose_id" --arg env "$DOKPLOY_ENV" \
    '{composeId: $composeId, env: $env}')" >/dev/null
  log "environment saved ($(printf '%s\n' "$DOKPLOY_ENV" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' || true) variables)"
else
  log "DOKPLOY_ENV is empty - leaving the stored environment alone"
fi

# ----------------------------------------------------------------- deploy ---
if [ "$DO_DEPLOY" = "1" ]; then
  api POST /api/compose.deploy "$(jq -nc \
    --arg composeId "$compose_id" '{composeId: $composeId}')" >/dev/null
  log "deploy started - the boot log ends with 'terminal.exe is up' when it is really up"
else
  log "DEPLOY=0 - provisioned and updated, nothing restarted"
fi
