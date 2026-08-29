# HMS authority model

## Purpose

HMS Skills Codex separates **what is authorized** from **how an agent prefers to work**. Process convenience must never become authority.

## Precedence

```text
OWNER INSTRUCTION
      ↓
LATEST VALID HMS CHECKPOINT / FROZEN AUTHORITY
      ↓
HMS FAIL-CLOSED + SAFETY RULES
      ↓
HMS ADAPTIVE MODEL ROUTING
      ↓
HMS PROJECT-SPECIFIC SKILLS
      ↓
UPSTREAM SUPERPOWERS
      ↓
CODEX DEFAULTS
```

When two sources conflict, the higher layer wins. At the same layer, use the newest valid authority that actually supersedes the older one; do not assume a newer filename automatically supersedes an older checkpoint.

## Authority is evidence-bearing

A durable authority should identify enough of the following to make continuation deterministic:

- project/repository identity;
- branch, commit, tree, artifact hash, or other relevant immutable identity;
- explicit verdict;
- completed scope;
- unresolved blockers;
- allowed next action;
- integration/push/UAC state when relevant;
- required verification or review gates.

## Fail-closed states

`UNKNOWN`, `UNVERIFIED`, `PARTIAL`, `TIMEOUT`, `CANCELED`, `INCONCLUSIVE`, `BLOCKED`, `STOP`, `DEFERRED`, and `REJECTED` are not synonyms for PASS.

A skill may refine the reason for one of these states but must not promote it to PASS without fresh evidence satisfying the required gate.

## Superpowers adaptation

Use upstream Superpowers where it improves execution discipline. HMS may adapt it as follows:

- Skip redundant brainstorming when a frozen/approved HMS specification already resolves the design question.
- Use TDD directly for deterministic production logic.
- For OS/kernel/UAC/service/native-I/O/hardware-dependent behavior, use the strongest appropriate deterministic harness plus real runtime evidence rather than artificial unit tests.
- Keep upstream worktree, systematic-debugging, code-review, and verification disciplines unless a higher HMS authority requires a stricter process.

## Mutation rule

Before a material mutation, identify:

1. current authority;
2. exact permitted scope;
3. current Git/runtime identity;
4. required verification;
5. required review/release gate.

If any mandatory prerequisite is unknown, stop at the appropriate HMS gate instead of improvising.
