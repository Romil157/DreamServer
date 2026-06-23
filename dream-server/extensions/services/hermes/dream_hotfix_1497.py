"""Startup hotfix for hermes-agent KeyError on missing 'final_response'.

Issue:  https://github.com/Light-Heart-Labs/DreamServer/issues/1497
Image:  nousresearch/hermes-agent:v2026.5.16 (pinned)

run_agent.py line 16042 does ``result["final_response"]`` which throws
``KeyError`` when an agent turn ends without a final-response payload
(empty / thinking-only / tool-terminated output — readily produced by
``/no_think`` under load).  The fix is trivially ``result.get(..., "")``.

This module is imported at interpreter startup via a ``.pth`` file placed
in the venv's ``site-packages/``.  It installs a ``sys.meta_path`` import
hook that fires when ``run_agent`` is first imported by the Hermes
gateway.  At that point it monkey-patches ``Agent.chat`` so the KeyError
is caught and degraded gracefully.  Because the hook lives inside the
same interpreter that runs the gateway, the patch is guaranteed to be
active when chat requests arrive — unlike the previous approach of
running a separate Python process before ``exec``-ing into the gateway.

The patch is idempotent: double-import is a no-op, and if the upstream
image is bumped past the fix the wrapper simply delegates.

Remove this file (and the compose mounts) once the pinned image tag
includes the upstream fix.
"""

from __future__ import annotations

import importlib
import importlib.abc
import importlib.machinery
import logging
import sys

logger = logging.getLogger("dream.hotfix.1497")

# ---------------------------------------------------------------------------
# Core patch logic (same as the original oneshot script)
# ---------------------------------------------------------------------------

def _apply_patch() -> bool:
    """Monkey-patch Agent.chat.  Return True if applied, False if skipped."""
    try:
        run_agent = importlib.import_module("run_agent")
    except ModuleNotFoundError:
        logger.debug("run_agent module not found; skipping hotfix")
        return False

    Agent = getattr(run_agent, "Agent", None)
    if Agent is None:
        logger.debug("run_agent.Agent not found; skipping hotfix")
        return False

    original_chat = getattr(Agent, "chat", None)
    if original_chat is None:
        logger.debug("Agent.chat not found; skipping hotfix")
        return False

    # Guard: don't double-patch if this module is imported twice (idempotent).
    if getattr(original_chat, "_dream_hotfix_1497", False):
        logger.info("hotfix #1497 already applied; skipping")
        return False

    def chat_safe(self, prompt, *args, **kwargs):  # type: ignore[override]
        """Wrapper: degrade gracefully when 'final_response' is missing."""
        try:
            return original_chat(self, prompt, *args, **kwargs)
        except KeyError as exc:
            if "final_response" in str(exc):
                logger.warning(
                    "hotfix #1497: agent turn produced no final_response "
                    "(prompt=%r); returning empty string instead of crashing",
                    prompt[:80] if isinstance(prompt, str) else "<non-str>",
                )
                return ""
            raise  # Re-raise unrelated KeyErrors

    chat_safe._dream_hotfix_1497 = True  # type: ignore[attr-defined]
    Agent.chat = chat_safe  # type: ignore[assignment]
    logger.info(
        "hotfix #1497 applied: Agent.chat now gracefully handles "
        "missing 'final_response'"
    )
    return True


# Also export apply() so the test can call it directly on a fake run_agent.
apply = _apply_patch


# ---------------------------------------------------------------------------
# sys.meta_path import hook — fires when `run_agent` is first imported
# ---------------------------------------------------------------------------

class _HotfixFinder(importlib.abc.MetaPathFinder):
    """One-shot meta-path finder that patches run_agent on first import."""

    def find_module(self, fullname, path=None):  # type: ignore[override]
        """Called for every import.  We only care about 'run_agent'."""
        if fullname == "run_agent":
            return self  # claim the import so find_module -> load_module fires
        return None

    def load_module(self, fullname):  # type: ignore[override]
        """Let the real import proceed, then apply the patch."""
        # Remove ourselves FIRST to avoid infinite recursion — the real
        # import of run_agent will re-enter the import machinery.
        if self in sys.meta_path:
            sys.meta_path.remove(self)

        # Perform the real import.
        module = importlib.import_module(fullname)
        # Ensure it's registered in sys.modules (importlib usually does this).
        sys.modules.setdefault(fullname, module)

        # Now apply the patch — run_agent is fully loaded.
        _apply_patch()
        return module


def install_hook() -> None:
    """Register the meta-path hook if not already installed."""
    for finder in sys.meta_path:
        if isinstance(finder, _HotfixFinder):
            return  # already installed
    sys.meta_path.insert(0, _HotfixFinder())
    logger.debug("dream_hotfix_1497: meta-path hook installed")


# ---------------------------------------------------------------------------
# Auto-install when this module is imported (via .pth at interpreter start)
# ---------------------------------------------------------------------------
install_hook()
