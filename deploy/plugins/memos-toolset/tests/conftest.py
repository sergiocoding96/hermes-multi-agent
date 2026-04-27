"""Make the plugin importable as ``memos_toolset`` for tests.

The plugin lives in a directory whose name (``memos-toolset``) contains a
hyphen and so cannot be imported directly. We register it under a synthetic
underscored name so tests can ``import memos_toolset.auto_capture`` etc.
"""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

_PLUGIN_DIR = Path(__file__).resolve().parent.parent
_PKG_NAME = "memos_toolset"


def _ensure_loaded() -> None:
    if _PKG_NAME in sys.modules:
        return

    init_file = _PLUGIN_DIR / "__init__.py"
    spec = importlib.util.spec_from_file_location(
        _PKG_NAME,
        init_file,
        submodule_search_locations=[str(_PLUGIN_DIR)],
    )
    if spec is None or spec.loader is None:  # pragma: no cover
        raise ImportError(f"Cannot load {init_file}")
    module = importlib.util.module_from_spec(spec)
    module.__path__ = [str(_PLUGIN_DIR)]  # type: ignore[attr-defined]
    sys.modules[_PKG_NAME] = module
    spec.loader.exec_module(module)


_ensure_loaded()
