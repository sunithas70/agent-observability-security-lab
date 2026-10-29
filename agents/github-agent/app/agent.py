# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""GitHub sub-agent.

Talks to the hosted **GitHub MCP server** through the out-of-the-box ADK
`McpToolset`. Deployed to Agent Runtime and reached by the root Code Assist
agent over A2A (the A2A surface is wired automatically by the scaffold in
`app/fast_api_app.py` + `app/app_utils/a2a.py`).
"""

import os

from dotenv import load_dotenv
from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams
from google.genai import types

load_dotenv()

MODEL = os.environ["MODEL"]
GITHUB_TOKEN = os.environ["GITHUB_PERSONAL_ACCESS_TOKEN"]
GITHUB_MCP_URL = os.getenv("GITHUB_MCP_URL", "https://api.githubcopilot.com/mcp/")
GITHUB_TOOL_FILTER = ["search_repositories", "search_issues", "list_issues"]

github_mcp_toolset = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=GITHUB_MCP_URL,
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github.v3+json",
        },
    ),
    tool_filter=GITHUB_TOOL_FILTER,
)

root_agent = Agent(
    name="github_agent",
    model=Gemini(
        model=MODEL,
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    description=(
        "Specialized assistant for GitHub: searches repositories, issues, and "
        "pull requests via the GitHub MCP server."
    ),
    instruction=(
        "You are a specialized assistant for interacting with GitHub. "
        "Use the provided tools to search for repositories, find issues, and "
        "retrieve pull-request information, then answer with what you find. "
        "Be concise and cite the repository names / issue numbers you used."
    ),
    tools=[github_mcp_toolset],
)

app = App(
    root_agent=root_agent,
    name="app",
)
