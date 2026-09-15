# Shell functions for interactive Claude Code sessions. Sourced by the
# `claude` wrapper, which exports CLAUDE_HERMES_MODEL / _WINDOW / _CONFIG
# for the session it is starting; the resolver fallback below covers a
# plain shell where the wrapper is not the parent.

claude_model() {
    # One-line: the model Claude Code is currently running (the Hermes
    # profile's configured model via the LiteLLM gateway).
    if [ -n "${CLAUDE_HERMES_MODEL:-}" ]; then
        printf '%s\n' "$CLAUDE_HERMES_MODEL"
        return 0
    fi
    local _out
    _out=$(/opt/data/tools/claude-hermes/claude-model-resolve.py \
        "${CLAUDE_HERMES_CONFIG:-${HERMES_HOME:-/opt/data}/config.yaml}" 2>/dev/null) || return 1
    local _rest="${_out#*	}"
    printf '%s\n' "${_rest%%	*}"
}

claude_window() {
    # One-line: the context window (tokens) this session compacts against.
    # Empty/failed means the model is not declared in config/models.toml,
    # so Claude Code is falling back to its own 200k assumption.
    if [ -n "${CLAUDE_HERMES_WINDOW:-}" ]; then
        printf '%s\n' "$CLAUDE_HERMES_WINDOW"
        return 0
    fi
    local _m
    _m=$(claude_model) || return 1
    /opt/data/tools/claude-hermes/claude-model-resolve.py --window "$_m" \
        "${CLAUDE_HERMES_CONFIG:-${HERMES_HOME:-/opt/data}/config.yaml}" 2>/dev/null
}

# Exported as CLAUDE_BASH_DYNAMIC_SHELL_FUNCTIONS so the SlashCommand tool
# can echo it; the tabs below are literal in the snippet.
HERMES_MODEL_SNIPPET='claude_model() { printf "%s\n" "${CLAUDE_HERMES_MODEL:-$(/opt/data/tools/claude-hermes/claude-model-resolve.py "${CLAUDE_HERMES_CONFIG:-${HERMES_HOME:-/opt/data}/config.yaml}" | cut -f2)}"; }'
