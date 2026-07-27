#!/usr/bin/env python3.12
"""
memos-explorer — direct introspection over the v2 memory plugin DB.

Reads `~/.hermes/memos-plugin/data/memos.db` (read-only by default) and gives
per-agent views the bundled MemOS viewer doesn't expose. Use it to:

  - List every profile with row counts                  → `profiles`
  - Browse a specific agent's traces (private to them)  → `traces <profile>`
  - List skills with originating-profile attribution    → `skills`
  - List policies / world-model entries per profile     → `policies <profile>`, `world <profile>`
  - Run a semantic search using BGE-large embeddings    → `search <query>`
  - Inspect embedding dimension / sparsity stats        → `vec-stats`
  - Show the forensic share_scope_audit log             → `audit [--since 1h]`
  - Project trace vectors to 2D / 3D (UMAP)             → `project --out file.png`
  - Export full memory GRAPH (traces+policies+skills    → `graph-export --out graph.json`
     +world+edges) for the 3D Memory Map viewer

The tool intentionally bypasses the daemon's HTTP layer so it can show rows
across all profiles — which the viewer currently can't, because it's bound
to a single namespace at startup.

For `project` (and `search`) you need a few extra Python packages
(umap-learn, matplotlib, sentence-transformers). Use the tools-venv that
the install script created:

  ~/.hermes/tools-venv/bin/python tools/memos-explorer.py project --out vec-map.png

For everything else, the stdlib + sqlite3 is enough — plain python3.12 works.

Usage examples:

  python3.12 tools/memos-explorer.py profiles
  python3.12 tools/memos-explorer.py traces sergio --limit 20 --search "memory"
  python3.12 tools/memos-explorer.py skills
  ~/.hermes/tools-venv/bin/python tools/memos-explorer.py search "embedder benchmark" --top-k 5
  python3.12 tools/memos-explorer.py vec-stats
  python3.12 tools/memos-explorer.py audit --since 1h
  ~/.hermes/tools-venv/bin/python tools/memos-explorer.py project --out tools/vec-map.png
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import sys
import time
from pathlib import Path

DB = Path.home() / ".hermes/memos-plugin/data/memos.db"
EMBED_MODEL = "BAAI/bge-large-en-v1.5"  # matches the plugin's Xenova/bge-large-en-v1.5
EMBED_DIM = 1024
BGE_QUERY_PREFIX = "Represent this sentence for searching relevant passages: "


def deepseek_key() -> str:
    """Read the DeepSeek API key from the plugin's config.yaml.

    The plugin embeds the LLM key directly in YAML (`llm.apiKey`) — we don't
    re-parse YAML for one field, just substring-grep. Falls back to env var
    DEEPSEEK_API_KEY when the config doesn't have one.
    """
    cfg = Path.home() / ".hermes/memos-plugin/config.yaml"
    if cfg.exists():
        text = cfg.read_text()
        # Find `apiKey: "sk-..."` under the `llm:` block.
        in_llm = False
        for line in text.splitlines():
            stripped = line.lstrip()
            if line and not line.startswith((" ", "\t")):
                in_llm = stripped.startswith("llm:")
                continue
            if in_llm and stripped.startswith("apiKey:"):
                v = stripped.split("apiKey:", 1)[1].strip().strip('"').strip("'")
                if v.startswith("sk-") and not v.startswith("sk-cp-"):
                    return v
    env = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if env:
        return env
    sys.exit("could not find DeepSeek key in ~/.hermes/memos-plugin/config.yaml or DEEPSEEK_API_KEY")


def open_db(readonly: bool = True) -> sqlite3.Connection:
    if not DB.exists():
        sys.exit(f"DB not found: {DB}")
    mode = "ro" if readonly else "rw"
    con = sqlite3.connect(f"file:{DB}?mode={mode}", uri=True)
    con.row_factory = sqlite3.Row
    return con


def fmt_ts(ms: int | None) -> str:
    if ms is None:
        return "?"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ms / 1000))
    except Exception:
        return str(ms)


def trunc(s: str | None, n: int = 80) -> str:
    if s is None:
        return ""
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def bytes_to_vector(blob: bytes | None) -> list[float] | None:
    if blob is None:
        return None
    # Vectors are stored as packed float32 little-endian (matches better-sqlite3 + onnxruntime defaults).
    if len(blob) % 4 != 0:
        return None
    return list(struct.unpack(f"<{len(blob)//4}f", blob))


# ─────────────────────────── commands ───────────────────────────────


def cmd_profiles(args: argparse.Namespace) -> None:
    con = open_db()
    print(f"\n  Profiles in {DB}")
    print(f"  {'-'*68}")
    rows = con.execute("""
        SELECT owner_agent_kind, owner_profile_id,
               (SELECT COUNT(*) FROM traces     WHERE owner_agent_kind=t.owner_agent_kind AND owner_profile_id=t.owner_profile_id) AS traces,
               (SELECT COUNT(*) FROM episodes   WHERE owner_agent_kind=t.owner_agent_kind AND owner_profile_id=t.owner_profile_id) AS episodes,
               (SELECT COUNT(*) FROM policies   WHERE owner_agent_kind=t.owner_agent_kind AND owner_profile_id=t.owner_profile_id) AS policies,
               (SELECT COUNT(*) FROM skills     WHERE owner_agent_kind=t.owner_agent_kind AND owner_profile_id=t.owner_profile_id) AS skills,
               (SELECT COUNT(*) FROM world_model WHERE owner_agent_kind=t.owner_agent_kind AND owner_profile_id=t.owner_profile_id) AS world
        FROM (SELECT DISTINCT owner_agent_kind, owner_profile_id FROM traces
              UNION SELECT DISTINCT owner_agent_kind, owner_profile_id FROM episodes
              UNION SELECT DISTINCT owner_agent_kind, owner_profile_id FROM policies
              UNION SELECT DISTINCT owner_agent_kind, owner_profile_id FROM skills) t
        ORDER BY traces DESC
    """).fetchall()
    print(f"  {'profile':<22} {'kind':<10} {'traces':>7} {'epi':>5} {'pol':>5} {'skill':>6} {'world':>6}")
    for r in rows:
        print(f"  {r['owner_profile_id']:<22} {r['owner_agent_kind']:<10} {r['traces']:>7} {r['episodes']:>5} {r['policies']:>5} {r['skills']:>6} {r['world']:>6}")
    print()


def cmd_traces(args: argparse.Namespace) -> None:
    con = open_db()
    where = ["owner_profile_id = ?"]
    params: list = [args.profile]
    if args.search:
        where.append("(summary LIKE ? OR user_text LIKE ? OR agent_text LIKE ?)")
        like = f"%{args.search}%"
        params.extend([like, like, like])
    if args.scope:
        where.append("share_scope = ?")
        params.append(args.scope)
    sql = f"""
        SELECT id, ts, share_scope, value, alpha,
               COALESCE(summary, '') AS summary,
               COALESCE(user_text, '') AS user_text,
               COALESCE(agent_text, '') AS agent_text
        FROM traces
        WHERE {' AND '.join(where)}
        ORDER BY ts DESC
        LIMIT ?
    """
    params.append(args.limit)
    rows = con.execute(sql, params).fetchall()
    if not rows:
        print(f"  No traces for profile '{args.profile}' matching filters.")
        return
    print(f"\n  Traces for {args.profile} ({len(rows)} shown, scope filter={args.scope or 'any'})")
    print(f"  {'-'*100}")
    for r in rows:
        text = r["summary"] or r["agent_text"] or r["user_text"]
        scope_badge = f"[{r['share_scope']}]" if r['share_scope'] else "[?]"
        print(f"  {fmt_ts(r['ts'])}  V={r['value']:+.2f}  α={r['alpha']:+.2f}  {scope_badge:>10}")
        print(f"    {r['id']}  {trunc(text, 110)}")
    print()


def cmd_skills(args: argparse.Namespace) -> None:
    con = open_db()
    rows = con.execute("""
        SELECT id, owner_profile_id, name, status, eta, support, share_scope, updated_at,
               COALESCE(invocation_guide, '') AS guide
        FROM skills
        ORDER BY updated_at DESC
        LIMIT ?
    """, (args.limit,)).fetchall()
    print(f"\n  Skills (shared across agents — {len(rows)} shown)")
    print(f"  {'-'*100}")
    for r in rows:
        print(f"  [{r['owner_profile_id']:<16}] {r['status']:<10} η={r['eta']:.2f}  sup={r['support']}  [{r['share_scope']}]")
        print(f"    {r['name']}")
        print(f"    {trunc(r['guide'], 110)}")
    print()


def cmd_policies(args: argparse.Namespace) -> None:
    con = open_db()
    rows = con.execute("""
        SELECT id, status, share_scope, gain, support, updated_at,
               COALESCE(title, '') AS title,
               COALESCE(trigger, '') AS trig
        FROM policies
        WHERE owner_profile_id = ?
        ORDER BY updated_at DESC
        LIMIT ?
    """, (args.profile, args.limit)).fetchall()
    if not rows:
        print(f"  No policies for profile '{args.profile}'.")
        return
    print(f"\n  Policies for {args.profile} ({len(rows)} shown)")
    print(f"  {'-'*100}")
    for r in rows:
        print(f"  {r['status']:<10} gain={r['gain']:.2f}  sup={r['support']}  [{r['share_scope']}]")
        print(f"    {trunc(r['title'], 100)}")
        if r['trig']:
            print(f"    trigger: {trunc(r['trig'], 100)}")
    print()


def cmd_world(args: argparse.Namespace) -> None:
    con = open_db()
    rows = con.execute("""
        SELECT id, owner_profile_id, share_scope, updated_at,
               COALESCE(title, '') AS title,
               COALESCE(body, '') AS body
        FROM world_model
        WHERE 1=1
        """ + ("AND owner_profile_id = ?" if args.profile else "") + """
        ORDER BY updated_at DESC
    """, (args.profile,) if args.profile else ()).fetchall()
    print(f"\n  World model entries ({len(rows)} shown — shared across agents)")
    print(f"  {'-'*100}")
    for r in rows:
        print(f"  [{r['owner_profile_id']:<16}] [{r['share_scope']}]  {r['title']}")
        print(f"    {trunc(r['body'], 110)}")
    print()


def cmd_vec_stats(args: argparse.Namespace) -> None:
    import statistics

    con = open_db()
    print(f"\n  Embedding vector stats")
    print(f"  {'-'*68}")
    for table, vec_col in [
        ("traces", "vec_summary"),
        ("traces", "vec_action"),
        ("policies", "vec"),
        ("world_model", "vec"),
        ("skills", "vec"),
    ]:
        rows = con.execute(
            f"SELECT length({vec_col}) AS bytes FROM {table} WHERE {vec_col} IS NOT NULL"
        ).fetchall()
        non_null = len(rows)
        total = con.execute(f"SELECT COUNT(*) AS n FROM {table}").fetchone()["n"]
        if non_null == 0:
            print(f"  {table}.{vec_col:<14}  {non_null:>5}/{total:<5}  (no vectors yet)")
            continue
        byte_sizes = [r["bytes"] for r in rows]
        dim = byte_sizes[0] // 4  # float32
        consistent = all(b == byte_sizes[0] for b in byte_sizes)
        print(f"  {table}.{vec_col:<14}  {non_null:>5}/{total:<5}  dim={dim}  {'(consistent)' if consistent else '(MIXED DIMS!)'}")
    print()


def cmd_search(args: argparse.Namespace) -> None:
    try:
        import numpy as np
        from sentence_transformers import SentenceTransformer
    except ImportError:
        sys.exit("Need sentence-transformers + numpy. Use python3.12 (already has them).")
    con = open_db()
    # Pull all traces with their summary vec (BGE)
    rows = con.execute("""
        SELECT id, owner_profile_id, share_scope, ts,
               COALESCE(summary, '') AS summary,
               vec_summary
        FROM traces
        WHERE vec_summary IS NOT NULL
    """).fetchall()
    if not rows:
        print("  No traces with vec_summary. Backfill may still be running.")
        return
    print(f"  Loading BGE-large to embed query (one-time download if first run) …", file=sys.stderr)
    model = SentenceTransformer(EMBED_MODEL)
    q = np.asarray(
        model.encode([BGE_QUERY_PREFIX + args.query], normalize_embeddings=True),
        dtype=np.float32,
    )[0]
    corpus = []
    for r in rows:
        v = bytes_to_vector(r["vec_summary"])
        if v is None or len(v) != EMBED_DIM:
            continue
        corpus.append((r, np.asarray(v, dtype=np.float32)))
    if not corpus:
        print("  No usable vectors found (dim mismatch?).")
        return
    vecs = np.stack([v for _, v in corpus])
    # vecs are already L2-normalized by the plugin (BGE produces normalized).
    sims = vecs @ q
    order = np.argsort(-sims)[: args.top_k]
    print(f"\n  Top-{args.top_k} for: {args.query!r}")
    print(f"  {'-'*100}")
    for i in order:
        r, _ = corpus[int(i)]
        print(f"  [sim={float(sims[i]):.3f}] [{r['owner_profile_id']:<16}] [{r['share_scope']}]  {fmt_ts(r['ts'])}")
        print(f"    {r['id']}  {trunc(r['summary'], 110)}")
    print()


def cmd_project(args: argparse.Namespace) -> None:
    """2D UMAP projection of trace vectors, coloured by owner_profile_id.

    Writes a PNG (matplotlib) at --out. When --json is given, also writes a
    sidecar JSON with one point per row containing:
      { x, y, id, profile, scope, ts, summary, cluster, crossAgentScore }
    The HTML viewer at tools/umap-viewer.html consumes this JSON.
    """
    try:
        import numpy as np
        import matplotlib
        matplotlib.use("Agg")  # headless
        import matplotlib.pyplot as plt
        import umap
        from sklearn.cluster import HDBSCAN
    except ImportError as e:
        sys.exit(
            f"Missing dep: {e.name}. Run this with ~/.hermes/tools-venv/bin/python "
            "(see module docstring)."
        )

    con = open_db()
    rows = con.execute("""
        SELECT id, owner_profile_id, share_scope, ts,
               COALESCE(summary, '') AS summary,
               vec_summary
        FROM traces
        WHERE vec_summary IS NOT NULL
        ORDER BY ts ASC
    """).fetchall()
    if len(rows) < 10:
        sys.exit(f"  Only {len(rows)} traces with vec_summary — UMAP needs ≥10. Did you backfill?")

    vecs: list[np.ndarray] = []
    meta: list[dict] = []
    bad = 0
    for r in rows:
        v = bytes_to_vector(r["vec_summary"])
        if v is None or len(v) != EMBED_DIM:
            bad += 1
            continue
        vecs.append(np.asarray(v, dtype=np.float32))
        meta.append({
            "id": r["id"],
            "profile": r["owner_profile_id"],
            "scope": r["share_scope"],
            "summary": r["summary"],
            "ts": r["ts"],
        })
    if bad:
        print(f"  Skipped {bad} traces with wrong-dim vectors.", file=sys.stderr)
    X = np.stack(vecs)
    print(f"  Projecting {X.shape[0]} × {X.shape[1]}-dim vectors → 2D via UMAP …", file=sys.stderr)

    n_components = 3 if args.three_d else 2
    reducer = umap.UMAP(
        n_neighbors=min(args.neighbors, len(X) - 1),
        min_dist=args.min_dist,
        n_components=n_components,
        metric="cosine",
        random_state=42,
        verbose=False,
    )
    Y = reducer.fit_transform(X)  # (n, n_components)

    # Per-profile colours.
    profiles = sorted({m["profile"] for m in meta})
    cmap = plt.colormaps.get_cmap("tab10")
    colour = {p: cmap(i / max(1, len(profiles))) for i, p in enumerate(profiles)}

    # In 3D mode we still render a 2D PNG by projecting Y[:, 0:2] — gives a
    # quick preview that the export worked. The interactive viewer reads the
    # JSON for the full 3D scene.
    Y2 = Y[:, :2]
    fig, ax = plt.subplots(figsize=(args.width / 100, args.height / 100), dpi=100)
    fig.patch.set_facecolor("#F4F6FA")
    ax.set_facecolor("#FFFFFF")

    for p in profiles:
        pts = np.array([Y2[i] for i, m in enumerate(meta) if m["profile"] == p])
        if len(pts) == 0:
            continue
        ax.scatter(
            pts[:, 0], pts[:, 1],
            s=28, alpha=0.78, color=colour[p],
            label=f"{p} (n={len(pts)})",
            edgecolors="none",
        )

    ax.set_title(
        f"Trace vector projection · UMAP(n_neighbors={reducer.n_neighbors}, "
        f"min_dist={reducer.min_dist}, metric=cosine) · {X.shape[0]} traces · BGE-large-en-v1.5",
        fontsize=11, color="#0F2042",
    )
    ax.set_xlabel("UMAP-1", fontsize=9, color="#6B7280")
    ax.set_ylabel("UMAP-2", fontsize=9, color="#6B7280")
    ax.tick_params(colors="#6B7280")
    for spine in ax.spines.values():
        spine.set_color("#E1E5EC")
    ax.legend(
        loc="best", framealpha=0.92, fontsize=9, frameon=True,
        edgecolor="#E1E5EC", facecolor="#FFFFFF",
    )
    fig.tight_layout()
    out = Path(args.out)
    fig.savefig(out, dpi=140, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"  wrote: {out.resolve()}  ({len(meta)} points, {len(profiles)} profiles)")

    # JSON sidecar for the interactive viewer.
    if args.json:
        try:
            clusterer = HDBSCAN(min_cluster_size=4, min_samples=2)
            cluster_ids = clusterer.fit_predict(Y).tolist()
        except Exception:
            cluster_ids = [-1] * len(meta)

        # Per-cluster profile diversity: how many distinct profiles, and which?
        cluster_profiles: dict[int, set[str]] = {}
        for cid, m in zip(cluster_ids, meta):
            if cid < 0:
                continue
            cluster_profiles.setdefault(cid, set()).add(m["profile"])
        cluster_summary = {
            int(cid): {
                "profiles": sorted(p),
                "size": cluster_ids.count(cid),
                "crossAgent": len(p) >= 2,
            }
            for cid, p in cluster_profiles.items()
        }

        points = []
        for i, m in enumerate(meta):
            cid = int(cluster_ids[i])
            cinfo = cluster_summary.get(cid)
            pt = {
                "id": m["id"],
                "x": float(Y[i, 0]),
                "y": float(Y[i, 1]),
                "profile": m["profile"],
                "scope": m["scope"],
                "ts": int(m["ts"]) if m["ts"] else 0,
                "summary": m["summary"][:300],
                "cluster": cid,
                "crossAgent": bool(cinfo and cinfo["crossAgent"]),
            }
            if n_components == 3:
                pt["z"] = float(Y[i, 2])
            points.append(pt)
        payload = {
            "model": EMBED_MODEL,
            "dim": EMBED_DIM,
            "umap": {
                "n_neighbors": reducer.n_neighbors,
                "min_dist": reducer.min_dist,
                "n_components": n_components,
            },
            "generated_at_ms": int(time.time() * 1000),
            "profiles": sorted(profiles),
            "clusters": cluster_summary,
            "points": points,
        }
        json_path = Path(args.json)
        json_path.write_text(json.dumps(payload, indent=2))
        cross = sum(1 for p in points if p["crossAgent"])
        print(f"  wrote: {json_path.resolve()}  ({len(points)} points, "
              f"{len(cluster_summary)} clusters, {cross} in cross-agent clusters)")


def label_clusters(
    members: dict[int, list[str]],
    profiles: dict[int, set[str]],
    cross_only: bool = True,
    min_size: int = 4,
) -> dict[int, str]:
    """Return {cluster_id: short_label} for the requested clusters.

    Uses DeepSeek V3 (deepseek-chat) via the plugin's HTTP key. Each call
    sends up to 12 representative member-summary strings and asks for a
    4-6 word topic label. Cluster IDs with no produced label simply absent.
    """
    try:
        import requests as _requests
    except ImportError:
        sys.exit("Missing dep: requests. Use ~/.hermes/tools-venv/bin/python")
    key = deepseek_key()
    targets = []
    for cid, texts in members.items():
        if len(texts) < min_size:
            continue
        if cross_only and len(profiles.get(cid, set())) < 2:
            continue
        targets.append(cid)
    if not targets:
        return {}

    print(f"  labelling {len(targets)} cluster(s) with DeepSeek …", file=sys.stderr)
    labels: dict[int, str] = {}
    SAMPLE = 12  # members per cluster sent to the LLM

    fails = 0
    for i, cid in enumerate(targets):
        texts = members[cid][:SAMPLE]
        joined = "\n".join(f"- {t}" for t in texts)
        prompt = (
            "You are labelling clusters of related memories from a "
            "multi-agent system. Given the snippets below, reply with a "
            "single 4-6 word noun phrase that captures the single topic "
            "they share. No quotes, no explanation, just the phrase.\n\n"
            f"Cluster snippets:\n{joined}\n\nTopic:"
        )
        body = {
            "model": "deepseek-chat",
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.2,
            "max_tokens": 40,
        }
        try:
            r = _requests.post(
                "https://api.deepseek.com/chat/completions",
                headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                json=body,
                timeout=30,
            )
            if r.status_code != 200:
                fails += 1
                if fails <= 3:
                    print(f"    cluster {cid}: HTTP {r.status_code}  {r.text[:200]}",
                          file=sys.stderr)
                continue
            label = r.json()["choices"][0]["message"]["content"].strip()
            # Strip surrounding quotes/punctuation, clamp length.
            label = label.strip("'\"`.,;:").strip()
            if label:
                labels[cid] = label[:80]
                if (i + 1) % 5 == 0:
                    print(f"    {i+1}/{len(targets)} labelled", file=sys.stderr)
        except Exception as e:
            fails += 1
            if fails <= 3:
                print(f"    cluster {cid}: {type(e).__name__}: {e}", file=sys.stderr)
            continue
    print(f"  labelled {len(labels)}/{len(targets)}", file=sys.stderr)
    return labels


def cmd_graph_export(args: argparse.Namespace) -> None:
    """Export the full memory graph as JSON for the 3D Memory Map viewer.

    Includes: traces (L1), policies (L2), skills (L3), world_model (L3) — each
    with its own (x, y, z) UMAP position — plus lineage edges:
      policy → trace      (from policies.source_trace_ids_json)
      skill  → policy     (from skills.source_policies_json)
      skill  → world      (from skills.source_world_json)
      world  → policy     (from world_model.policy_ids_json)

    X,Y are produced by a single joint UMAP over ALL artifacts (so artifacts
    that share semantic content cluster together regardless of kind). Z is
    assigned by kind so the abstraction hierarchy reads vertically:
      traces      z = 0    (raw experience)
      policies    z = 25   (induced patterns)
      world_model z = 45   (environment knowledge)
      skills      z = 55   (validated, callable)

    For artifacts without a stored embedding vector, we embed their text
    representation on the fly using BGE-large (sentence-transformers).
    """
    try:
        import numpy as np
        from sentence_transformers import SentenceTransformer
        import umap
        from sklearn.cluster import HDBSCAN
    except ImportError as e:
        sys.exit(f"Missing dep: {e.name}. Use ~/.hermes/tools-venv/bin/python")

    con = open_db()

    def vec_from_blob(b: bytes | None) -> np.ndarray | None:
        if not b or len(b) % 4 != 0:
            return None
        v = np.frombuffer(b, dtype=np.float32)
        if len(v) != EMBED_DIM:
            return None
        return v

    # Collect rows + text needed for fallback embedding.
    rows: list[dict] = []

    for r in con.execute("""
        SELECT id, owner_profile_id, share_scope, ts, episode_id,
               COALESCE(summary, '') AS text,
               value, priority,
               vec_summary AS v
        FROM traces
    """):
        rows.append({"kind": "trace", "id": r["id"], "profile": r["owner_profile_id"],
                     "scope": r["share_scope"], "ts": r["ts"] or 0,
                     "episode_id": r["episode_id"], "text": r["text"], "v": vec_from_blob(r["v"]),
                     "value": r["value"], "priority": r["priority"],
                     "status": None, "extra": {}})

    for r in con.execute("""
        SELECT id, owner_profile_id, share_scope, updated_at, status,
               title, trigger, procedure, support, gain,
               source_trace_ids_json, source_episodes_json,
               vec AS v
        FROM policies
    """):
        text = f"{r['title']}\n{r['trigger']}\n{r['procedure']}"[:1200]
        rows.append({"kind": "policy", "id": r["id"], "profile": r["owner_profile_id"],
                     "scope": r["share_scope"], "ts": r["updated_at"] or 0,
                     "episode_id": None, "text": text, "v": vec_from_blob(r["v"]),
                     "status": r["status"],
                     "extra": {
                         "name": r["title"],
                         "support": r["support"],
                         "gain": r["gain"],
                         "src_traces": json.loads(r["source_trace_ids_json"] or "[]"),
                         "src_episodes": json.loads(r["source_episodes_json"] or "[]"),
                     }})

    for r in con.execute("""
        SELECT id, owner_profile_id, share_scope, updated_at, status,
               name, invocation_guide, eta, support,
               source_policies_json, source_world_json,
               vec AS v
        FROM skills
    """):
        text = f"{r['name']}\n{r['invocation_guide']}"[:1200]
        rows.append({"kind": "skill", "id": r["id"], "profile": r["owner_profile_id"],
                     "scope": r["share_scope"], "ts": r["updated_at"] or 0,
                     "episode_id": None, "text": text, "v": vec_from_blob(r["v"]),
                     "status": r["status"],
                     "extra": {
                         "name": r["name"],
                         "eta": r["eta"],
                         "support": r["support"],
                         "src_policies": json.loads(r["source_policies_json"] or "[]"),
                         "src_world": json.loads(r["source_world_json"] or "[]"),
                     }})

    for r in con.execute("""
        SELECT id, owner_profile_id, share_scope, updated_at,
               title, body, policy_ids_json, source_episodes_json,
               vec AS v
        FROM world_model
    """):
        text = f"{r['title']}\n{r['body']}"[:1200]
        rows.append({"kind": "world", "id": r["id"], "profile": r["owner_profile_id"],
                     "scope": r["share_scope"], "ts": r["updated_at"] or 0,
                     "episode_id": None, "text": text, "v": vec_from_blob(r["v"]),
                     "status": None,
                     "extra": {
                         "name": r["title"],
                         "src_policies": json.loads(r["policy_ids_json"] or "[]"),
                         "src_episodes": json.loads(r["source_episodes_json"] or "[]"),
                     }})

    if not rows:
        sys.exit("  no rows to project")

    # On-the-fly embedding for rows without a vec.
    need_embed = [(i, r["text"]) for i, r in enumerate(rows) if r["v"] is None]
    if need_embed:
        print(f"  embedding {len(need_embed)} rows missing vecs via BGE-large…", file=sys.stderr)
        model = SentenceTransformer("BAAI/bge-large-en-v1.5")
        texts = [t or "(empty)" for _, t in need_embed]
        vecs = model.encode(texts, normalize_embeddings=True, show_progress_bar=False, batch_size=16)
        for (idx, _), v in zip(need_embed, vecs):
            rows[idx]["v"] = np.asarray(v, dtype=np.float32)

    # Joint UMAP over everything.
    X = np.stack([r["v"] for r in rows])
    print(f"  joint UMAP: {X.shape[0]} artifacts × {X.shape[1]} dims → 2D", file=sys.stderr)
    reducer = umap.UMAP(
        n_neighbors=min(args.neighbors, len(X) - 1),
        min_dist=args.min_dist,
        n_components=2,
        metric="cosine",
        random_state=42,
        verbose=False,
    )
    Y = reducer.fit_transform(X)

    # Z by kind = vertical abstraction hierarchy.
    Z_BY_KIND = {"trace": 0.0, "policy": 25.0, "world": 45.0, "skill": 55.0}

    # Cluster traces only (cross-agent flag is most meaningful for L1).
    trace_idxs = [i for i, r in enumerate(rows) if r["kind"] == "trace"]
    trace_pos = np.stack([Y[i] for i in trace_idxs])
    try:
        cluster_ids = HDBSCAN(min_cluster_size=4, min_samples=2).fit_predict(trace_pos).tolist()
    except Exception:
        cluster_ids = [-1] * len(trace_idxs)
    trace_cluster_lookup = {trace_idxs[k]: int(cluster_ids[k]) for k in range(len(trace_idxs))}
    # Per-cluster profile diversity + centroid + member texts.
    cluster_profiles: dict[int, set[str]] = {}
    cluster_centroids: dict[int, list[float]] = {}
    cluster_members: dict[int, list[str]] = {}
    for i in trace_idxs:
        cid = trace_cluster_lookup[i]
        if cid < 0:
            continue
        cluster_profiles.setdefault(cid, set()).add(rows[i]["profile"])
        cluster_centroids.setdefault(cid, [0.0, 0.0, 0])  # x_sum, y_sum, n
        cluster_centroids[cid][0] += float(Y[i, 0])
        cluster_centroids[cid][1] += float(Y[i, 1])
        cluster_centroids[cid][2] += 1
        cluster_members.setdefault(cid, []).append((rows[i].get("text") or "")[:200])

    # ── LLM cluster labelling ─────────────────────────────────────────
    # For each cluster (cross-agent ones first, then solo if requested), ask
    # DeepSeek for a 4-6 word topic label. Reads DeepSeek key from the
    # plugin's config.yaml. Cheap (~1¢ for 30 clusters) and short. Skipped
    # entirely when --no-labels is set.
    cluster_labels: dict[int, str] = {}
    if not args.no_labels:
        cluster_labels = label_clusters(
            cluster_members,
            cluster_profiles,
            cross_only=not args.label_all,
            min_size=args.label_min_size,
        )

    # Build node list.
    profiles = sorted({r["profile"] for r in rows})
    nodes = []
    for i, r in enumerate(rows):
        cid = trace_cluster_lookup.get(i, -1) if r["kind"] == "trace" else -1
        cross = cid >= 0 and len(cluster_profiles.get(cid, set())) >= 2
        nodes.append({
            "id": r["id"],
            "kind": r["kind"],
            "x": float(Y[i, 0]),
            "y": float(Y[i, 1]),
            "z": Z_BY_KIND.get(r["kind"], 0.0),
            "profile": r["profile"],
            "scope": r["scope"],
            "ts": int(r["ts"]),
            "status": r["status"],
            "text": (r["text"] or "")[:240],
            "extra": r["extra"],
            "value": (round(float(r["value"]), 3) if r.get("value") is not None else None),
            "priority": (round(float(r["priority"]), 3) if r.get("priority") is not None else None),
            "cluster": cid,
            "crossAgent": bool(cross),
        })

    # Build edges. We only keep edges where BOTH endpoints exist in the node set.
    id_to_node = {n["id"]: n for n in nodes}
    edges = []
    for n in nodes:
        if n["kind"] == "policy":
            for tid in n["extra"].get("src_traces", []):
                if tid in id_to_node:
                    edges.append({"from": n["id"], "to": tid, "kind": "policy_trace"})
        elif n["kind"] == "skill":
            for pid in n["extra"].get("src_policies", []):
                if pid in id_to_node:
                    edges.append({"from": n["id"], "to": pid, "kind": "skill_policy"})
            for wid in n["extra"].get("src_world", []):
                if wid in id_to_node:
                    edges.append({"from": n["id"], "to": wid, "kind": "skill_world"})
        elif n["kind"] == "world":
            for pid in n["extra"].get("src_policies", []):
                if pid in id_to_node:
                    edges.append({"from": n["id"], "to": pid, "kind": "world_policy"})

    # Cluster summary blocks (centroids in unprojected UMAP coords —
    # viewer applies its own SCALE/CENTER transform).
    clusters_out = {}
    for cid, (sx, sy, n) in cluster_centroids.items():
        clusters_out[str(cid)] = {
            "id": cid,
            "size": n,
            "profiles": sorted(cluster_profiles.get(cid, set())),
            "crossAgent": len(cluster_profiles.get(cid, set())) >= 2,
            "centroid": [sx / n, sy / n],
            "label": cluster_labels.get(cid),
        }

    payload = {
        "model": EMBED_MODEL,
        "dim": EMBED_DIM,
        "umap": {"n_neighbors": reducer.n_neighbors, "min_dist": reducer.min_dist, "n_components": 2,
                 "z_by_kind": Z_BY_KIND},
        "generated_at_ms": int(time.time() * 1000),
        "profiles": profiles,
        "nodes": nodes,
        "edges": edges,
        "clusters": clusters_out,
        "counts": {
            "trace": sum(1 for n in nodes if n["kind"] == "trace"),
            "policy": sum(1 for n in nodes if n["kind"] == "policy"),
            "skill": sum(1 for n in nodes if n["kind"] == "skill"),
            "world": sum(1 for n in nodes if n["kind"] == "world"),
        },
    }
    out = Path(args.out)
    out.write_text(json.dumps(payload, indent=2))
    print(f"  wrote: {out.resolve()}")
    print(f"    nodes: {len(nodes)}  ({payload['counts']})")
    print(f"    edges: {len(edges)}")
    print(f"    profiles: {profiles}")


def cmd_audit(args: argparse.Namespace) -> None:
    con = open_db()
    # Resolve --since
    now_ms = int(time.time() * 1000)
    since_ms = 0
    if args.since:
        if args.since.endswith("h"):
            since_ms = now_ms - int(args.since[:-1]) * 3600 * 1000
        elif args.since.endswith("m"):
            since_ms = now_ms - int(args.since[:-1]) * 60 * 1000
        elif args.since.endswith("d"):
            since_ms = now_ms - int(args.since[:-1]) * 86400 * 1000
        else:
            since_ms = now_ms - int(args.since) * 1000
    where = ["ts_ms >= ?"]
    params: list = [since_ms]
    if args.non_private_only:
        where.append("COALESCE(new_scope,'') != 'private'")
    sql = f"""
        SELECT ts_ms, table_name, row_id, operation, old_scope, new_scope, owner_profile_id
        FROM share_scope_audit
        WHERE {' AND '.join(where)}
        ORDER BY ts_ms DESC
        LIMIT ?
    """
    params.append(args.limit)
    rows = con.execute(sql, params).fetchall()
    print(f"\n  share_scope_audit ({len(rows)} events, --since {args.since or 'all'})")
    print(f"  {'-'*100}")
    if not rows:
        print("  (no events) — either nothing has changed, or the triggers aren't installed.")
    for r in rows:
        arrow = f"{r['old_scope'] or '∅'} → {r['new_scope'] or '∅'}"
        print(f"  {fmt_ts(r['ts_ms'])}  {r['table_name']:<10}  {r['operation']:<6}  {arrow:<25}  {r['owner_profile_id'] or '?'}")
        print(f"    {r['row_id']}")
    print()


# ─────────────────────────── argparse ───────────────────────────────


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("profiles", help="list profiles with row counts per table")

    t = sub.add_parser("traces", help="list a profile's traces")
    t.add_argument("profile")
    t.add_argument("--limit", type=int, default=20)
    t.add_argument("--search", help="substring search in summary/user/agent text")
    t.add_argument("--scope", help="filter by share_scope ('private', 'local', etc.)")

    s = sub.add_parser("skills", help="list skills (shared across agents)")
    s.add_argument("--limit", type=int, default=30)

    pol = sub.add_parser("policies", help="list a profile's policies")
    pol.add_argument("profile")
    pol.add_argument("--limit", type=int, default=20)

    w = sub.add_parser("world", help="list world-model entries (shared across agents)")
    w.add_argument("--profile", help="filter to one originating profile")

    sub.add_parser("vec-stats", help="show embedding-vector dim/coverage stats")

    sr = sub.add_parser("search", help="semantic search across all traces via BGE-large")
    sr.add_argument("query")
    sr.add_argument("--top-k", type=int, default=10)

    a = sub.add_parser("audit", help="show share_scope_audit log (requires forensic triggers)")
    a.add_argument("--since", default="24h", help="e.g. '15m', '2h', '7d'")
    a.add_argument("--limit", type=int, default=100)
    a.add_argument("--non-private-only", action="store_true", help="only show writes to non-private scope")

    pr = sub.add_parser("project", help="UMAP 2D projection of trace vectors → PNG (+ optional JSON sidecar)")
    pr.add_argument("--out", default="tools/vec-map.png", help="output PNG path")
    pr.add_argument("--json", default=None, help="if set, also write a JSON sidecar consumed by tools/umap-viewer.html")
    pr.add_argument("--neighbors", type=int, default=15, help="UMAP n_neighbors")
    pr.add_argument("--min-dist", type=float, default=0.1, help="UMAP min_dist")
    pr.add_argument("--width", type=int, default=1400, help="output px width")
    pr.add_argument("--height", type=int, default=900, help="output px height")
    pr.add_argument("--3d", dest="three_d", action="store_true",
                    help="project to 3D (n_components=3); JSON adds z to each point")

    gx = sub.add_parser("graph-export",
                        help="Export full memory graph (traces+policies+skills+world+edges) for the 3D Memory Map viewer")
    gx.add_argument("--out", default="tools/memory-graph.json", help="output JSON path")
    gx.add_argument("--neighbors", type=int, default=15)
    gx.add_argument("--min-dist", type=float, default=0.1)
    gx.add_argument("--no-labels", action="store_true",
                    help="skip LLM cluster labelling (faster; useful in CI)")
    gx.add_argument("--label-all", action="store_true",
                    help="also label solo-agent clusters (default: only cross-agent)")
    gx.add_argument("--label-min-size", type=int, default=4,
                    help="minimum cluster size to label (default 4)")

    args = p.parse_args()

    handlers = {
        "profiles": cmd_profiles,
        "traces": cmd_traces,
        "skills": cmd_skills,
        "policies": cmd_policies,
        "world": cmd_world,
        "vec-stats": cmd_vec_stats,
        "search": cmd_search,
        "audit": cmd_audit,
        "project": cmd_project,
        "graph-export": cmd_graph_export,
    }
    handlers[args.cmd](args)


if __name__ == "__main__":
    main()
