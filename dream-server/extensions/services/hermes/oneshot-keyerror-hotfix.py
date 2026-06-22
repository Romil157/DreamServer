#!/usr/bin/env python3
"""Startup hotfix for hermes-agent KeyError on missing 'final_response'.

Issue:  https://github.com/Light-Heart-Labs/DreamServer/issues/1497
Image:  nousresearch/hermes-agent:v2026.5.16 (pinned)

run_agent.py line 16042 does ``result["final_response"]`` which throws
``KeyError`` when an agent turn ends without a final-response payload
(empty / thinking-only / tool-terminated output — readily produced by
``/no_think`` under load).  The fix is trivially ``result.get(..., "")``.

This script is bind-mounted into the container and run *before* the
gateway starts (see compose.yaml command).  It monkey-patches the
``chat`` method on the ``Agent`` class so the subscript is replaced by
a ``.get()`` call.  The patch is idempotent: if the upstream image is
bumped past the fix, the wrapper simply delegates.

Remove this file (and the compose mount + command) once the pinned
image tag includes the upstream fix.
"""

from __future__ import annotations

import importlib
import logging
import sys

logger = logging.getLogger("dream.hotfix.1497")


def apply() -> bool:
    """Return True if the patch was applied, False if skipped/unnecessary."""
    try:
        run_agent = importlib.import_module("run_agent")
    except ModuleNotFoundError:
        # Outside the container or import layout changed — nothing to patch.
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

    # Guard: don't double-patch if this script runs twice (idempotent).
    if getattr(original_chat, "_dream_hotfix_1497", False):
        logger.info("hotfix #1497 already applied; skipping")
        return False

    def chat_safe(self, prompt, *args, **kwargs):  # type: ignore[override]
        """Wrapper: degrade gracefully when 'final_response' is missing."""
        # The original chat() does result["final_response"] which throws
        # KeyError when the turn produces no final response. We catch that
        # specific KeyError and return "" — which flows into oneshot.py's
        # existing `or ""` fallback path.
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
    logger.info("hotfix #1497 applied: Agent.chat now gracefully handles missing 'final_response'")
    return True


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # Add the hermes venv to sys.path so run_agent is importable.
    venv_site = "/opt/hermes/.venv/lib/python3.11/site-packages"
    hermes_root = "/opt/hermes"
    for p in (venv_site, hermes_root):
        if p not in sys.path:
            sys.path.insert(0, p)

    applied = apply()
    sys.exit(0)  # Always exit clean — patch failure must not block startup.
