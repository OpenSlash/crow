# Agent Conversation Flow

Crow should feel like an interactive assistant, not only a task runner.

## Default Routing

When a user speaks or types a general request, Crow routes it to the Codex agent by default.

Specialized routes still exist:

- `email` -> mail context / mail executor
- `browser` -> browser executor
- `research` -> research executor
- `code` / `agent` / general -> Codex agent

This makes ordinary input behave like:

```text
User asks Crow
-> Crow sends the request to Codex
-> Codex may inspect, reason, or use tools
-> tool output feeds the agent, not the user's ears
-> Crow records the observable process
-> Crow streams the agent's user-facing answer when TTS is enabled
-> Crow highlights the final conclusion
-> Island can speak the conclusion
```

## Output Priority

Process output is optional from a product perspective. It is useful for trust and debugging, but it should not be the primary user-facing result.

The primary result is the final conclusion:

- shown as the task completion message
- spoken by Island TTS when enabled
- kept readable and concise

Tool output remains secondary. It can appear in the execution console for trust and debugging, but voice output should come from the agent's answer, not raw tool logs.

## Codex Prompt Contract

Crow wraps user input with a short instruction:

- treat the request as agent conversation or task
- use tools only when useful
- keep process output brief
- end with a clear final answer
- avoid file changes unless explicitly requested or approved

This preserves Codex as the executor while making Crow own the assistant experience.
