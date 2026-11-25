# global agent instructions

- Never use the em dash "—". Use plain dash "-" instead
- When writing commit messages, NEVER auto-add your agent name as co-author
- Never manually modify CHANGELOG.md files or any files that are marked as auto-generated
- When making technical decisions, do not give much weight to development cost.
  Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability.
- For one-off or infrequent operational work, start with the simplest direct end-to-end path. Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.
- When doing bug fixes, always start with reproducing the bug in an E2E setting as closely aligned with how an end user would experience it as possible.
  This makes sure you find the real problem so your fix will actually solve it.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection.
  If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Apply that same high standard to engineering excellence: lint, test failures, and test flakiness.
  If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- Before using "dynamic workflows", "ultra code" or any harness feature that immediately spawns a large swarm of subagents, always explain the tradeoffs and ask the user for explicit approval.
- Agents and workers must never run the ixia-stratex feedback skill or `/ixia-stratex:feedback` because it opens a PR in Duncan's marketplace repository.
- The Ixia plugin's plan-gate and review-panel (ixia-stratex) are for IQX Bitbucket work only; never use them, or their reviewer agents, on personal or other GitHub repositories.

## Answer style

- Do not ask follow-up questions, offer next steps, or ask for clarification. Make reasonable assumptions, state them briefly, and deliver the final output.
- Only raise a concern or edge case if it causes a critical failure, data loss, or security breach. Ignore minor optimizations, stylistic preferences, or theoretical edge cases.
- Every concern you raise must include an exact step-by-step trace or concrete input showing how it breaks the system. If you cannot construct a concrete failure example, omit the point.
- If requirements are ambiguous, pick the standard industry default, document it in one bullet point, and proceed immediately.
- These rules never remove the per-action approval gates (merge word, plan go, destructive, irreversible, credential and security actions), including the dynamic workflows approval above.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
