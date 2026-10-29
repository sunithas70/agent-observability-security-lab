# github-agent

Simple ReAct agent
Agent generated with `agents-cli` version `0.6.1`

## Project Structure

```
github-agent/
├── app/         # Core agent code
│   ├── agent.py               # Main agent logic
│   ├── fast_api_app.py        # FastAPI Backend server
│   └── app_utils/             # App utilities and helpers
├── tests/                     # Unit, integration, and load tests
├── GEMINI.md                  # AI-assisted development guide
└── pyproject.toml             # Project dependencies
```

> 💡 **Tip:** Use [Antigravity CLI](https://antigravity.google/) for AI-assisted development - project context is pre-configured in `GEMINI.md`.

## Requirements

Before you begin, ensure you have:
- **uv**: Python package manager (used for all dependency management in this project) - [Install](https://docs.astral.sh/uv/getting-started/installation/) ([add packages](https://docs.astral.sh/uv/concepts/dependencies/) with `uv add <package>`)
- **agents-cli**: Agents CLI - Install with `uv tool install google-agents-cli`
- **Google Cloud SDK**: For GCP services - [Install](https://cloud.google.com/sdk/docs/install)


## Configuration

Copy `.env.example` to `.env` and fill it in. No Secret Manager is used - the
GitHub PAT is read from `.env` locally and injected as an env var at deploy time.

| Variable | Required | Description |
|----------|----------|-------------|
| `GOOGLE_CLOUD_PROJECT` | yes | GCP project id |
| `GOOGLE_CLOUD_LOCATION` | yes | e.g. `global` |
| `GOOGLE_GENAI_USE_VERTEXAI` | yes | `True` |
| `MODEL` | yes | Gemini model id, e.g. `gemini-3.5-flash` |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | yes | GitHub PAT for the GitHub MCP server |
| `GITHUB_MCP_URL` | no | defaults to `https://api.githubcopilot.com/mcp/` |

### Getting a GitHub Personal Access Token (PAT)

The agent calls the hosted GitHub MCP server, which authenticates with a PAT. It
only uses read tools (`search_repositories`, `search_issues`, `list_issues`), so
a read-only token is enough.

**Option A - Classic token**
1. GitHub -> **Settings -> Developer settings -> Personal access tokens -> Tokens (classic)** (https://github.com/settings/tokens).
2. **Generate new token -> Generate new token (classic)**.
3. Set a name and expiration.
4. Select scopes: **`repo`** (repos + issues, incl. private) and **`read:org`**. For public repos only, **`public_repo`** suffices.
5. **Generate token** and copy the `ghp_...` value (shown only once).

**Option B - Fine-grained token**
1. GitHub -> **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens** (https://github.com/settings/personal-access-tokens/new).
2. **Generate new token**; set name, expiration, and resource owner.
3. **Repository access**: All repositories (or select specific ones).
4. **Permissions -> Repository permissions**: **Contents: Read-only**, **Issues: Read-only**, **Metadata: Read-only** (required).
5. **Generate token** and copy the `github_pat_...` value.

Add it to `.env`:

```
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_your_token_here
```


## Quick Start

Install `agents-cli` and its skills if not already installed:

```bash
uvx google-agents-cli setup
```

Install required packages:

```bash
agents-cli install
```

Test the agent with a local web server:

```bash
agents-cli playground
```

You can also use features from the [ADK](https://adk.dev/) CLI with `uv run adk`.

## Commands

| Command              | Description                                                                                 |
| -------------------- | ------------------------------------------------------------------------------------------- |
| `agents-cli install` | Install dependencies using uv                                                         |
| `agents-cli playground` | Launch local development environment                                                  |
| `agents-cli lint`    | Run code quality checks                                                               |
| `agents-cli eval`    | Evaluate agent behavior (generate, grade, analyze, and more — see `agents-cli eval --help`) |
| `uv run pytest tests/unit tests/integration` | Run unit and integration tests                                                        |
| `agents-cli deploy`  | Deploy agent to Agent Runtime                                                                |
| `agents-cli publish gemini-enterprise` | Register deployed agent to Gemini Enterprise                    || [A2A Inspector](https://github.com/a2aproject/a2a-inspector) | Launch A2A Protocol Inspector                                                        |

## 🛠️ Project Management

| Command | What It Does |
|---------|--------------|
| `agents-cli scaffold enhance` | Add CI/CD pipelines and Terraform infrastructure |
| `agents-cli infra cicd` | One-command setup of entire CI/CD pipeline + infrastructure |
| `agents-cli scaffold upgrade` | Auto-upgrade to latest version while preserving customizations |

---

## Development

Edit your agent logic in `app/agent.py` and test with `agents-cli playground` - it auto-reloads on save.

## Deployment

Deploys to **Agent Runtime** (set in `agents-cli-manifest.yaml`). A2A needs no
flag - it's enabled by `is_a2a: true` in the manifest, so the deployed container
serves the A2A card + JSON-RPC automatically (reached via the Agent Engine
`/api` passthrough). `agents-cli deploy` does not auto-load `.env`, so pass the
env vars (including the PAT) from `.env`:

```bash
agents-cli deploy --project <your-project-id> --no-confirm-project \
  --update-env-vars "$(grep -v '^#' .env | grep -v '^$' | grep -v '^GOOGLE_CLOUD_PROJECT' | paste -sd,)"
```

`GOOGLE_CLOUD_PROJECT` is excluded because `--project` sets it; everything else
(`MODEL`, `GITHUB_PERSONAL_ACCESS_TOKEN`, `GOOGLE_CLOUD_LOCATION`,
`GOOGLE_GENAI_USE_VERTEXAI`, `GITHUB_MCP_URL`) flows from `.env`. Deploys take
5-10 min; add `--no-wait` and poll with `agents-cli deploy --status`.

To add CI/CD and Terraform, run `agents-cli scaffold enhance`.
To set up your production infrastructure, run `agents-cli infra cicd`.

### Letting the root agent invoke this agent

Agent Runtime endpoints are always authenticated, so a caller (the root Code
Assist agent) must be authorized to invoke this engine. Grant the **root's**
Agent Runtime service account a role with `aiplatform.reasoningEngines.query`
(`roles/aiplatform.user`); without it the root gets **403** resolving this
agent's card. Project-wide grant (substitute a custom SA if you set one):

```bash
gcloud projects add-iam-policy-binding <your-project-id> \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"
```

## Testing the deployed agent

> ⚠️ **Agent Runtime is authenticated.** Unlike a public URL, its endpoints
> require a Google OAuth2 access token. Opening the agent-card URL in a browser
> or calling it with a plain `curl` returns **`401 UNAUTHENTICATED`
> (`CREDENTIALS_MISSING`)** — this is expected, **not** a broken deployment. You
> must send credentials.

On success, `agents-cli deploy` prints the **Agent Card URL** and the **Agent
Runtime ID**; the id is also saved in `deployment_metadata.json`. The engine URL
looks like:

```
https://us-central1-aiplatform.googleapis.com/v1/projects/<PROJECT_NUMBER>/locations/us-central1/reasoningEngines/<ENGINE_ID>
```

### Option 1 — `agents-cli run` (recommended; handles auth for you)

```bash
agents-cli run --url "<engine-url>" --mode a2a "What can you do? List your tools."
```

`--mode a2a` exercises the A2A surface (what other agents use); `--mode adk`
uses the native ADK streaming API. Auth is auto-detected from your Google Cloud
credentials.

### Option 2 — fetch the agent card with `curl` (needs a bearer token)

```bash
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/projects/<PROJECT_NUMBER>/locations/us-central1/reasoningEngines/<ENGINE_ID>/api/a2a/app/.well-known/agent-card.json"
```

A correct response lists the agent's skills (`search_repositories`,
`search_issues`, `list_issues`). Omitting the `Authorization` header is what
produces the 401 above.

## Observability

Built-in telemetry exports to Cloud Trace, BigQuery, and Cloud Logging.

## A2A Inspector

This agent supports the [A2A Protocol](https://a2a-protocol.org/). Use the [A2A Inspector](https://github.com/a2aproject/a2a-inspector) to test interoperability.
See the [A2A Inspector docs](https://github.com/a2aproject/a2a-inspector) for details.
