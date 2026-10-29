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

"""Offline tests for the Salesforce Files 2LO tool and client (network mocked).

The tool is built in ``app.agent`` from a ``SalesforceClient`` instance; we patch
the client class methods (``authenticate`` / ``search_files`` /
``download_version_text``) at their source so no network is hit. The client's
request layer is exercised separately by patching ``requests``.
"""

import io
import time
from unittest.mock import MagicMock

import pytest
import requests
from docx import Document

from app.agent import search_salesforce
from app.salesforce_client import (
    SalesforceClient,
    _build_excerpt,
    _build_sosl,
    _escape_sosl,
    _extract_text,
    _file_name,
)

_TOKEN = {"access_token": "app-token", "instance_url": "https://inst.my.salesforce.com"}


def _http_error(status: int) -> requests.HTTPError:
    """Builds a requests.HTTPError carrying a response with the given status."""
    resp = MagicMock()
    resp.status_code = status
    return requests.HTTPError(f"{status} boom", response=resp)


# --- Tool behavior -------------------------------------------------------------


def test_search_salesforce_success(mocker) -> None:
    """Happy path: mock the 2LO token fetch and file search; no network."""
    tool_context = MagicMock()
    tool_context.state = {}

    mock_auth = mocker.patch(
        "app.salesforce_client.SalesforceClient.authenticate",
        return_value=_TOKEN,
    )
    mock_search = mocker.patch(
        "app.salesforce_client.SalesforceClient.search_files",
        return_value=[
            {
                "name": "adr-014-async-timeouts.docx",
                "url": "https://inst.my.salesforce.com/lightning/r/ContentDocument/069x/view",
                "snippet": "Outbound calls must set a timeout.",
            }
        ],
    )

    result = search_salesforce("timeout", tool_context)

    assert result["status"] == "success"
    assert result["data"][0]["name"] == "adr-014-async-timeouts.docx"
    assert result["data"][0]["snippet"] == "Outbound calls must set a timeout."
    mock_auth.assert_called_once()
    mock_search.assert_called_once_with(
        "app-token", "https://inst.my.salesforce.com", "timeout"
    )
    cached = tool_context.state["salesforce_app_token"]
    assert cached["access_token"] == "app-token"
    assert cached["instance_url"] == "https://inst.my.salesforce.com"


def test_search_reuses_cached_token(mocker) -> None:
    """A cached, unexpired token skips re-auth."""
    tool_context = MagicMock()
    tool_context.state = {
        "salesforce_app_token": {
            "access_token": "cached-token",
            "instance_url": "https://cached.my.salesforce.com",
            "expires_at": time.time() + 1000,
        }
    }
    auth = mocker.patch("app.salesforce_client.SalesforceClient.authenticate")
    search = mocker.patch(
        "app.salesforce_client.SalesforceClient.search_files", return_value=[]
    )

    result = search_salesforce("q", tool_context)

    assert result["status"] == "success"
    auth.assert_not_called()
    search.assert_called_once_with(
        "cached-token", "https://cached.my.salesforce.com", "q"
    )


def test_expired_cached_token_triggers_reauth(mocker) -> None:
    """An expired cached token forces a fresh 2LO grant."""
    tool_context = MagicMock()
    tool_context.state = {
        "salesforce_app_token": {
            "access_token": "old-token",
            "instance_url": "https://old.my.salesforce.com",
            "expires_at": time.time() - 10,
        }
    }
    auth = mocker.patch(
        "app.salesforce_client.SalesforceClient.authenticate", return_value=_TOKEN
    )
    search = mocker.patch(
        "app.salesforce_client.SalesforceClient.search_files", return_value=[]
    )

    result = search_salesforce("q", tool_context)

    assert result["status"] == "success"
    auth.assert_called_once()
    search.assert_called_once_with("app-token", "https://inst.my.salesforce.com", "q")


def test_401_reauthenticates_once_and_retries(mocker) -> None:
    """A 401 on search invalidates the session and retries after re-auth."""
    tool_context = MagicMock()
    tool_context.state = {
        "salesforce_app_token": {
            "access_token": "stale-token",
            "instance_url": "https://stale.my.salesforce.com",
            "expires_at": time.time() + 1000,
        }
    }
    auth = mocker.patch(
        "app.salesforce_client.SalesforceClient.authenticate", return_value=_TOKEN
    )
    search = mocker.patch(
        "app.salesforce_client.SalesforceClient.search_files",
        side_effect=[_http_error(401), [{"name": "A", "url": "u", "snippet": "s"}]],
    )

    result = search_salesforce("q", tool_context)

    assert result["status"] == "success"
    assert result["data"][0]["name"] == "A"
    auth.assert_called_once()
    assert search.call_count == 2
    search.assert_called_with("app-token", "https://inst.my.salesforce.com", "q")


def test_non_401_http_error_returns_error_dict(mocker) -> None:
    """A non-401 HTTP error is surfaced as a structured error, not a retry."""
    tool_context = MagicMock()
    tool_context.state = {}
    mocker.patch(
        "app.salesforce_client.SalesforceClient.authenticate", return_value=_TOKEN
    )
    search = mocker.patch(
        "app.salesforce_client.SalesforceClient.search_files",
        side_effect=_http_error(500),
    )

    result = search_salesforce("q", tool_context)

    assert result["status"] == "error"
    assert "search failed" in result["error_message"].lower()
    search.assert_called_once()


def test_search_returns_error_dict_on_auth_failure(mocker) -> None:
    """Auth failures are surfaced as a structured error, not an exception."""
    tool_context = MagicMock()
    tool_context.state = {}
    mocker.patch(
        "app.salesforce_client.SalesforceClient.authenticate",
        side_effect=RuntimeError("bad credentials"),
    )

    result = search_salesforce("q", tool_context)

    assert result["status"] == "error"
    assert "auth failed" in result["error_message"].lower()


# --- Client request layer ------------------------------------------------------


def test_authenticate_posts_client_credentials(mocker) -> None:
    """authenticate performs the client-credentials grant and returns token JSON."""
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = dict(_TOKEN)
    post = mocker.patch("app.salesforce_client.requests.post", return_value=resp)

    client = SalesforceClient("myorg.my.salesforce.com", "cid", "secret")
    token = client.authenticate()

    assert token["access_token"] == "app-token"
    url, kwargs = post.call_args[0][0], post.call_args[1]
    assert url == "https://myorg.my.salesforce.com/services/oauth2/token"
    assert kwargs["data"]["grant_type"] == "client_credentials"
    assert kwargs["data"]["client_id"] == "cid"


def test_search_files_maps_records_and_enriches_top_hits(mocker) -> None:
    """search_files issues a SOSL GET and enriches hits with a downloaded excerpt."""
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {
        "searchRecords": [
            {
                "Id": "068A",
                "Title": "adr-014-async-timeouts",
                "FileExtension": "docx",
                "ContentDocumentId": "069A",
            }
        ]
    }
    get = mocker.patch("app.salesforce_client.requests.get", return_value=resp)
    mocker.patch(
        "app.salesforce_client.SalesforceClient.download_version_text",
        return_value=("filler " * 40) + " NEEDLE timeout rule " + ("tail " * 40),
    )

    client = SalesforceClient("org.my.salesforce.com", "c", "s")
    docs = client.search_files("tok", "https://inst.my.salesforce.com", "NEEDLE")

    assert len(docs) == 1
    assert docs[0]["name"] == "adr-014-async-timeouts.docx"
    assert docs[0]["url"] == (
        "https://inst.my.salesforce.com/lightning/r/ContentDocument/069A/view"
    )
    assert "NEEDLE" in docs[0]["snippet"]
    # Endpoint + auth header + SOSL param.
    url = get.call_args[0][0]
    kwargs = get.call_args[1]
    assert url == "https://inst.my.salesforce.com/services/data/v62.0/search"
    assert kwargs["headers"]["Authorization"] == "Bearer tok"
    assert kwargs["params"]["q"].startswith("FIND {NEEDLE} IN ALL FIELDS")
    assert "RETURNING ContentVersion(" in kwargs["params"]["q"]


def test_search_files_enrichment_failure_leaves_empty_snippet(mocker) -> None:
    """A download/parse failure leaves an empty snippet (title still returned)."""
    resp = MagicMock()
    resp.status_code = 200
    resp.json.return_value = {
        "searchRecords": [
            {
                "Id": "068A",
                "Title": "doc",
                "FileExtension": "docx",
                "ContentDocumentId": "069A",
            }
        ]
    }
    mocker.patch("app.salesforce_client.requests.get", return_value=resp)
    mocker.patch(
        "app.salesforce_client.SalesforceClient.download_version_text",
        side_effect=RuntimeError("download boom"),
    )

    client = SalesforceClient("org.my.salesforce.com", "c", "s")
    docs = client.search_files("tok", "https://inst.my.salesforce.com", "q")

    assert docs[0]["name"] == "doc.docx"
    assert docs[0]["snippet"] == ""


def test_download_version_text_extracts(mocker) -> None:
    """download_version_text fetches VersionData bytes and extracts text."""
    resp = MagicMock()
    resp.status_code = 200
    resp.content = b"plain body text"
    get = mocker.patch("app.salesforce_client.requests.get", return_value=resp)

    client = SalesforceClient("org.my.salesforce.com", "c", "s")
    text = client.download_version_text(
        "tok", "https://inst.my.salesforce.com", "068A", "notes.txt"
    )

    assert text == "plain body text"
    url = get.call_args[0][0]
    assert url.endswith("/services/data/v62.0/sobjects/ContentVersion/068A/VersionData")


def test_search_files_raises_includes_body(mocker) -> None:
    """A >=400 search response raises HTTPError carrying the Salesforce error body."""
    resp = MagicMock()
    resp.status_code = 400
    resp.url = "https://inst/services/data/v62.0/search"
    resp.text = '[{"message":"MALFORMED_SEARCH"}]'
    mocker.patch("app.salesforce_client.requests.get", return_value=resp)

    client = SalesforceClient("org.my.salesforce.com", "c", "s")
    with pytest.raises(requests.HTTPError) as exc:
        client.search_files("tok", "https://inst", "q")
    assert "MALFORMED_SEARCH" in str(exc.value)


# --- Helpers -------------------------------------------------------------------


def test_build_sosl_targets_latest_content_versions() -> None:
    sosl = _build_sosl("async timeout")
    assert sosl.startswith(
        "FIND {async timeout} IN ALL FIELDS RETURNING ContentVersion("
    )
    assert "IsLatest = true" in sosl
    assert "ContentDocumentId" in sosl


def test_escape_sosl_escapes_reserved_chars() -> None:
    assert _escape_sosl("a+b (c)") == r"a\+b \(c\)"


def test_file_name_appends_extension() -> None:
    assert _file_name("adr-014", "docx") == "adr-014.docx"
    assert _file_name("notes.txt", "txt") == "notes.txt"
    assert _file_name("", "") == "document"


def test_extract_text_txt_md_and_unknown() -> None:
    assert _extract_text("notes.txt", b"hello world") == "hello world"
    assert _extract_text("readme.md", b"# Title") == "# Title"
    assert _extract_text("image.png", b"\x89PNG") == ""


def test_extract_text_docx_roundtrip() -> None:
    """A real .docx round-trips through python-docx extraction."""
    doc = Document()
    doc.add_paragraph("mTLS between services is mandatory")
    buf = io.BytesIO()
    doc.save(buf)
    text = _extract_text("adr.docx", buf.getvalue())
    assert "mTLS between services is mandatory" in text


def test_build_excerpt_windows_around_match() -> None:
    text = ("a " * 2000) + "NEEDLE marker here " + ("b " * 2000)
    excerpt = _build_excerpt(text, "NEEDLE", max_chars=200)
    assert "NEEDLE" in excerpt
    assert excerpt.startswith("…") and excerpt.endswith("…")
    assert len(excerpt) <= 202


def test_build_excerpt_leading_when_no_match() -> None:
    text = "alpha beta gamma delta " * 100
    excerpt = _build_excerpt(text, "zzz-not-present", max_chars=50)
    assert excerpt.startswith("alpha beta")
    assert excerpt.endswith("…")


def test_build_excerpt_short_text_returned_whole() -> None:
    assert _build_excerpt("tiny doc body", "doc") == "tiny doc body"
