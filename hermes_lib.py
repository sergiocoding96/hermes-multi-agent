"""hermes_lib.py — Python library wrapper for calling Hermes agents programmatically.

Instead of subprocess calls to `hermes chat -q "..."`, use:

    from hermes_lib import hermes_chat, hermes_research, hermes_email

    # Simple one-shot
    response = hermes_chat("What's the weather like?")

    # Research with specific profile
    brief = hermes_research("AI agents in real estate 2026")

    # Email marketing with profile
    campaign = hermes_email("Create a cold outreach sequence for SaaS founders")

    # Custom profile + skills
    result = hermes_chat(
        "Analyze this GitHub repo",
        profile="research-agent",
        skills=["github-research", "code-researcher"],
        toolsets=["web", "terminal", "skills"],
    )

Requires: Hermes Agent installed at ~/.hermes/hermes-agent with venv.
"""

import subprocess
import json
import os
import sys
from typing import Optional, List


HERMES_AGENT_DIR = os.path.expanduser("~/.hermes/hermes-agent")
HERMES_PYTHON = os.path.join(HERMES_AGENT_DIR, "venv", "bin", "python3")


def _ensure_hermes():
    """Verify Hermes agent is installed."""
    if not os.path.exists(HERMES_PYTHON):
        raise RuntimeError(
            f"Hermes venv not found at {HERMES_PYTHON}. "
            "Install Hermes first: curl -fsSL https://hermes-agent.nousresearch.com/install | bash"
        )


def hermes_chat(
    query: str,
    profile: Optional[str] = None,
    skills: Optional[List[str]] = None,
    toolsets: Optional[List[str]] = None,
    max_turns: int = 90,
    quiet: bool = True,
) -> str:
    """Send a one-shot query to Hermes and return the response.

    Args:
        query: The prompt/question to send
        profile: Hermes profile to use (research-agent, email-marketing, etc.)
        skills: List of skills to attach (e.g., ["research-coordinator"])
        toolsets: List of toolsets to enable (e.g., ["web", "terminal", "skills"])
        max_turns: Maximum agent turns
        quiet: Suppress Hermes UI output

    Returns:
        The agent's final text response
    """
    _ensure_hermes()

    cmd = ["hermes", "chat", "-q", query]

    if profile:
        cmd = ["hermes", "-p", profile, "chat", "-q", query]

    if skills:
        for skill in skills:
            cmd.extend(["--skill", skill])

    if toolsets:
        cmd.extend(["--toolsets", ",".join(toolsets)])

    env = os.environ.copy()
    env["HERMES_QUIET"] = "1" if quiet else "0"

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=max_turns * 30,  # rough timeout: 30s per turn max
            env=env,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return f"[ERROR] Hermes timed out after {max_turns * 30}s"
    except Exception as e:
        return f"[ERROR] {e}"


def hermes_research(topic: str, depth: str = "standard") -> str:
    """Run a multi-stream research brief on a topic.

    Args:
        topic: Research topic
        depth: "quick", "standard", or "deep"

    Returns:
        Research intelligence brief
    """
    prompt = f"Research the following topic at {depth} depth: {topic}"
    return hermes_chat(
        prompt,
        profile="research-agent",
        skills=["research-coordinator"],
        toolsets=["web", "terminal", "file", "skills"],
    )


def hermes_email(task: str) -> str:
    """Run an email marketing task.

    Args:
        task: Email marketing task description

    Returns:
        Campaign plan / deliverable
    """
    return hermes_chat(
        task,
        profile="email-marketing",
        skills=["email-marketing-plusvibe"],
        toolsets=["web", "terminal", "file", "skills"],
    )


def hermes_api_chat(
    messages: list,
    api_url: str = "http://localhost:8642/v1",
    api_key: str = "hermes-local-api-2026",
    stream: bool = False,
) -> str:
    """Call Hermes via the OpenAI-compatible API server.

    This is the preferred method when the gateway is running.
    Lower overhead than CLI subprocess, supports streaming.

    Args:
        messages: OpenAI-format messages list
        api_url: Hermes API server URL
        api_key: API key (from API_SERVER_KEY in .env)
        stream: Enable streaming

    Returns:
        The assistant's response text
    """
    import requests

    resp = requests.post(
        f"{api_url}/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json={
            "model": "hermes-agent",
            "messages": messages,
            "stream": stream,
        },
        timeout=600,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["choices"][0]["message"]["content"]


# --- Convenience for Paperclip CEO integration ---

def dispatch_to_hermes(
    task: str,
    agent: str = "research-agent",
    skills: Optional[List[str]] = None,
) -> dict:
    """Dispatch a task to a Hermes agent and return structured result.

    Designed for Paperclip CEO → Hermes worker dispatch.

    Args:
        task: Full task description with all context
        agent: Hermes profile name
        skills: Skills to attach

    Returns:
        dict with {success, response, agent, task}
    """
    try:
        response = hermes_chat(
            task,
            profile=agent,
            skills=skills,
            toolsets=["web", "terminal", "file", "skills"],
        )
        return {
            "success": True,
            "response": response,
            "agent": agent,
            "task": task[:200],
        }
    except Exception as e:
        return {
            "success": False,
            "response": str(e),
            "agent": agent,
            "task": task[:200],
        }


if __name__ == "__main__":
    # Quick test
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        print(hermes_chat(query))
    else:
        print("Usage: python hermes_lib.py 'your question here'")
        print("  or:  from hermes_lib import hermes_chat, hermes_research")
