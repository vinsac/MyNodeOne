# Documentation Restructure Task

## User Request

User requested INSTALLATION.md be restructured into **4 clear sections** instead of jumbled content:

1. **Section 1: Control Plane Installation**
2. **Section 2: VPS Edge Node Installation**  
3. **Section 3: Management Laptop Setup**
4. **Section 4: Worker Node Installation**

## Current Status

- ✅ **FIXED (commit 3748723):** Added critical missing SSH key exchange step to VPS section
- ⏳ **IN PROGRESS:** Full 4-section restructure

## Completed

- [x] Add SSH key exchange instructions for VPS
- [x] Make SSH step prominent with ⚠️ CRITICAL warning
- [x] Add verification commands
- [x] Fix immediate documentation gap causing user confusion

## Remaining Work

### Phase 1: Structure Planning
- [ ] Design clean 4-section structure with clear navigation
- [ ] Determine what goes in each section
- [ ] Plan cross-references between sections

### Phase 2: Control Plane Section
- [ ] Extract all control plane content
- [ ] Create standalone "Section 1" with:
  - Prerequisites
  - Download MyNodeOne
  - Installation wizard
  - Passwordless sudo setup
  - Security hardening
  - Verification steps
  - "What's next" links

### Phase 3: VPS Edge Node Section
- [ ] Extract all VPS content
- [ ] Create standalone "Section 2" with:
  - Prerequisites (control plane must be ready)
  - SSH key exchange (already added!)
  - Pre-flight checks
  - Installation wizard
  - DNS setup
  - Certificate management
  - Verification steps

### Phase 4: Management Laptop Section
- [ ] Extract all management workstation content
- [ ] Create standalone "Section 3" with:
  - Prerequisites
  - Tailscale setup
  - SSH key exchange (optional)
  - Installation wizard
  - Kubectl verification
  - Access testing

### Phase 5: Worker Node Section
- [ ] Extract all worker node content
- [ ] Create standalone "Section 4" with:
  - Prerequisites
  - Installation wizard
  - Join token usage
  - Verification steps

### Phase 6: Navigation & Cross-References
- [ ] Add clear table of contents at top
- [ ] Add "Start here" guidance
- [ ] Add "Next steps" at end of each section
- [ ] Ensure all cross-references work

### Phase 7: Testing
- [ ] Test each section's instructions on fresh machines
- [ ] Verify no broken links
- [ ] Confirm all commands are correct
- [ ] Get user feedback

## Design Principles

1. **One section, one node type** - No mixing
2. **Prerequisites at top** - Always clear what's needed first
3. **Step-by-step** - Numbered steps, copy-pasteable commands
4. **Verification at end** - How to confirm it worked
5. **Clear navigation** - Easy to jump between sections
6. **Examples included** - Real IPs, usernames, commands

## Priority

**HIGH** - User confusion indicates this is critical for usability

## Notes

- Current INSTALLATION.md is 927 lines and covers all node types
- Users get confused about what to run where
- SSH key exchange was completely missing for VPS
- Pre-flight check commands were not in docs
- Worker vs Management vs VPS sections were interleaved

## Success Criteria

- [ ] User can follow one section for their node type without jumping around
- [ ] No missing steps (like SSH key exchange)
- [ ] Clear "you are here" indicators
- [ ] Pre-flight checks documented for each node type
- [ ] Copy-pasteable commands with real examples
