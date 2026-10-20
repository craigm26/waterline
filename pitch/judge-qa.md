# Judge Q&A: 10-second answers

**How accurate is it?**
"It's a screening model, not HEC-RAS. We validate against Flood Hub and documented past flooding, and every guessed input is marked as a guess."

**Why agents and not a cron job?**
"The schedule *is* a cron job. What runs on it is judgment: reconciling sources that disagree and deciding when a threshold is worth an alert. Each agent calls our data through an MCP server, and every tool result carries its provenance."

**What does Argon do that last week's models couldn't?**
"It writes the whole per-neighborhood model, including terrain handling, drainage approximation and the scene code, in one long run. Its 1M-token output makes 'generate the model for this block' a single step."

**Why not just use Flood Hub?**
"Flood Hub tells you a flood is coming to the area. We tell you the depth at your front step, and you see it through your camera. We use Flood Hub as a check, not a replacement."

**Who uses this?**
"City emergency managers first, then residents. Next is a parcel-level readiness report: flood insurance usually has a 30-day waiting period, so October is the window to buy."

**What about the storm drains? SF data is hard to get.**
"Right. San Francisco's sewer is mostly combined. Where we don't have pipe data, we estimate capacity from design standards and show those pipes hatched. That's the provenance system doing its job."

**Isn't AR flood imagery risky? People might over-trust it.**
"That's why the water plane only ever comes from the computed depth grid, never a generative model, and why it shows a range. We render a low/likely/worst band, not a single line."

**How does it scale?**
"Each watershed is one agent. The terrain and drainage steps are cached per neighborhood; only the forecast changes daily."

**What did you build today versus before?**
Answer exactly per the event rules. Data staging was prep; code written today is today's.
