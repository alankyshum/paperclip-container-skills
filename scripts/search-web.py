#!/usr/bin/env python3
"""Unified web search tool — Perplexity Sonar + self-hosted Gemini/Google Search.

Adapted from Claude skill search--web for use inside the Paperclip container.

This version depends ONLY on the Python standard library (urllib) so it runs in
minimal container images that have neither `pip` nor the `requests` package
(see BLD-2335). Behaviour and CLI interface are unchanged from the requests-based
version, so AGENTS-*.md commands such as `search-web.py search "..."` keep working.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

# --- Perplexity config ---
PERPLEXITY_API_URL = "https://api.perplexity.ai/chat/completions"
PERPLEXITY_DEFAULT_KEY = os.environ.get("PERPLEXITY_API_KEY", "")
PERPLEXITY_MODELS = {
    "ask": "sonar",
    "search": "sonar",
    "research": "sonar-deep-research",
    "reason": "sonar-reasoning-pro",
}

# --- Gemini Search API config ---
GEMINI_DEFAULT_URL = os.environ.get("SEARCH_API_URL", "https://search.persoack.org/search")
GEMINI_DEFAULT_KEY = os.environ.get("SEARCH_API_KEY", "")
GEMINI_QUICK_PROMPT = (
    "You are a concise research assistant. "
    "Answer the question directly with specific facts and dates. "
    "Keep your response under 300 words."
)


def strip_thinking(text):
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def _error(msg, hint=""):
    print(json.dumps({"error": msg, "hint": hint}))
    sys.exit(1)


def _post_json(url, payload, headers, timeout):
    """POST JSON via stdlib urllib. Returns (status_code, parsed_json_or_text).

    Never raises for HTTP errors; the caller inspects the status code. Network
    level failures (timeout, DNS, connection refused) raise urllib.error.URLError
    or socket.timeout, which callers translate into structured errors.
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
            status = resp.getcode()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace") if e.fp else ""
        status = e.code
    try:
        return status, json.loads(body)
    except (ValueError, json.JSONDecodeError):
        return status, body


def call_perplexity(model, query, timeout=120):
    api_key = PERPLEXITY_DEFAULT_KEY
    if not api_key:
        return _error("PERPLEXITY_API_KEY not set", "Set PERPLEXITY_API_KEY environment variable")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    payload = {"model": model, "messages": [{"role": "user", "content": query}]}

    try:
        status, data = _post_json(PERPLEXITY_API_URL, payload, headers, timeout)
    except TimeoutError:
        return _error("Request timed out", f"Perplexity did not respond within {timeout}s.")
    except urllib.error.URLError as e:
        return _error("Connection failed", str(getattr(e, "reason", e)))

    if status == 401:
        return _error("Authentication failed", "Check PERPLEXITY_API_KEY.")
    if status == 429:
        return _error("Rate limited", "Wait before retrying.")
    if status >= 400:
        detail = data if isinstance(data, str) else json.dumps(data)
        return _error(f"HTTP {status}", detail[:500])

    if not isinstance(data, dict):
        return _error("Unexpected response", str(data)[:500])
    answer = data.get("choices", [{}])[0].get("message", {}).get("content", "")
    citations = data.get("citations", [])
    return answer, citations


def call_gemini(query, system_prompt=None, timeout=90):
    api_key = GEMINI_DEFAULT_KEY
    api_url = GEMINI_DEFAULT_URL
    if not api_key:
        return _error("SEARCH_API_KEY not set", "Set SEARCH_API_KEY environment variable")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    payload = {"query": query}
    if system_prompt:
        payload["system_prompt"] = system_prompt

    try:
        status, data = _post_json(api_url, payload, headers, timeout)
    except TimeoutError:
        return _error("Request timed out", f"Gemini search did not respond within {timeout}s.")
    except urllib.error.URLError as e:
        return _error("Connection failed", str(getattr(e, "reason", e)))

    if status == 401:
        return _error("Authentication failed", "Check SEARCH_API_KEY.")
    if status == 429:
        return _error("Rate limited", "Wait before retrying.")
    if status >= 400:
        detail = data.get("detail", data) if isinstance(data, dict) else data
        return _error(f"HTTP {status}", str(detail)[:500])

    if not isinstance(data, dict):
        return _error("Unexpected response", str(data)[:500])
    return data, None


def cmd_ask(args):
    answer, _ = call_perplexity(PERPLEXITY_MODELS["ask"], args.query)
    print(json.dumps({"answer": answer, "backend": "perplexity/sonar"}, indent=2))


def cmd_search(args):
    answer, citations = call_perplexity(PERPLEXITY_MODELS["search"], args.query)
    result = {"answer": answer, "backend": "perplexity/sonar"}
    if citations:
        result["citations"] = citations
    print(json.dumps(result, indent=2))


def cmd_research(args):
    answer, citations = call_perplexity(PERPLEXITY_MODELS["research"], args.query, timeout=300)
    if args.strip_thinking:
        answer = strip_thinking(answer)
    result = {"answer": answer, "backend": "perplexity/sonar-deep-research"}
    if citations:
        result["citations"] = citations
    print(json.dumps(result, indent=2))


def cmd_reason(args):
    answer, citations = call_perplexity(PERPLEXITY_MODELS["reason"], args.query)
    if args.strip_thinking:
        answer = strip_thinking(answer)
    result = {"answer": answer, "backend": "perplexity/sonar-reasoning-pro"}
    if citations:
        result["citations"] = citations
    print(json.dumps(result, indent=2))


def cmd_deep(args):
    data, _ = call_gemini(args.query, system_prompt=args.system_prompt)
    result = {
        "answer": data.get("answer", ""),
        "backend": f"gemini/{data.get('model', 'unknown')}",
    }
    sources = data.get("sources", [])
    if sources:
        result["sources"] = sources
    print(json.dumps(result, indent=2))


def cmd_quick(args):
    prompt = args.system_prompt or GEMINI_QUICK_PROMPT
    data, _ = call_gemini(args.query, system_prompt=prompt)
    result = {
        "answer": data.get("answer", ""),
        "backend": f"gemini/{data.get('model', 'unknown')}",
    }
    sources = data.get("sources", [])
    if sources:
        result["sources"] = sources
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Unified web search: Perplexity + Gemini")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("ask", help="[Perplexity] Quick factual Q&A")
    p.add_argument("query"); p.set_defaults(func=cmd_ask)

    p = sub.add_parser("search", help="[Perplexity] Web search with citations")
    p.add_argument("query"); p.set_defaults(func=cmd_search)

    p = sub.add_parser("research", help="[Perplexity] Deep multi-source synthesis")
    p.add_argument("query")
    p.add_argument("--strip-thinking", action="store_true", default=False)
    p.set_defaults(func=cmd_research)

    p = sub.add_parser("reason", help="[Perplexity] Tradeoff analysis with verdicts")
    p.add_argument("query")
    p.add_argument("--strip-thinking", action="store_true", default=False)
    p.set_defaults(func=cmd_reason)

    p = sub.add_parser("deep", help="[Gemini] Analytical search with editorial voice")
    p.add_argument("query")
    p.add_argument("--system-prompt", default=None)
    p.set_defaults(func=cmd_deep)

    p = sub.add_parser("quick", help="[Gemini] Quick factual lookup")
    p.add_argument("query")
    p.add_argument("--system-prompt", default=None)
    p.set_defaults(func=cmd_quick)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
