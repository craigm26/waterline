#!/usr/bin/env python3
"""Pre-event smoke test: can this key reach gemini-4-argon and a Managed Agent?

Prep tooling, not submission code. Run once before Oct 25:
    pip install -U google-genai
    set GEMINI_API_KEY=...        (PowerShell: $env:GEMINI_API_KEY="...")
    python scripts/smoke_test_argon.py

Call shapes follow Google's Gemini 4 Argon Developer Guide (Oct 13, 2026).
Expect the managed-agent call to take minutes.
"""
import sys
import time

try:
    from google import genai
except ImportError:
    sys.exit("pip install -U google-genai")

client = genai.Client()
if not hasattr(client, "interactions"):
    sys.exit("This google-genai version has no Interactions API. Upgrade: pip install -U google-genai")

print("[1] gemini-4-argon, thinking_level=low ...")
t = time.time()
r = client.interactions.create(
    model="gemini-4-argon",
    input="Reply with exactly: WATERLINE OK",
    generation_config={"thinking_level": "low"},
)
print(f"    {r.output_text!r}  ({time.time() - t:.1f}s)")

print("[2] Managed Agent (antigravity-preview-09-2026, model gemini-4-argon) ...")
t = time.time()
try:
    a = client.interactions.create(
        agent="antigravity-preview-09-2026",
        agent_config={"type": "antigravity", "model": "gemini-4-argon"},
        input=("Fetch https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations/9414290/"
               "floodlevels.json?units=english and report nws_minor. One line."),
        environment="remote",
    )
    print(f"    {a.output_text!r}  ({time.time() - t:.1f}s)")
except Exception as ex:
    print(f"    FAILED: {ex}\n    -> Check the agent name in the current docs; it's a preview and may roll.")
    sys.exit(1)

print("\nBoth calls OK. Note the managed-agent latency for the demo plan.")
