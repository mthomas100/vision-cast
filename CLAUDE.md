# vision-cast — working rules for agents

A visionOS app (SwiftUI + RealityKit, xcodegen) that puts one `m3d` character on the
real table and keeps it alive. Read `README.md` first (files, asset provenance, build
and signing recipe), then `Sources/AliveSystem.swift` (everything per-frame lives there).

## Rules

1. **Never hand-edit the `.xcodeproj`.** `project.yml` is the project; run `xcodegen generate`.
2. **Assets are copies, with provenance.** Anything under `Resources/Characters/` came from
   the m3d pipeline's output folder through `m3d animate --usdz`; say where in `README.md`.
   One USDZ per clip; a clip never drives another file's entity, so swap entities, do not
   share clips.
3. **No AI model loads, no GPU jobs** beyond Xcode and the simulator. `m3d animate` on CPU is fine.
4. **The local-3d pipeline repo is read-only from here.** Pipeline fixes go to that repo's own agent.
5. **The render is the test.** Build for the simulator, launch with `SIMCTL_CHILD_VC_AUTO_PLACE=1
   SIMCTL_CHILD_VC_FALLBACK_Y=1.1`, screenshot (`xcrun simctl io booted screenshot`) and
   look at it; then install on the device with the README recipe.
6. **API names come from the SDK**, not memory: grep the `RealityFoundation` swiftinterface
   in the XROS SDK when something does not compile; two failed builds on one error → stop.
7. **Git, always.** Commit every working increment, subject `vision-cast: …`, body saying what
   was verified, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
   Never commit `.build*/`, `*.xcodeproj/`.
8. **Keep it small.** Look-at + micro-motion + tap-to-wave on a table is the bar; add one
   ingredient at a time and keep `AliveSystem` readable.
