# personal-ai-setup

The reproducible blueprint for a personal AI: a Goose hub agent and a herdr-run set of coding agents on the Hetzner brain, set up by a wizard, reached only over Tailscale.

## Language

**Brain**:
The Hetzner VPS that runs everything: the Goose hub and the herdr server. Clients never own state.
_Avoid_: VPS, "the cloud", server (when naming the whole machine)

**Hub**:
Goose running on the brain as the one shared assistant; every chat surface is a client to it.
_Avoid_: brain agent, goose server (the command, not the role)

**Wizard**:
The repo's single front-door script that sets up a machine or the brain by asking questions and driving units. Generated with the `wizard` skill.
_Avoid_: bootstrap (as the front door), installer

**Unit**:
One selectable add-on in `config/units/` with its installer, checks, and README row. The wizard's menu is built from these.
_Avoid_: package, module, component

**herd**:
The set of machines herdr manages; the brain runs the herdr server, clients attach over SSH.
_Avoid_: Herder (the tool is herdr, one word), fleet

**Coding agent**:
A CLI coding assistant running in a herdr pane on the brain (OpenCode, Pi, Claude Code, Codex, Gemini CLI, ...).
_Avoid_: code agent, subagent (a different, OpenCode-internal concept)

**First-class agents**:
The coding agents the wizard installs and wires by default: OpenCode and Pi.
_Avoid_: builtin agents, defaults

**Tailnet-only**:
Every path to the brain goes through Tailscale; zero public inbound ports. A standing constraint, not a feature.
_Avoid_: VPN (too generic)
