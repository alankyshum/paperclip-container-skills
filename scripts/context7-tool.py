#!/usr/bin/env python3
"""Context7 documentation fetcher — calls the Context7 MCP server over Streamable HTTP.
Adapted from Claude skill search--docs for use inside Paperclip container."""

import argparse
import json
import os
import sys

import requests

MCP_URL = "https://mcp.context7.com/mcp"
DEFAULT_TIMEOUT = 30


def _parse_sse_result(response):
    result = None
    session_id = response.headers.get("mcp-session-id")
    for line in response.iter_lines(decode_unicode=True):
        if line and line.startswith("data: "):
            try:
                data = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            if "result" in data:
                result = data["result"]
                break
    return result, session_id


def _parse_json_result(response):
    session_id = response.headers.get("mcp-session-id")
    data = response.json()
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and "result" in item:
                return item["result"], session_id
    if isinstance(data, dict):
        return data.get("result"), session_id
    return None, session_id


def initialize_session(api_key=None):
    payload = {
        "jsonrpc": "2.0",
        "id": 0,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "paperclip-context7", "version": "1.0.0"},
        },
    }
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    resp = requests.post(MCP_URL, json=payload, headers=headers, timeout=DEFAULT_TIMEOUT, stream=True)
    resp.raise_for_status()

    content_type = resp.headers.get("content-type", "")
    if "text/event-stream" in content_type:
        _, session_id = _parse_sse_result(resp)
    else:
        _, session_id = _parse_json_result(resp)

    if not session_id:
        return None

    notif = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    notify_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "mcp-session-id": session_id,
    }
    if api_key:
        notify_headers["Authorization"] = f"Bearer {api_key}"
    try:
        requests.post(MCP_URL, json=notif, headers=notify_headers, timeout=10)
    except Exception:
        pass

    return session_id


def call_mcp_tool(tool_name, arguments, session_id=None, api_key=None):
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": arguments},
    }
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["mcp-session-id"] = session_id
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    resp = requests.post(MCP_URL, json=payload, headers=headers, timeout=DEFAULT_TIMEOUT, stream=True)
    resp.raise_for_status()

    content_type = resp.headers.get("content-type", "")
    if "text/event-stream" in content_type:
        return _parse_sse_result(resp)
    else:
        return _parse_json_result(resp)


def _extract_text_from_result(result):
    if result is None:
        return None
    if isinstance(result, dict) and "content" in result:
        parts = []
        for item in result["content"]:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item["text"])
        return "\n".join(parts) if parts else json.dumps(result)
    return json.dumps(result)


def _get_api_key(args):
    if hasattr(args, "api_key") and args.api_key:
        return args.api_key
    return os.environ.get("CONTEXT7_API_KEY")


def cmd_resolve(args):
    api_key = _get_api_key(args)
    try:
        session_id = initialize_session(api_key)
        result, _ = call_mcp_tool(
            "resolve-library-id",
            {"libraryName": args.library_name, "query": args.library_name},
            session_id=session_id,
            api_key=api_key,
        )
        text = _extract_text_from_result(result)
        if text is None:
            print(json.dumps({"error": "No result returned from Context7 MCP server"}))
            sys.exit(1)
        try:
            parsed = json.loads(text)
            print(json.dumps(parsed, indent=2))
        except (json.JSONDecodeError, TypeError):
            print(json.dumps({"result": text}))
    except requests.exceptions.Timeout:
        print(json.dumps({"error": "Request timed out"}))
        sys.exit(1)
    except requests.exceptions.ConnectionError as exc:
        print(json.dumps({"error": "Connection failed", "details": str(exc)}))
        sys.exit(1)
    except requests.exceptions.HTTPError as exc:
        print(json.dumps({"error": f"HTTP {exc.response.status_code}"}))
        sys.exit(1)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)


def cmd_query(args):
    api_key = _get_api_key(args)
    try:
        session_id = initialize_session(api_key)
        result, _ = call_mcp_tool(
            "query-docs",
            {"libraryId": args.library_id, "query": args.query},
            session_id=session_id,
            api_key=api_key,
        )
        text = _extract_text_from_result(result)
        if text is None:
            print(json.dumps({"error": "No result returned from Context7 MCP server"}))
            sys.exit(1)
        try:
            parsed = json.loads(text)
            print(json.dumps(parsed, indent=2))
        except (json.JSONDecodeError, TypeError):
            print(json.dumps({"documentation": text}))
    except requests.exceptions.Timeout:
        print(json.dumps({"error": "Request timed out"}))
        sys.exit(1)
    except requests.exceptions.ConnectionError as exc:
        print(json.dumps({"error": "Connection failed", "details": str(exc)}))
        sys.exit(1)
    except requests.exceptions.HTTPError as exc:
        print(json.dumps({"error": f"HTTP {exc.response.status_code}"}))
        sys.exit(1)
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Fetch library docs via Context7 MCP server.")
    parser.add_argument("--api-key", default=None)

    subparsers = parser.add_subparsers(dest="command", required=True)

    p_resolve = subparsers.add_parser("resolve")
    p_resolve.add_argument("library_name")
    p_resolve.add_argument("--limit", type=int, default=5)
    p_resolve.set_defaults(func=cmd_resolve)

    p_query = subparsers.add_parser("query")
    p_query.add_argument("library_id")
    p_query.add_argument("query")
    p_query.add_argument("--tokens", type=int, default=10000)
    p_query.set_defaults(func=cmd_query)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
