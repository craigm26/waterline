# Application answers (paste-ready)

## Two-sentence pitch

**Waterline:** NOAA puts the odds at about 70% that this winter's El Niño will be the strongest since 1950, so I'm building a fleet of Gemini 4 Argon managed agents that turns Google WeatherNext forecasts, tide data and lidar terrain into flood depths for each city block. You see the result through your phone's camera as a water line on your actual street. Argon writes the flood model for each neighborhood, and the agents monitor every California watershed around the clock, flagging where forecasts disagree, so emergency managers and residents can see what the next atmospheric river will do to their block before it arrives.

**Short version (tight character limits):**
A record El Niño is coming, and forecasts still stop at the county line. Waterline uses Gemini 4 Argon managed agents and Google WeatherNext to put the predicted flood line on your own street, live through your phone's camera.

---

## "What would you build to show how the agents turn a forecast into a block-level flood depth?"

I'd build a split-screen "trace view" with one city block, 17th & Folsom in the Mission, as the example. The left side shows the agents' hand-offs live, and the right side shows a 3D model of the block filling with water as each agent adds its piece:

1. A **forecast agent** takes Google WeatherNext ensemble rainfall for that grid cell and converts it into storm intensity and a return period, using NOAA Atlas 14.
2. A **terrain agent** uses 1-meter lidar to outline the area of land that drains into the block and find the low spots where water pools.
3. A **drainage agent** subtracts what the storm-drain network can carry, and marks any pipe data it had to estimate.
4. A **hydraulics agent** runs a fill-and-spill model to produce a water depth for each cell of the block.
5. A **coordinator agent** combines the results across the ensemble into low, likely and worst-case depths, and flags where the forecast inputs disagree.

Every number on screen links back to its source. Official data is drawn solid and estimates are hatched, so judges can see exactly where the depth came from. To show it's grounded, I'd replay a real past storm and compare the predicted depths with documented flooding at the same spot. Then I'd switch to the upcoming El Niño forecast and finish on the phone, where that same depth number becomes the water line on the street.

> Before submitting: confirm which past storm has documented flooding at 17th & Folsom (see `plan/schedule.md`, item P5) and name it in the answer.

---

## "What AI project are you most proud of building?"

**Option A: OpenCastor (recommended for a DeepMind / robotics audience)**

I'm proudest of OpenCastor, an open-source robot stack that began as a Raspberry Pi RC car you could talk to over WhatsApp. It grew into a set of open specs for how AI agents describe, command and safely operate physical robots: RCAN, robot.md and RRF. The part I'm proudest of is the safety work. The question of how to evaluate whether an AI-driven machine is safe to run became a pilot proposal I submitted to the ITU's Focus Group on Embodied AI, and they've invited me to scope it across three of their working groups. It taught me the lesson Waterline is built on: an AI system earns trust by showing where every decision came from and where it's guessing.

**Option B: Bellwether (on-theme for emergency response)**

I'm proudest of Bellwether, an iOS emergency-response app that runs AI on the device and passes alerts over a BLE/Meshtastic mesh, so it keeps working when cell service goes down. It interoperates with the TAK systems that responders already use, and it follows a strict rule that a person, not the model, makes every life-safety decision.

**Check before pasting:**
- Have a one-line explanation ready for each of RCAN, robot.md and RRF.
- Keep "three working groups" only if that's how you'd describe the WG7/8/9 reply.
- Use Option B only if Bellwether is working, not still in design.
