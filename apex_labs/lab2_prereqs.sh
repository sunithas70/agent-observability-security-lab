#!/usr/bin/env bash
#
# lab2_prereqs.sh  (Salesforce edition)
# =============================================================================
# Prepares a FRESH Google Cloud project (a new "Start lab" environment for
# APEX009 - "Agent Identity Foundations", aka Lab 2) so that Lab 2 can run.
#
# Lab 2 continues directly from APEX012 ("Build Enterprise Agents", Lab 1) and
# assumes the project already contains the two agents Lab 2 refactors:
#
#   * github-agent      -> deployed to Agent Runtime  (Lab 1 Task 2)
#   * salesforce-agent  -> deployed to Cloud Run      (Lab 1 Task 7)
#
# This script reproduces the END-OF-LAB-1 state (the "starter" state for Lab 2):
# both agents carry their tool secrets in .env (github = a GitHub PAT;
# salesforce = a Connected App consumer key/secret). Lab 2's whole exercise is
# the student moving those secrets onto Agent Identity Auth Manager connectors
# (Tasks 2-5), so this script deliberately does NOT create connectors, enable
# Agent Identity, or refactor any code.
#
# It also deliberately does NOT recreate the rest of Lab 1 (Stack Exchange
# agent, Bug DB / GKE / BigQuery agent, the code-assistant root, the Vertex AI
# Search datastore, Gemini Enterprise, or the Vertex AI Memory Bank) because
# Lab 2 does not touch any of those.
#
# -----------------------------------------------------------------------------
# What changed vs the old SharePoint prereqs
# -----------------------------------------------------------------------------
#   1. SharePoint agent -> Salesforce agent (env vars, .env, dir, validation).
#   2. Deploy region is us-central1 for BOTH agents (matches the Salesforce
#      Lab 2 manual and the agents-cli-manifest.yaml region). Connectors live in
#      us-west1, but that is an in-lab Task 1 step, not a prereq.
#   3. agents-cli is pinned to 1.0.0. Agent Identity ( --agent-identity ) is
#      only supported from agents-cli >= 1.0.0; the agents were scaffolded with
#      0.6.1, which cannot enable it. 1.0.0 is verified to carry the flag.
#   4. Both agents' manifests are bumped to acli_version 1.0.0 to match the
#      installed CLI.
#
# -----------------------------------------------------------------------------
# Agent source code
# -----------------------------------------------------------------------------
# The two agents' Lab-1-solution starter code is pulled from GCS. The default
# source is the maintainer bucket that holds the Salesforce Lab 1 solution:
#     gs://misha-agents/agents-salesforce
# For a student rollout, set AGENTS_GCS_SOURCE to the per-project lab bucket
# (e.g. gs://${PROJECT_ID}-bucket/agents) once it is seeded with the Salesforce
# agents. The script validates that the chosen source contains BOTH
# github-agent/ and salesforce-agent/ before deploying.
# -----------------------------------------------------------------------------
#
# USAGE (run in the Lab 2 Cloud Shell, signed in as the student account):
#   bash lab2_prereqs.sh
#   # or override the code source:
#   AGENTS_GCS_SOURCE=gs://your-bucket/agents bash lab2_prereqs.sh
# =============================================================================

set -euo pipefail

# Ensure user-local tool bin is on PATH for the whole run. `uv`, `uvx` and the
# `agents-cli` binary land in ~/.local/bin; without this, later calls fail with
# "command not found". Scoped to this script's process (does not touch the
# student's shell).
export PATH="${HOME}/.local/bin:${PATH}"

# ------------------------------- pretty logging ------------------------------
BOLD="$(tput bold 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
GREEN="$(tput setaf 2 2>/dev/null || true)"; YELLOW="$(tput setaf 3 2>/dev/null || true)"
RED="$(tput setaf 1 2>/dev/null || true)"; BLUE="$(tput setaf 4 2>/dev/null || true)"

log()  { echo "${BLUE}${BOLD}==>${RESET} ${BOLD}$*${RESET}"; }
ok()   { echo "${GREEN}  ✓ $*${RESET}"; }
warn() { echo "${YELLOW}  ! $*${RESET}"; }
die()  { echo "${RED}${BOLD}ERROR:${RESET} $*" >&2; exit 1; }

# Retry a flaky cloud command a few times. The labs warn that the first Agent
# Runtime deploy can hit a transient "code 13 INTERNAL" that succeeds on retry,
# so critical cloud calls are wrapped in this.
#   RETRY_MAX (default 3) and RETRY_DELAY seconds (default 20) are overridable
#   inline, e.g.  RETRY_MAX=2 RETRY_DELAY=30 retry <cmd...>
retry() {
  local max="${RETRY_MAX:-3}" delay="${RETRY_DELAY:-20}" n=1
  until "$@"; do
    if [ "${n}" -ge "${max}" ]; then return 1; fi
    warn "attempt ${n}/${max} failed; retrying in ${delay}s..."
    sleep "${delay}"; n=$((n + 1))
  done
}

trap 'rc=$?; echo >&2; die "Step failed (line ${LINENO}, exit ${rc}). This script is safe to re-run. If it was an auth error, run:  gcloud auth application-default login  then re-run this script."' ERR

# --------------------------------- config ------------------------------------
# The Salesforce Lab 2 manual deploys agents to us-central1 (REGION) and creates
# Auth Manager connectors in us-west1 (LOCATION, an in-lab step). The manifests
# also pin region us-central1. GOOGLE_CLOUD_LOCATION=global is only where the
# Gemini model is called (not a created resource), so it stays "global".
REGION="us-central1"            # deploy region for both agents
LOCATION="global"              # GOOGLE_CLOUD_LOCATION (model location) for both
MODEL="gemini-3.5-flash"      # Lab 1 default model (matches the manual .env)
GITHUB_MCP_URL="https://api.githubcopilot.com/mcp/"

# agents-cli version to pin. 1.0.0 is the first GA release that supports
# --agent-identity (verified: cmd_deploy.py exposes the flag and agent_runtime.py
# implements setup_agent_identity). Lab 2 Task 3/5 need it.
ACLI_VERSION="1.0.0"

# Cloud Run max instances for salesforce-agent. agents-cli defaults to 10, which
# at 4Gi/instance = 40Gi and can exceed this project's Cloud Run memory quota
# (MemAllocPerProjectRegion = 32Gi), failing deploy validation. 4 instances
# (=16Gi) fits with margin and is plenty for a single-user lab.
SF_MAX_INSTANCES="4"

# Code source. Defaults to the maintainer bucket holding the Salesforce Lab 1
# solution. Override for a student rollout (see header). The script picks the
# first candidate that contains BOTH github-agent/ and salesforce-agent/.
AGENTS_GCS_SOURCE="${AGENTS_GCS_SOURCE:-}"
DEFAULT_SOURCE="gs://${PROJECT_ID}-bucket/agents"

# =============================================================================
# 0. Project
# =============================================================================
log "Confirm the target project"
DEFAULT_PROJECT="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
read -rp "  Project ID [${DEFAULT_PROJECT}]: " INPUT_PROJECT
PROJECT_ID="${INPUT_PROJECT:-${DEFAULT_PROJECT}}"
[ -n "${PROJECT_ID}" ] || die "No project id provided."

gcloud config set project "${PROJECT_ID}" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
ok "Project: ${PROJECT_ID} (number ${PROJECT_NUMBER})"
ok "Deploy region: ${REGION} | model location: ${LOCATION} | agents-cli: ${ACLI_VERSION}"

# =============================================================================
# 1. Collect external secrets (never echoed, never stored in shell history)
# =============================================================================
log "Enter the external tool credentials from Lab 1"
echo "  (These are baked into each agent's .env so the initial deploy matches"
echo "   the end of Lab 1. You will re-enter them inside Lab 2 as well.)"
echo

read -rsp "  GitHub personal access token (ghp_...): " GITHUB_PERSONAL_ACCESS_TOKEN; echo
[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN}" ] || die "GitHub PAT is required."

read -rp  "  Salesforce My Domain host (e.g. yourorg.my.salesforce.com, no https://): " SALESFORCE_DOMAIN
[ -n "${SALESFORCE_DOMAIN}" ] || die "Salesforce My Domain is required."
# Normalize: strip any scheme/trailing slash the user may paste.
SALESFORCE_DOMAIN="${SALESFORCE_DOMAIN#https://}"; SALESFORCE_DOMAIN="${SALESFORCE_DOMAIN#http://}"
SALESFORCE_DOMAIN="${SALESFORCE_DOMAIN%%/}"

read -rp  "  Salesforce Consumer Key (SALESFORCE_CLIENT_ID): " SALESFORCE_CLIENT_ID
[ -n "${SALESFORCE_CLIENT_ID}" ] || die "Salesforce consumer key is required."

read -rsp "  Salesforce Consumer Secret (SALESFORCE_CLIENT_SECRET): " SALESFORCE_CLIENT_SECRET; echo
[ -n "${SALESFORCE_CLIENT_SECRET}" ] || die "Salesforce consumer secret is required."

# The deploy injects these via --update-env-vars "KEY=VAL,KEY=VAL", which splits
# on commas. A comma inside a value would corrupt the env vars, so reject it now
# with a clear message rather than failing cryptically during deploy.
for _v in "${GITHUB_PERSONAL_ACCESS_TOKEN}" "${SALESFORCE_DOMAIN}" \
          "${SALESFORCE_CLIENT_ID}" "${SALESFORCE_CLIENT_SECRET}"; do
  case "${_v}" in
    *,*) die "One of your credentials contains a comma, which cannot be passed to the deploy. Regenerate that secret so it has no comma, then re-run." ;;
  esac
done
ok "Secrets captured."

echo
log "Starting unattended setup (~15-20 min): enable APIs, install agents-cli, stage code, deploy 2 agents."
log "You can leave this running — a completion summary prints at the end."

# =============================================================================
# 2. Enable the APIs the two deploys need
# =============================================================================
log "Enabling required APIs (this can take a minute)"
retry gcloud services enable \
  aiplatform.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  logging.googleapis.com \
  cloudtrace.googleapis.com \
  --project "${PROJECT_ID}"
ok "APIs enabled."

# Pre-provision the Vertex AI / Reasoning Engine service agents so the first
# Agent Runtime deploy in a brand-new project doesn't race their creation.
# Non-fatal: if it's already there or not needed, we just continue.
gcloud beta services identity create --service=aiplatform.googleapis.com \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || true

# Grant the Agent Runtime (Reasoning Engine) service agent the roles a deployed
# agent needs to START and serve: call the Gemini model + write telemetry. In a
# brand-new project these are NOT present, which makes the first Agent Runtime
# deploy "fail to start and cannot serve traffic". Lab 1 Task 6 granted these;
# Lab 2's Appendix verifies them. The service agent can take a few seconds to
# exist after the identity-create above, so we retry a bit before giving up.
log "Granting the Agent Runtime service agent its model + telemetry roles"
RE_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
for role in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent; do
  RETRY_MAX=5 RETRY_DELAY=15 retry gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${RE_SA}" --role="${role}" \
    --condition=None --quiet >/dev/null \
    || warn "Could not grant ${role} to ${RE_SA} (may already be present, or the service agent is still provisioning)."
done
ok "Agent Runtime service agent roles ensured (${RE_SA})."

# =============================================================================
# 3. Install agents-cli, pinned to ${ACLI_VERSION}
# =============================================================================
log "Installing agents-cli ${ACLI_VERSION}"
if ! command -v uv >/dev/null 2>&1; then
  warn "uv not found; installing uv (Astral)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
fi
# uv tool install pins the version and puts the agents-cli binary on PATH
# (~/.local/bin), which persists for the later deploy calls. --force makes the
# script idempotent if a different version was already installed.
uv tool install "google-agents-cli==${ACLI_VERSION}" --force
hash -r  # forget any stale command lookups so the new agents-cli is found
command -v agents-cli >/dev/null 2>&1 || die "agents-cli not on PATH after install (looked in ~/.local/bin). Open a new shell and re-run."
ACLI_ACTUAL="$(agents-cli info 2>/dev/null | grep -ioE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
case "${ACLI_ACTUAL}" in
  "${ACLI_VERSION}") ok "agents-cli ${ACLI_ACTUAL} ready." ;;
  "") warn "Could not parse agents-cli version from 'agents-cli info'; continuing." ;;
  *)  warn "agents-cli reports ${ACLI_ACTUAL}, expected ${ACLI_VERSION}; continuing." ;;
esac

# =============================================================================
# 4. Fetch the agent code
# =============================================================================
log "Fetching agent source code from GCS"

# A candidate source is usable only if it contains BOTH agent directories.
source_has_agents() {
  gcloud storage ls "$1/github-agent/" >/dev/null 2>&1 \
    && gcloud storage ls "$1/salesforce-agent/" >/dev/null 2>&1
}

find_source() {
  if [ -n "${AGENTS_GCS_SOURCE}" ]; then
    source_has_agents "${AGENTS_GCS_SOURCE}" && { echo "${AGENTS_GCS_SOURCE}"; return 0; }
    die "AGENTS_GCS_SOURCE='${AGENTS_GCS_SOURCE}' does not contain both github-agent/ and salesforce-agent/."
  fi
  for cand in "${DEFAULT_SOURCE}" "gs://${PROJECT_ID}-bucket/agents" "gs://${PROJECT_ID}/agents"; do
    if source_has_agents "${cand}"; then echo "${cand}"; return 0; fi
  done
  return 1
}

SRC="$(find_source)" || die "Could not find Salesforce agent code (github-agent/ + salesforce-agent/) in ${DEFAULT_SOURCE}, gs://${PROJECT_ID}-bucket/agents, or gs://${PROJECT_ID}/agents. Set AGENTS_GCS_SOURCE to the correct bucket."
ok "Source: ${SRC}"

rm -rf ~/agents && mkdir -p ~/agents
gcloud storage cp -r "${SRC}/github-agent" "${SRC}/salesforce-agent" ~/agents/
[ -d ~/agents/github-agent ]     || die "github-agent/ missing after download from ${SRC}"
[ -d ~/agents/salesforce-agent ] || die "salesforce-agent/ missing after download from ${SRC}"
ok "Code downloaded to ~/agents (github-agent, salesforce-agent)"

# Bump both manifests' acli_version to match the installed CLI, so the deploy
# does not run in a stale (0.6.1) scaffold-compatibility mode.
for mf in ~/agents/github-agent/agents-cli-manifest.yaml ~/agents/salesforce-agent/agents-cli-manifest.yaml; do
  [ -f "${mf}" ] || { warn "Manifest missing: ${mf}"; continue; }
  sed -i -E "s/^([[:space:]]*acli_version:[[:space:]]*)\"?[0-9]+\.[0-9]+\.[0-9]+\"?/\1\"${ACLI_VERSION}\"/" "${mf}"
done
ok "Manifests set to acli_version ${ACLI_VERSION}."

# Helper: build the --update-env-vars string exactly as the labs do (skip
# comments, blanks, and GOOGLE_CLOUD_PROJECT which --project sets).
env_vars_from_file() {
  grep -v '^#' "$1" | grep -v '^$' | grep -v '^GOOGLE_CLOUD_PROJECT' | paste -sd,
}

# =============================================================================
# 5. Deploy github-agent to Agent Runtime  (reproduces Lab 1 Task 2)
# =============================================================================
log "Deploying github-agent to Agent Runtime (5-10 min)"
cd ~/agents/github-agent
cat > .env <<EOF
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${LOCATION}
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=${MODEL}
GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN}
GITHUB_MCP_URL=${GITHUB_MCP_URL}
EOF

GH_ENV_VARS="$(env_vars_from_file .env)"
RETRY_MAX=2 RETRY_DELAY=30 retry agents-cli deploy --project "${PROJECT_ID}" --region "${REGION}" --no-confirm-project \
  --update-env-vars "${GH_ENV_VARS}"
ok "github-agent deployed to Agent Runtime."

# Derive the deployed Agent Runtime URL from the metadata the CLI just wrote.
GITHUB_AGENT_URL=""
if [ -f deployment_metadata.json ]; then
  GH_RESOURCE="$(python3 -c 'import json,sys; print(json.load(open("deployment_metadata.json")).get("remote_agent_runtime_id",""))' 2>/dev/null || true)"
  if [ -n "${GH_RESOURCE}" ]; then
    GITHUB_AGENT_URL="https://${REGION}-aiplatform.googleapis.com/v1/${GH_RESOURCE}"
    ok "github-agent URL: ${GITHUB_AGENT_URL}"
  fi
fi
[ -n "${GITHUB_AGENT_URL}" ] || warn "Could not derive GITHUB_AGENT_URL from deployment_metadata.json."

# =============================================================================
# 6. Deploy salesforce-agent to Cloud Run  (reproduces Lab 1 Task 7)
# =============================================================================
log "Deploying salesforce-agent to Cloud Run (5-10 min)"
cd ~/agents/salesforce-agent
cat > .env <<EOF
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${LOCATION}
GOOGLE_GENAI_USE_VERTEXAI=True
MODEL=${MODEL}
SALESFORCE_DOMAIN=${SALESFORCE_DOMAIN}
SALESFORCE_CLIENT_ID=${SALESFORCE_CLIENT_ID}
SALESFORCE_CLIENT_SECRET=${SALESFORCE_CLIENT_SECRET}
EOF

SF_ENV_VARS="$(env_vars_from_file .env)"
# --max-instances caps total Cloud Run memory to fit the region's quota (see
# SF_MAX_INSTANCES above); without it, agents-cli's default of 10 can overflow it.
RETRY_MAX=2 RETRY_DELAY=30 retry agents-cli deploy --project "${PROJECT_ID}" --region "${REGION}" --no-confirm-project \
  --max-instances "${SF_MAX_INSTANCES}" \
  --update-env-vars "${SF_ENV_VARS}"
ok "salesforce-agent deployed to Cloud Run (max-instances=${SF_MAX_INSTANCES}, private)."

# NOTE: We deliberately do NOT make the service public. Lab 2 reaches the
# Salesforce service with the caller's identity token (`gcloud run services
# update salesforce-agent --no-iap` then `agents-cli run --mode a2a`), so
# allUsers access is unnecessary. It is also typically impossible here: the lab
# student role (roles/editor) cannot call run.services.setIamPolicy.

# =============================================================================
# 7. Supporting IAM grants (telemetry + model) that Lab 2's Appendix verifies
# =============================================================================
# agents-cli usually grants these during deploy; we assert them defensively so
# Lab 2's "verify the supporting grants" checks pass. Idempotent.
log "Ensuring telemetry + model grants on the Salesforce Cloud Run service account"
SF_SA="$(gcloud run services describe salesforce-agent --region "${REGION}" \
  --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null || true)"
if [ -z "${SF_SA}" ]; then
  SF_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  warn "No explicit SA on the service; assuming default compute SA: ${SF_SA}"
fi
for role in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent; do
  retry gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" --role="${role}" \
    --condition=None --quiet >/dev/null \
    || warn "Could not add ${role} to ${SF_SA} (may already be present / auto-granted)."
done
ok "Grants ensured for ${SF_SA}"
warn "The GitHub Agent Runtime identity's telemetry/model grants are created by"
warn "agents-cli at deploy time. Lab 2 Task 3 redeploys with --agent-identity and"
warn "grants the resulting SPIFFE principal there; nothing to pre-grant here."

# =============================================================================
# 8. a2a smoke test for the GitHub agent (NON-FATAL diagnostic)
# =============================================================================
# This reproduces the Lab 2 Task 3 test command against the freshly deployed
# (starter) GitHub agent. It is intentionally non-fatal: if a2a is broken we
# want the exact error surfaced here so it can be diagnosed, without aborting
# the whole prereqs run.
if [ -n "${GITHUB_AGENT_URL}" ]; then
  log "a2a smoke test (non-fatal): agents-cli run --mode a2a against github-agent"
  cd ~/agents/github-agent
  set +e
  A2A_OUT="$(agents-cli run --url "${GITHUB_AGENT_URL}" --mode a2a "List all my open GitHub issues" 2>&1)"
  A2A_RC=$?
  set -e
  echo "----------------------------------------------------------------------"
  echo "${A2A_OUT}"
  echo "----------------------------------------------------------------------"
  if [ "${A2A_RC}" -eq 0 ]; then
    ok "a2a smoke test succeeded."
  else
    warn "a2a smoke test FAILED (exit ${A2A_RC}). Output above — share it for diagnosis."
    warn "For comparison you can also try:  agents-cli run --url \"${GITHUB_AGENT_URL}\" --mode adk \"Find the google/adk-python repository\""
  fi
else
  warn "Skipping a2a smoke test (no GITHUB_AGENT_URL)."
fi

# =============================================================================
# 9. Leave the home directory pristine for Lab 2
# =============================================================================
# 9a. Remove ~/agents. Lab 2 Task 1 runs `gcloud storage cp -r
# gs://${PROJECT_ID}-bucket/agents ~/agents`; if ~/agents already exists (this
# script created it to deploy from), that copy nests into ~/agents/agents and
# breaks every later Lab 2 path. Removing it also wipes the local .env secrets.
cd ~
rm -rf ~/agents
ok "Removed local ~/agents so Lab 2 Task 1 downloads cleanly (and secrets are off disk)."

# 9b. Scrub stale agent URL / identity exports from ~/.bashrc. The lab home
# snapshot can ship with the author's values (e.g. GITHUB_AGENT_URL pointing at
# a DIFFERENT project), which get sourced into every shell and make Lab 2's
# `agents-cli run` tests hit the wrong project (403 PERMISSION_DENIED). Lab 2
# re-exports these itself, so removing the stale fallbacks is safe. Backup kept.
BASHRC="${HOME}/.bashrc"
STALE_RE='^[[:space:]]*export[[:space:]]+([A-Za-z0-9_]*_AGENT_URL|[A-Za-z0-9_]*_AGENT_IDENTITY|[A-Za-z0-9_]*_ENGINE_URL|[A-Za-z0-9_]*_CONNECTOR_URI)='
if [ -f "${BASHRC}" ] && grep -qE "${STALE_RE}" "${BASHRC}"; then
  cp "${BASHRC}" "${BASHRC}.prereq.bak"
  { grep -vE "${STALE_RE}" "${BASHRC}" || true; } > "${BASHRC}.tmp"
  mv "${BASHRC}.tmp" "${BASHRC}"
  warn "Scrubbed stale agent URL/identity exports from ~/.bashrc (backup: ~/.bashrc.prereq.bak)."
  warn "Your CURRENT shell still holds them — run 'exec bash' or open a new Cloud Shell tab before Lab 2."
else
  ok "No stale agent URL/identity exports found in ~/.bashrc."
fi

# =============================================================================
# Done
# =============================================================================
echo
log "${GREEN}Prerequisites complete.${RESET}"
cat <<SUMMARY

  Project              : ${PROJECT_ID}
  agents-cli           : ${ACLI_VERSION}
  github-agent         : deployed to Agent Runtime (region=${REGION})
  salesforce-agent     : deployed to Cloud Run (region=${REGION}, private)
  Code source          : ${SRC}

  You can now start Lab 2 (APEX009). When it asks for credentials, reuse:
    - the same GitHub PAT
    - the same Salesforce My Domain / consumer key / consumer secret
  you entered here.

SUMMARY
