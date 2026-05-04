# paperclip-container-skills

Helper scripts mounted into the [Paperclip](https://github.com/paperclipai/paperclip) container at `/skills/scripts/`. Used by agent heartbeat scripts to talk to Paperclip's API, query memory, search the web, and look up library documentation.

## Contents

| Script | Purpose | Required env vars |
|---|---|---|
| `scripts/clip.sh` | Paperclip REST API helper (issues, comments, agents, approvals). Used by agents to interact with their company. | `PAPERCLIP_AGENT_API_KEY`, `CLIP_COMPANY`, `CLIP_AGENT` |
| `scripts/memory-cli` | Graphiti knowledge-graph CLI (`add`, `search-nodes`, `search-facts`). Persistent agent memory across heartbeats. | `GRAPHITI_API_URL` (or defaults) |
| `scripts/search-web.py` | Perplexity + Gemini web search with citations. | `PERPLEXITY_API_KEY`, `SEARCH_API_KEY` |
| `scripts/context7-tool.py` | Context7 library documentation lookup. | `CONTEXT7_API_KEY` |
| `scripts/requirements.txt` | Python deps for the `.py` scripts. |  |

## Install (Dockerfile pattern)

```dockerfile
RUN apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-requests
RUN git clone --depth 1 https://github.com/alankyshum/paperclip-container-skills.git /tmp/skills && \
    cp -r /tmp/skills/scripts /skills/scripts && \
    chmod +x /skills/scripts/clip.sh /skills/scripts/memory-cli && \
    rm -rf /tmp/skills
```

## Install (volume mount, host editing)

If you want to iterate on these scripts without rebuilding the container:

```yaml
# docker-compose.yml
services:
  paperclip:
    volumes:
      - ./paperclip-container-skills/scripts:/skills/scripts:ro
```

## License

MIT
