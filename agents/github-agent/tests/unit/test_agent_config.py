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

"""Offline config tests for the GitHub sub-agent (no model/network calls)."""

from app import agent as agent_module
from app.agent import GITHUB_TOOL_FILTER, app, root_agent


def test_agent_identity() -> None:
    """The agent and app are named as the runner expects."""
    assert root_agent.name == "github_agent"
    # App name must match the agent directory for the runner to find sessions.
    assert app.name == "app"


def test_single_mcp_toolset_is_wired() -> None:
    """The agent exposes exactly one MCP toolset."""
    tool_types = [type(t).__name__ for t in root_agent.tools]
    assert tool_types == ["McpToolset"]


def test_tool_filter_is_read_only_subset() -> None:
    """Only the intended read-only GitHub tools are exposed."""
    assert GITHUB_TOOL_FILTER == [
        "search_repositories",
        "search_issues",
        "list_issues",
    ]


def test_mcp_url_default() -> None:
    """The default MCP endpoint targets the GitHub MCP server."""
    assert agent_module.GITHUB_MCP_URL.endswith("/mcp/")
