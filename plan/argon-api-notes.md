# Gemini 4 Argon: API notes for Waterline

Source: [Gemini 4 Argon Developer Guide](https://aistudio.google.com/learn/gemini-4-argon-developer-guide), Google AI Studio, published Oct 13, 2026. Read Oct 20.

## Facts that matter for us

| Item | Value |
|---|---|
| Model ID | `gemini-4-argon` |
| Access | Paid tier of the Gemini API (AI Studio), or Google AI Ultra (AI Studio + Antigravity) |
| Pricing | Intro through **Nov 30**: $2 in / $10 out per 1M tokens, 95% off cached input. From Dec 1: $4 / $20 |
| Context | Unified **1M tokens** shared by input, thinking and output |
| Default output cap | 65,536 tokens. To go past it: `background=True` + `max_output_tokens` > 65536, then poll `client.interactions.get(id=...)` |
| Reasoning | `thinking_level`: `"low"` / `"medium"` (default) / `"high"`. `thinking_budget` is deprecated |
| Sampling | `temperature`, `top_p`, `top_k` are **ignored** (deprecation warning) |
| Caching | Implicit only; remove explicit `cached_content` |
| Timeouts | Hard prompts can take **several minutes**: use `background=True` or a 15–20 min HTTP timeout |
| Inputs | Images, audio, video, code, text. "Agentic video understanding" scrubs and inspects frames |
| API | **Interactions API**: `client.interactions.create(...)`, SDK `google-genai` |
| Subagents | The guide's recommended pattern: Argon orchestrates, Gemini 3.8 Flash subagents (`model: flash`) execute |

## Managed Agents (the $5K prize)

```python
from google import genai
client = genai.Client()

interaction = client.interactions.create(
    agent="antigravity-preview-09-2026",
    agent_config={"type": "antigravity", "model": "gemini-4-argon"},
    input="...",
    environment="remote",   # hosted sandbox
)
print(interaction.output_text)
```

The guide says a managed agent gets a **hosted sandbox plus the Antigravity harness**: web search, code writing and execution, self-verification, and **MCP tool calls** in a single API call.

**What the guide does NOT say:** whether a managed agent persists or runs continuously, whether it can be scheduled, or how state carries between calls. So:
- Don't claim agents that "never stop running." Say each watershed agent **re-runs every forecast cycle**, and drive that from our own scheduler. Ask the DeepMind team on the day whether persistent agents exist.
- Carry state between runs ourselves (a JSON situation-report file the next run reads), unless the docs show a native mechanism.

## How this changes Waterline

1. **Expose our data as an MCP server.** Managed agents call MCP tools natively. Write a small MCP server with `get_forecast`, `get_dem_tile`, `get_tide`, `get_atlas14`, `get_sewer_capacity` and `write_depth_grid`. Every tool returns the `provenance` field. This makes the provenance story visible inside the agent trace, and it's the cleanest "best use of Managed Agents" angle.
2. **Coordinator = Argon, workers = Flash.** This matches Google's own recommended pattern: Argon (`thinking_level="high"`) as coordinator/reviewer, with Flash subagents for terrain, drainage and per-scenario hydraulics runs.
3. **The replay storm becomes Argon's verification harness.** The guide's #2 tip is to give the model a pass/fail target. Ours: "Predicted depth > 0 at every documented flood location for the replay storm, and ≈ 0 at the documented dry control points." Argon iterates on the hydraulics module until the check passes. **This is a pitch line:** "We didn't tell Argon how to model the flood. We gave it a real storm and what actually flooded, and it iterated until its model agreed with reality."
4. **Long decode for the "one run" claim.** Generate the hydraulics module plus trace view with `background=True`, `max_output_tokens` around 262144, `thinking_level="high"`. Log the token and line counts for the pitch.
5. **Optional: video as ground truth.** Feed news or social video of the replay storm to Argon's video understanding to estimate observed water depth against curb height. Use it only as qualitative evidence, and hatch it.
6. **Latency.** Several-minute agent runs mean the live demo must play **cached** runs. Kick off one live run at the start of the pitch and show its result at the end if it finishes.

## Day-of setup checklist

- [ ] `pip install -U google-genai`; confirm `client.interactions` exists in the installed version
- [ ] API key from the paid tier (or event-provided credits); test one `gemini-4-argon` call and one managed-agent call **before** Oct 25
- [ ] Confirm the agent name `antigravity-preview-09-2026` is still current (it's a preview and may roll)
- [ ] Set the HTTP timeout to 20 min everywhere
