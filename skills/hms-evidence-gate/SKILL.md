---
name: hms-evidence-gate
description: Use before claiming an HMS fix, checkpoint, test phase, integration, or release is complete or PASS, especially when runtime, identity, provenance, or regression evidence is required.
---

# HMS Evidence Gate

No PASS from confidence alone.

## Fresh evidence

Collect evidence appropriate to the task, such as:

- exact command or harness invoked;
- exit code and relevant output;
- targeted tests;
- broad regression tests when required;
- build/lint/type checks;
- Git status/diff and committed identity;
- artifact hashes;
- runtime receipts/logs;
- provenance or lineage;
- visual verification;
- integration/remote state.

Evidence must be fresh enough and bound tightly enough to prove the candidate being judged. A passing test from an older commit does not prove a newer candidate.

## Invalid substitutes

The following are not evidence by themselves:

- "should work";
- "looks correct";
- static inspection when runtime proof is required;
- self-attestation from an untrusted mutable source;
- a test that does not exercise the claimed branch/contract;
- success output whose producer identity is unbound.

Use upstream `verification-before-completion` when available, then apply this HMS gate as the stricter authority/evidence layer.
