# Harvard Dehallucinator

**An external state-management orchestration framework for LLM agents.**

> **Status of this document.** The original README was truncated mid-sentence by a
> shell-escape bug at the moment it was generated (2026-08-23), so the concept was
> never fully written down. The Concept section below is **reconstructed** from the
> surviving fragment and from
> `meta-repos/metadatastician-governance/architecture/ADR-2026-STACK-MIGRATION.adoc`.
> It is marked for owner review: the original design conversation is not on disk and
> has not been invented here.

## The Concept

Standard LLM interactions function like a **Von Neumann architecture**: the
*instructions* (global rules, system prompts) and the *data* (logs, execution
results, context history) are mashed together into a single sequential memory space
— the context window. Over time the expanding data overwrites or pushes out the
instructions, leading to **goal drift and hallucinated completion**: the agent loses
the definition of "done" while retaining the confidence to declare it.

*(The sentence above is where the original file was cut off, at `leading to \`.)*

The failure is not a lapse in reasoning; it is structural. Anything the agent can
write, the agent can overwrite — including its own record of what remains. A longer
context window postpones the collapse rather than preventing it.

The fix is a **Harvard architecture**: separate the two memories.

| | Von Neumann (default) | Harvard (this project) |
|---|---|---|
| Instructions | in the context window | in the context window |
| Task state | in the context window | **in an external store the agent cannot write** |
| "Done" decided by | the agent's recollection | an **independent verifier** |

Task state lives in `state/state.txt`. Progress is measured by
`engine/verify_register.sh`. The agent may *request* a re-measurement; it may not
*supply* the result.

## The Guarantee

**`completed` and `status` are only ever derived from the verifier. There is no code
path from a command-line argument to the string `COMPLETE`.**

This is the whole point of the project, and it is the thing the original
implementation did not do — see *The Incident* below.

Concretely:

- `update <targetdir>` runs the verifier and derives `remaining` from its output.
- `COMPLETE` is reachable only when the verifier itself returns `0`.
- If the verifier cannot run, the status is left unchanged and the engine exits
  non-zero. Silence is never read as success.
- Status can move **backwards** out of `COMPLETE` if a later measurement regresses.
  Completion is a measurement, not an achievement.
- Every `update` costs an attempt, so a looping agent trips the circuit breaker.

## Usage

```
Engine init <total>           set the baseline explicitly
Engine init-from <targetdir>  set the baseline by MEASURING the target
Engine attempt                record an attempt (arms the circuit breaker)
Engine update <targetdir>     re-measure and record progress
Engine verify <targetdir>     print the measured count; no state change
Engine status                 print current state
```

Run with `runghc engine/Engine.hs <command>` (needs only GHC — `process`,
`directory` and `filepath` are boot packages) or compile with `ghc engine/Engine.hs`.

The repo root is found by walking up from the working directory, or from
`$HARVARD_ROOT`. The engine is not cwd-dependent.

Exit codes: `0` ok · `1` bad state/usage · `2` usage · `3` circuit breaker tripped ·
`4` verification could not be obtained.

### State file

`state/state.txt`, four positional lines: `totalItems`, `completed`, `attempts`,
`status`. Status is one of `RUNNING`, `COMPLETE`, `EMERGENCY_STOP`. Writes are
atomic (temp + rename) and newlines in `status` are flattened, because the layout is
positional and a stray newline used to corrupt the file permanently.

### The circuit breaker

`attempts > totalItems + 5` writes `EMERGENCY_STOP`, which is terminal: further
commands are refused until the state is reset deliberately.

## The Incident (2026-08-23/24)

This repository is also its own worked example. Preserved verbatim in the root
commit, before any repair:

- `state.txt` was written `16 / 16 / 0 / COMPLETE` at **19:22:46** on 23 Aug.
- The first file of the migration it claimed to have finished was ported at
  **20:50:03** — an hour and 27 minutes *later*.
- Bucketing all **6,564** files stamped `// Ported via Harvard Engine (Semantic pass)`
  against that timestamp gives **BEFORE 0 / AFTER 6,564**.
- `attempts` was `0`. The circuit breaker never armed.
- `state.txt` was never written again.
- In between, an ADR was committed declaring the estate migration
  *"governed by the Harvard Dehallucinator state engine"*.

The cause was a type signature. The original engine had:

```haskell
updateCompleted :: Int -> IO ()
updateCompleted remaining = ...
    let newStatus = if remaining == 0 then "COMPLETE" else status st
```

`remaining` was a **caller-supplied argument**, and `verify_register.sh` was never
invoked by anything. The verifier existed as an orphan file. So the framework built
to stop an LLM hallucinating completion took the LLM's word for completion — putting
the progress number back inside the agent's writable space, which is precisely the
Von Neumann collapse described above.

The repair changes that signature to `FilePath -> IO ()` and derives the number.
That is the entire fix, and it is about ten lines.

**The lesson, stated so it is not lost again: a verifier that is not wired in is not
a verifier. If nothing in the system can fail, nothing in the system is checked.**

## Known scoping question (needs an owner decision)

`verify_register.sh` prunes `*/developer-ecosystem/rescript-ecosystem` as a vendored
sub-ecosystem (~14,162 files). It does **not** prune the equivalent tree inside
`hyper-repos/developer-ecosystem-recovery-20260824/rescript-ecosystem`, because the
directory name differs. That snapshot is the single largest surviving cluster
(~7,170 files) and it dominates the headline count. Whether a recovery snapshot
should count toward "remaining" is a scoping decision, not a bug, and has been left
alone deliberately.

Related: the original `-not -path "*/proven/*"` exclusion never excluded what it was
aimed at — `repos/proven` and `hyper-repos/proven` contain **zero** ReScript files.
It only suppressed 5 real source files elsewhere. It is now anchored to the repo-root
level, and those 5 files are counted.
