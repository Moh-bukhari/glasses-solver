# Claude photo packet to CG50 images

User request: keep the existing iPhone/iloader installation route. Collect a mixture of wide shots, close-ups, duplicates and poor photos, combine their evidence, and export concise student calculations and answers as calculator pictures. Use Claude for now.

Acceptance criteria:

- Photo quality is advisory: saving an imported/captured decodable photo never stops because of blur, distance or incomplete framing. Multiple selected photos import in order. Automatic capture still waits for stability; a manual capture button bypasses framing advice.
- Nothing is sent to the solver until Finish. Drafts and originals survive cancellation/errors. Corrupt files, storage failures, missing API credentials and service failures remain explicit errors, distinct from poor quality.
- Claude inventories all photos together, combines overlapping views, deduplicates question/subparts, and tracks supporting photos. Each question keeps its original label. Unknown data is marked, never invented; unresolved items produce labeled review pages while readable questions finish.
- Claude-only credentials and compact, self-checked calculation/result output. Bounded repair/retry and at most two concurrent solve groups; preserve answer coverage and cancellation.
- Every question/subquestion gets separate CG50-compatible G3P picture(s), readable at native size. Repeat question labels and Page n/m on every picture. Wrap/paginate instead of shrinking or clipping. Export all pictures in one ZIP with filenames mapped to labels; preview the actual pictures on the phone. Keep prior PDF history compatible.
- Validate actual binary format against independent format evidence, layout overflow/numbering, mixed-quality import and pipeline coverage. Run iOS simulator tests/build if a macOS runner is accessible. Clearly distinguish fixture, build, paid-API and physical-calculator evidence.

The current Linux workspace cannot run Xcode. Do not claim an installable release without an actual matching successful iOS build.
