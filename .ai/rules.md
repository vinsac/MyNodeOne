# AI Assistant Rules for MyNodeOne

## No Patch Work Rule

When a user explicitly requests a clean solution or states they don't want patch work:

1. **DO NOT** suggest temporary workarounds (hostPath, init containers, node affinity pins)
2. **DO NOT** leave infrastructure in a partially working state
3. **ALWAYS** pursue root cause fixes through proper reinstallation/reconfiguration
4. **PREFER** full OS-level reinstalls over band-aid fixes for persistent networking/storage issues
5. **EXPLAIN** the trade-offs clearly but respect the user's preference for proper solutions

Examples of patch work to avoid:
- Using hostPath when PVC is the intended architecture
- Pinning pods to specific nodes with nodeAffinity as a "fix"
- Leaving broken CSI drivers in CrashLoopBackOff
- Suggesting "just live with it" approaches

Instead, do:
- Full node reinstallation when networking is broken
- Complete storage reconfiguration when Longhorn is misconfigured
- Clean slate approaches that restore intended architecture
