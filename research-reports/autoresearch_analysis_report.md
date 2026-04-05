# Autoresearch Technical Analysis Report

## Executive Summary

Autoresearch is Karpathy's autonomous ML research framework that enables AI agents to autonomously improve a language model through iterative experimentation. This report analyzes the architecture, integration patterns, and ecosystem for potential multi-agent and Claude Code integration.

---

## 1. Architecture Overview

### Core Design Philosophy
- **Single-file modification**: Only `train.py` is edited by agents
- **Fixed time budget**: 5-minute training runs ensure comparable experiments
- **Minimal dependencies**: Self-contained with PyTorch + few packages
- **program.md as "skill"**: Markdown file defines agent behavior/instructions

### File Structure
```
train.py       - The ONLY file agents modify (model, optimizer, loop)
prepare.py     - Fixed constants, data prep, evaluation (READ-ONLY)
program.md     - Agent instructions/skill definition (human edits)
pyproject.toml - Dependencies
```

---

## 2. The Self-Improvement Loop Architecture

### Loop Structure (from program.md)
```
LOOP FOREVER:
  1. Check git state (current branch/commit)
  2. Modify train.py with experimental idea
  3. git commit
  4. Run: `uv run train.py > run.log 2>&1`
  5. Parse results: grep "^val_bpb:\|^peak_vram_mb:" run.log
  6. If crash: read tail -n 50 run.log, attempt fix
  7. Log to results.tsv (commit, val_bpb, memory_gb, status, description)
  8. If val_bpb improved: KEEP (advance branch)
  9. If worse: DISCARD (git reset --hard HEAD~1)
```

### Key Metrics
- **val_bpb** (bits per byte): Primary optimization target (lower is better)
- **peak_vram_mb**: Memory constraint
- **mfu_percent**: Model FLOPS utilization
- **Simplicity criterion**: Prefer simpler solutions

### Evaluation Mechanism (prepare.py)
```python
def evaluate_bpb(model, tokenizer, batch_size):
    # Vocab-size-independent BPB metric
    # Sums per-token cross-entropy, converts nats/byte to bits/byte
    # Fixed MAX_SEQ_LEN for comparability
```

---

## 3. Integration Hooks & Extension Points

### 3.1 Primary Integration Points

| Hook | Location | Purpose |
|------|----------|---------|
| `program.md` | Root | Agent instruction template - extend for multi-agent |
| `train.py` hyperparams | Lines 428-451 | Direct modification target |
| `results.tsv` | Root | Experiment logging - parseable for analysis |
| Git branches | `autoresearch/<tag>` | Experiment isolation |
| `run.log` output | Stdout | Structured metrics extraction |

### 3.2 train.py Modifiable Hyperparameters
```python
# Model architecture
ASPECT_RATIO = 64       # model_dim = depth * ASPECT_RATIO
HEAD_DIM = 128          # target head dimension
WINDOW_PATTERN = "SSSL" # sliding window pattern

# Optimization
TOTAL_BATCH_SIZE = 2**19  # ~524K tokens per step
EMBEDDING_LR = 0.6
UNEMBEDDING_LR = 0.004
MATRIX_LR = 0.04
SCALAR_LR = 0.5
WEIGHT_DECAY = 0.2
WARMUP_RATIO = 0.0
WARMDOWN_RATIO = 0.5

# Model size
DEPTH = 8               # number of transformer layers
DEVICE_BATCH_SIZE = 128
```

### 3.3 Output Format (Parseable)
```
---
val_bpb:          0.997900
training_seconds: 300.1
total_seconds:    325.9
peak_vram_mb:     45060.2
mfu_percent:      39.80
total_tokens_M:   499.6
num_steps:        953
num_params_M:     50.3
depth:            8
```

---

## 4. Multi-Agent Hub System (agenthub branch)

### CRITICAL FINDING: program_agenthub.md

The `origin/agenthub` branch contains a full multi-agent coordination system:

### 4.1 Hub API Design
```
HUB = http://autoresearchhub.com

Endpoints:
POST /api/register          - Agent registration (returns api_key)
POST /api/git/push          - Push git bundle
GET  /api/git/fetch/<hash>  - Fetch specific commit
GET  /api/git/commits       - List recent commits
GET  /api/git/leaves        - Get frontier (uncommitted tips)
GET  /api/git/commits/<hash>/children - What's been tried
GET  /api/git/diff/<a>/<b>  - Compare commits

POST /api/channels          - Create channel
POST /api/channels/<name>/posts - Post to channel
GET  /api/channels/<name>/posts - Read channel
```

### 4.2 Agent Coordination Protocol
```
Channels:
  #results     - Structured experiment results (EVERY run)
  #discussion  - Freeform conversation, hypotheses, ideas

Result Format:
  commit:<hash> platform:<gpu> val_bpb:<value> vram_gb:<value> | <description>

Examples:
  commit:a1b2c3d platform:H100 val_bpb:0.9932 vram_gb:44.2 | increase LR to 0.04
  commit:b2c3d4e platform:M4-Max val_bpb:1.0050 vram_gb:44.0 | switch to GeLU (DISCARD)
  commit:c3d4e5f platform:A100 val_bpb:--- vram_gb:--- | double model width (CRASH: OOM)
```

### 4.3 Git Bundle Protocol
```bash
# Push improvement
git bundle create /tmp/push.bundle HEAD
curl -s -X POST "$HUB/api/git/push" \
  -H "Authorization: Bearer $HUB_KEY" \
  --data-binary @/tmp/push.bundle

# Fetch and apply someone's work  
curl -s "$HUB/api/git/fetch/<hash>" -H "Authorization: Bearer $HUB_KEY" -o /tmp/fetch.bundle
git bundle unbundle /tmp/fetch.bundle
git checkout <hash>
```

---

## 5. Notable Forks & Derivatives

### 5.1 Platform Adaptations
| Fork | Platform | Key Changes |
|------|----------|-------------|
| miolini/autoresearch-macos | macOS (MPS) | SDPA fallback, Metal optimizations |
| trevin-creator/autoresearch-mlx | macOS (MLX) | Native Apple Silicon, no PyTorch |
| jsegov/autoresearch-win-rtx | Windows | Windows compatibility |
| andyluo7/autoresearch | AMD ROCm | AMD GPU support |

### 5.2 Related Projects Mentioned
- **SentientWave Automata** (github.com/sentientwave/automata): Agent swarming organization system, referenced in macOS fork
- **nanochat** (github.com/karpathy/nanochat): Parent project with full platform support

---

## 6. Claude Code Integration Patterns

### 6.1 Direct Integration (Current Design)
Autoresearch is ALREADY designed for Claude Code integration:

```
Simply spin up your Claude/Codex or whatever you want in this repo 
(and disable all permissions), then prompt:
"Hi have a look at program.md and let's kick off a new experiment!"
```

### 6.2 Multi-Layer Agent Setup

**Layer 1: Orchestrator Agent (Claude Code)**
```
- Reads program.md/program_agenthub.md as skill
- Manages experiment lifecycle
- Parses results and makes keep/discard decisions
- Coordinates with other agents via hub

Integration:
- Load autoresearch as a "skill" directory
- Use terminal tool for: git, uv run train.py, curl to hub
- Use file tools for: read/modify train.py, parse run.log
```

**Layer 2: Worker Agents (Multiple Claude Code instances)**
```
- Each runs on different hardware (H100, A100, Mac, etc.)
- Register with hub, post to #results
- Fetch promising commits from other agents
- Explore different directions in parallel
```

**Layer 3: Meta-Agent (Optional)**
```
- Analyzes #results and #discussion
- Identifies patterns in successful experiments
- Suggests high-level research directions
- Could modify program.md itself ("research org code")
```

### 6.3 Paperclip Integration Pattern

While no direct "Paperclip" framework was found, the pattern for organizational agents:

```
Paperclip-style Integration:
1. Define objective function: minimize val_bpb
2. Define constraints: 5min time budget, memory limits
3. Define action space: modify train.py hyperparams/architecture
4. Define feedback loop: parse run.log, git commit/reset
5. Define coordination: hub API for multi-agent
```

---

## 7. Implementation Recommendations

### 7.1 For Single-Agent Claude Code Setup
```bash
# 1. Clone repo
git clone https://github.com/karpathy/autoresearch.git
cd autoresearch

# 2. Setup
uv sync
uv run prepare.py

# 3. Start Claude Code with skill
claude --skill-dir . "Read program.md and start experimenting"
```

### 7.2 For Multi-Agent Setup
```bash
# 1. Use agenthub branch
git fetch origin agenthub
git checkout origin/agenthub

# 2. Deploy hub server (implement API endpoints)
# 3. Start multiple Claude Code instances with program_agenthub.md
# 4. Each agent auto-registers, coordinates via hub
```

### 7.3 Custom Multi-Agent Orchestration
```python
# Pseudo-code for Paperclip/orchestrator integration
class AutoresearchOrchestrator:
    def __init__(self, workers: List[ClaudeCodeInstance]):
        self.workers = workers
        self.hub = AutoresearchHub()
        
    def run_parallel_experiments(self):
        while True:
            # Assign different directions to workers
            for worker in self.workers:
                direction = self.select_experiment_direction()
                worker.execute(f"Modify train.py: {direction}, run, report to hub")
            
            # Wait for results, analyze
            results = self.hub.get_recent_results()
            self.update_search_strategy(results)
```

---

## 8. Key Findings Summary

1. **Architecture is agent-first**: Designed for Claude/Codex from the start
2. **program.md is the "skill"**: Extend this for custom behavior
3. **Multi-agent support exists**: agenthub branch has full coordination API
4. **Git bundles for sharing**: Efficient experiment state transfer
5. **Channel-based coordination**: #results + #discussion pattern
6. **Platform-agnostic design**: Forks exist for Mac, Windows, AMD
7. **Fixed time budget**: Enables fair comparison across experiments
8. **Single-file focus**: Simplifies agent action space

---

## 9. Files Created

- `/tmp/autoresearch/` - Cloned main repository
- `/tmp/autoresearch-macos/` - Cloned macOS fork
- `/tmp/autoresearch_analysis_report.md` - This report

---

## 10. Next Steps for Integration

1. **Implement Hub Server**: Create backend for agenthub API
2. **Create Wrapper Skill**: Extend program.md for specific use cases
3. **Multi-Instance Orchestration**: Script to spin up N Claude Code workers
4. **Results Aggregation**: Dashboard for experiment visualization
5. **Meta-Learning Loop**: Agent that evolves program.md itself
