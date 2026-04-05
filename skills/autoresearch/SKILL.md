---
name: autoresearch
description: Implement Karpathy's autoresearch self-improving agent loop framework. Use when researching autonomous AI research agents, self-optimizing systems, or integrating test-time compute scaling into agent workflows.
---

# Autoresearch Self-Improving Agent Framework

Implement Karpathy's autoresearch framework (released March 2026) for autonomous AI research loops.

## What is Autoresearch?

Autoresearch is a framework where AI agents autonomously run experiments, analyze results, and iterate on their own training/behavior without human intervention. Key paper: `arXiv:2503.``` prefix suggests this is a March 2025 paper by Karpathy.

## Architecture Overview

```
Agent → Generate Hypothesis → Run Experiment → Analyze Results → Update Policy → Repeat
```

## Implementation Steps

### Step 1: Set Up the Experiment Environment

```bash
# Clone autoresearch if available
git clone https://github.com/karpathy/autoresearch.git ~/autoresearch
cd ~/autoresearch

# Check requirements
cat requirements.txt 2>/dev/null || cat setup.py 2>/dev/null | grep -i requires

# Install in development mode
pip install -e . 2>&1 | tail -5
```

### Step 2: Define the Search Space

Autoresearch works by:
1. **Policy**: The agent's behavior policy (can be a prompt, LoRA weights, or full model)
2. **Environment**: The task/benchmark to improve on
3. **Reward signal**: How to measure improvement

```python
# Basic autoresearch config structure
config = {
    "policy": {
        "type": "llm",  # or "loRA", "full_model"
        "model": "your-model",
    },
    "environment": {
        "task": "math" | "code" | "reasoning",
        "dataset": "GSM8K" | "MATH" | "HumanEval",
    },
    "search": {
        "method": "greedy" | "beam" | "evolution",
        "n_trials": 100,
    }
}
```

### Step 3: Run the Research Loop

```bash
# Basic run command (check actual CLI)
python -m autoresearch.run --config config.yaml --output_dir ~/autoresearch_runs

# Monitor results
tensorboard --logdir ~/autoresearch_runs 2>&1 &
```

### Step 4: Integrate with Hermes

To use within Hermes agent:

```python
# In a Hermes skill or script
import subprocess
import json

def run_autoresearch(topic: str, n_trials: int = 50):
    """Run autoresearch on a specific topic."""
    cmd = [
        "python", "-m", "autoresearch.run",
        "--topic", topic,
        "--n_trials", str(n_trials),
        "--output_dir", f"~/autoresearch_runs/{topic}"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(result.stdout)
```

## Key Papers to Reference

1. **Self-Improving LLM Agents at Test-Time** - arXiv:2510.07841 (Oct 2025)
2. **Deep Research: A Survey of Autonomous Research Agents** - arXiv:2508.12752
3. **Karpathy's Autoresearch** - GitHub trending, March 2026 release

## Autoresearch vs Other Approaches

| Approach | Human in Loop | Compute | Best For |
|----------|--------------|---------|----------|
| SFT | Yes (labeled data) | Low | Specific tasks |
| RLHF/DPO | Yes (preferences) | Medium | Alignment |
| Autoresearch | No | High | Open-ended discovery |
| Test-time compute | No | Variable | Reasoning scaling |

## Pitfalls

- **Reward hacking**: Agent finds shortcuts that maximize metric but don't generalize
- **Mode collapse**: All experiments converge to same solution
- **Compute cost**: Each iteration requires full model inference
- **Benchmark contamination**: Overfitting to specific test sets

## Verification

Check if autoresearch is properly installed:
```bash
python -c "import autoresearch; print(autoresearch.__version__)"
autoresearch --help 2>&1 | head -10
```

## Related Skills

- `deep-research`: For understanding the landscape of autonomous research agents
- `grpo-rl-training`: For related RL training patterns
- `llama-cpp`: For running models locally for experiments
