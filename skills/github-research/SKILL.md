---
name: github-research
description: Research GitHub repositories, topics, trending projects, issues, discussions, and community activity. Use when user asks about GitHub projects, open-source tools, repo stats, contributor activity, or any task requiring GitHub data.
---

# GitHub Research Skill

Research GitHub repositories, topics, trends, and community activity using the `gh` CLI and web extraction.

## Quick Start

```bash
# Search repositories by topic/keyword
gh search repos "paperclip" --limit 10

# Get repo details
gh repo view NousResearch/hermes-agent

# List repo issues
gh issue list --repo paperclipai/paperclip --state all --limit 20

# Search issues/discussions
gh search issues "multi-agent orchestration" --limit 10

# Get repo README
gh repo view paperclipai/paperclip --json readme --jq '.readme' | head -100

# Trending repos
gh search repos "created:>2026-01-01" --sort stars --limit 20
```

## Research Workflow

1. **Discover repos**: Use `gh search repos` to find relevant projects
2. **Get overview**: `gh repo view` for description, stars, forks, topics
3. **Deep dive**: Clone or extract README, check issues for pain points/features
4. **Community signals**: Recent commits, PR activity, contributor count

## Key gh Commands

| Task | Command |
|------|---------|
| Search repos | `gh search repos "query" --limit 10` |
| Repo details | `gh repo view owner/repo` |
| Issues | `gh issue list --repo owner/repo --state all --limit 20` |
| PRs | `gh pr list --repo owner/repo --state all --limit 10` |
| Releases | `gh release list --repo owner/repo` |
| Topics | `gh repo list owner --topic topic-name` |
| Star history | `gh api repos/owner/repo/stargazers --paginate` |

## Web Extraction (for non-gh tasks)

When `gh` doesn't cover it, use Firecrawl or web search:
```bash
# Extract README directly
web_extract(urls: ["https://github.com/owner/repo"])

# Get GitHub Topics page
web_search(query: "site:github.com paperclip AI orchestration")
```

## Common Patterns

### Competitive Analysis
```
gh search repos "<competitor>" --limit 5
gh repo view <competitor>/<repo> --json description,stars,forks,topics
gh issue list --repo <competitor>/<repo> --state all --limit 10
```

### Project Health Assessment
```
gh api repos/owner/repo --jq '{stars, forks, open_issues, subscribers, updated_at}'
gh api repos/owner/repo/commit_activity --jq '.[-12:]'  # last 12 weeks
gh api repos/owner/repo/contributors --jq 'length'
```

### Finding Similar Projects
```bash
gh search repos "topic:ai-agents orchestration" --sort stars --limit 10
gh search repos "topic:multi-agent" --sort updated --limit 10
```
