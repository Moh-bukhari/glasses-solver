# AI handoff documentation acceptance contract

- Provide a single authoritative root `AI-HANDOFF.md` on `solver-app`, sufficient for a new AI session without private chat history.
- Explain product intent, current implementation/evidence, capture and voice behavior, batch AI collaboration, completeness checks, storage, configuration, code ownership, build/test/install workflow, troubleshooting, and next priorities.
- Distinguish user goals, code behavior, simulator verification, and physical-device confirmation. Never describe the 1.3.1 crash diagnosis as confirmed by a device crash log.
- Link the guide from README, AGENTS, and a short CLAUDE entry point. Add routing pointers on the default `main` branch so opening the repository leads to the active app branch without merging app code.
- Preserve upstream reference material and make branch selection explicit. Document repeatable commands and actual file paths; do not depend on temporary assistant workspaces or expiring download URLs.
- Verify local links, filenames, commands, versions, limits, and referenced CI evidence. This is a documentation-only change; do not rebuild an unchanged IPA or claim a new device test.
- Publish both branch updates with expected-head checks and verify the remote files. Include a maintenance checklist so subsequent changes keep the guide current.
