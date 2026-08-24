"""A Jupyter AI persona backed by the NSF NCAR-hosted model.

This is the stock Claude ACP adapter run against a different endpoint. The
persona exists only so the endpoint gets its own entry in the agent picker,
next to Claude, rather than silently replacing it: the two are separate
choices, and which one a user wants depends on whether they have their own
Anthropic credentials.

The endpoint itself is set in the `qwen-agent-acp` wrapper on PATH, not here.
"""

import shutil

from jupyter_ai_persona_manager import PersonaRequirementsUnmet

# Checked at import. Jupyter AI treats this exception as "this persona is not
# available here" and carries on loading the others, so an image built without
# the wrapper simply shows one fewer agent.
if shutil.which("qwen-agent-acp") is None:
    raise PersonaRequirementsUnmet(
        "This persona requires the `qwen-agent-acp` wrapper, which is installed"
        " by the CIRRUS notebook image. See npm.txt and scripts/qwen-agent-acp."
    )

import os

from jupyter_ai_acp_client.base_acp_persona import BaseAcpPersona
from jupyter_ai_persona_manager import PersonaDefaults


class QwenAcpPersona(BaseAcpPersona):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, executable=["qwen-agent-acp"], **kwargs)

    @property
    def defaults(self) -> PersonaDefaults:
        avatar_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qwen.svg")
        return PersonaDefaults(
            name="Qwen (NCAR)",
            description="A coding agent running on the NSF NCAR-hosted model. No account or API key needed.",
            avatar_path=avatar_path,
            # Unused: the ACP agent supplies its own system prompt.
            system_prompt="unused",
        )

    async def is_authed(self) -> bool:
        # The endpoint does not authenticate, so there is nothing to check and
        # no login flow to send anyone to.
        return True
