"""Tool schemas — what the LLM sees. Credentials never appear here."""

MEMOS_STORE = {
    "name": "memos_store",
    "description": (
        "Store a memory in your MemOS cube for long-term retrieval. "
        "Use after completing research, generating deliverables, or whenever "
        "information should persist across sessions. Content should be "
        "self-contained and atomic — one finding or deliverable per call."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "content": {
                "type": "string",
                "description": "The content to store. Should be self-contained with context, details, and sources.",
            },
            "mode": {
                "type": "string",
                "enum": ["fine", "fast"],
                "description": "Extraction mode: 'fine' (default) uses LLM to extract structured facts, 'fast' stores raw text.",
            },
            "tags": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Optional tags for categorization (e.g., ['research', 'competitor-analysis']).",
            },
        },
        "required": ["content"],
    },
}

MEMOS_SEARCH = {
    "name": "memos_search",
    "description": (
        "Search your MemOS memory cube for previously stored information. "
        "Returns semantically relevant memories ranked by relevance. "
        "Use to recall past research, deliverables, or context from previous sessions."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Natural language search query.",
            },
            "top_k": {
                "type": "integer",
                "description": "Maximum results to return (default: 10, max: 50).",
            },
        },
        "required": ["query"],
    },
}
