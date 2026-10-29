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

"""Salesforce tool: app-only (2LO / client-credentials) Files search.

There is no end user in this flow: the agent authenticates *as the application*
using a Connected App / External Client App consumer key/secret, so there is no
interactive consent and no ``ToolContext.request_credential`` involved. The tool
obtains an app token, caches it (with its instance URL) in session state, and runs
a SOSL full-text search over Salesforce Files (``ContentVersion``).

Salesforce does not return ``expires_in`` for the client-credentials grant, so the
token is cached with a conservative TTL (``SALESFORCE_TOKEN_TTL_SECONDS``) and the
tool also re-authenticates once on a ``401`` (an expired/revoked session).

The configured ``SalesforceClient`` is built in ``app/agent.py`` (where the
credentials are read fail-fast from the environment) and injected here.
"""

import os
import time

import requests
from google.adk.tools import ToolContext

from app.salesforce_client import SalesforceClient

# Per-session state key under which the app token + instance URL are cached.
_TOKEN_CACHE_KEY = "salesforce_app_token"
# Refresh slightly early so a token never expires mid-request.
_EXPIRY_SKEW_SECONDS = 60
# Fallback lifetime for the cached token (Salesforce omits expires_in); the org's
# session policy governs the real lifetime, so this is deliberately conservative.
_DEFAULT_TOKEN_TTL_SECONDS = 3600


def build_search_salesforce(client: SalesforceClient):
    """Builds the Salesforce search tool bound to a configured client.

    Args:
        client: A ``SalesforceClient`` configured with 2LO credentials.

    Returns:
        The ``search_salesforce`` tool function for the agent.
    """

    def _authenticate_and_cache(tool_context: ToolContext) -> dict:
        """Runs the 2LO grant and caches the token + instance URL in state."""
        token = client.authenticate()
        ttl = int(
            os.environ.get("SALESFORCE_TOKEN_TTL_SECONDS", _DEFAULT_TOKEN_TTL_SECONDS)
        )
        cached = {
            "access_token": token["access_token"],
            "instance_url": token["instance_url"],
            "expires_at": time.time() + ttl - _EXPIRY_SKEW_SECONDS,
        }
        tool_context.state[_TOKEN_CACHE_KEY] = cached
        return cached

    def _get_token(tool_context: ToolContext) -> dict:
        """Returns a cached token, fetching a new one (2LO) when needed."""
        cached = tool_context.state.get(_TOKEN_CACHE_KEY)
        if cached and cached.get("expires_at", 0) > time.time():
            return cached
        return _authenticate_and_cache(tool_context)

    def search_salesforce(query: str, tool_context: ToolContext) -> dict:
        """Searches the company's Salesforce document library (Files).

        Runs a SOSL full-text search across every file the application can read;
        the caller does not need to know a file name or folder.

        Args:
            query: The search term or issue description.

        Returns:
            A dict with a 'status' key; on success, 'data' holds matching
            documents (each a {'name', 'url', 'snippet'} dict). On failure,
            'error_message' explains why.
        """
        try:
            token = _get_token(tool_context)
        except Exception as e:  # surface any auth failure to the model
            return {
                "status": "error",
                "error_message": f"Salesforce auth failed: {e}",
            }

        try:
            documents = client.search_files(
                token["access_token"], token["instance_url"], query
            )
        except requests.HTTPError as e:
            # A 401 means the cached session expired or was revoked; re-auth once.
            status = e.response.status_code if e.response is not None else None
            if status != 401:
                return {
                    "status": "error",
                    "error_message": f"Salesforce search failed: {e}",
                }
            try:
                token = _authenticate_and_cache(tool_context)
                documents = client.search_files(
                    token["access_token"], token["instance_url"], query
                )
            except Exception as retry_error:
                return {
                    "status": "error",
                    "error_message": f"Salesforce search failed: {retry_error}",
                }
        except Exception as e:  # surface any other search failure to the model
            return {
                "status": "error",
                "error_message": f"Salesforce search failed: {e}",
            }

        return {
            "status": "success",
            "query": query,
            "data": documents,
        }

    return search_salesforce
