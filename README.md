# Sleep Bug Analysis

I bought a gaming laptop XMG Neo 15 (M22) with awesome external liquid cooling, 3080 Ti GPU etc at end of ~2022.

... but almost immediately I hit nasty sleep bug, when sometimes it sleeps, but doesn't wake up; so deep, that the only way to wake it up is to let battery drain (or unscrew case and disconnect it physically).

Support said they haven't seen that, their analysis said laptop is fine and they didn't reproduce the problem, etc.

I disabled sleep as much as I can in windows, yet, it still occasionally get into that state -- and this time it coincides with long 4-days weekend, so I decided to give it a try to do a proper fix myself.

## I have the same laptop, what to do?

Best: wait for the firmware update :)

Next step: you can try to use the same patch that worked for me.

1. Download https://github.com/acidanthera/OpenCorePkg/releases/download/1.0.8/OpenCore-1.0.8-RELEASE.zip
2. Get "EFI" from X64 folder from it
3. Mix into it contents from `xmg_neo_m22/EFI`
4. Follow [skill/Install.md]
5. Good luck!

## I have another laptop/pc with sleep problem

Fire your agent and ask it to follow the [skill/DeepSleepInvestigateSkill.md]. That should be enough to start your engine running.

## What's and where in this repo?

- [xmg_neo_m22/EFI]: the config for OpenCore (tested on v1.0.8) that patches BIOS and chainloads into Windows as usual.
- [xmg_neo_m22/RootCause.md]: raw rootcausing log from the process, maintained by LLM
- [retro/]: multiple angles of retro analysis of the debug session
- [skill/]: folder with generalized analysis skill, aimed at seeding debug session avoiding jump-to-conclusion pitfalls.

## Disclaimers

### License

MIT. Do whatever you want with.

### AI Usage

This README.md is 100% human generated. Rest of stuff there is 99% not :D

All work was done with antigravity using Gemini 3.8 Flash Medium thinking.

I tried mid-run to do couple of reviews from Claude Sonnet 5 Medium and Deepseek 4.0 flash by feeding them RootCause.md with current patch dsl -- but that did not helped...
They agreed with everything and proposed even more overcomplicated steps.


### Personality

Done by me personally without any association with my current employer (NVidia) or XMG or anyone else.

