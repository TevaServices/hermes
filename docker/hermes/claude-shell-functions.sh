claude_model() {
    # One-line: the model Claude Code is currently running (the Hermes
    # profile's configured model via the LiteLLM gateway).
    local _out
    _out=$(/opt/data/tools/claude-hermes/claude-model-resolve.py 2>/dev/null) || return 1
    local _rest="${_out#*	}"
    printf '%s\n' "${_rest%%	*}"
}

# Exported as CLAUDE_BASH_DYNAMIC_SHELL_FUNCTIONS so the SlashCommand tool
# can echo it; the tab below is literal in the snippet.
HERMES_MODEL_SNIPPET='claude_model() { /opt/data/tools/claude-hermes/claude-model-resolve.py | { IFS="	" read -r _p _m _c; printf "%s\n" "$_m"; }; }'