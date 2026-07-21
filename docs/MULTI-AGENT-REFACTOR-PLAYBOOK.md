# Multi-Agent Refactor Playbook

A portable, **harness-agnostic** field guide for orchestrating many AI coding agents through
large refactors and feature work on an existing codebase. Written to be used from any tool —
Claude Code, Cursor, Windsurf/Cascade, Aider, or a plain CLI agent. The abstract model is what
matters; §10 maps it onto each harness's concrete features.

It is grounded in a real case study: the **Baton** extraction, where Tonebox's music player is
being carved into a standalone macOS app. The extracted code now lives in the Baton repo
(`~/Projects/baton`, `app/Sources/Baton/...`); the wave plan is in
`~/Projects/baton/ORCHESTRATION-PLAN.md`.

---

## 0. Quick-start checklist (TL;DR — the orchestrator's one page)

Print this. Follow it top to bottom for each wave.

```
BEFORE YOU SPAWN ANYTHING
[ ] Write/update a live plan doc (waves, agents, file sets, gates).
[ ] Map the coupling FIRST. grep the call-sites and imports before slicing.
[ ] Classify each track: INDEPENDENT (no shared build) or SHARED-TARGET.
[ ] Slice shared-target work into DISJOINT file sets. Verify disjointness by grep.
[ ] Freeze public APIs for the wave. Siblings depend on them staying stable.
[ ] Pick isolation: same-tree (no concurrent build) | worktree | branch-per-agent.
[ ] Pick model per agent (design vs code vs trickiest-correctness).

SPAWN THE WAVE
[ ] One brief per agent (template in §7): scope, do-not-touch, invariants, change,
    verify commands, required report.
[ ] Independent tracks: fan out freely, now.
[ ] Shared target: fan out only across disjoint files; each agent builds ITS slice.

CLOSE THE WAVE  (serial integration gate — ORCHESTRATOR ONLY, §5)
[ ] Merge slices (worktrees/branches) into the main tree.
[ ] Regenerate the project (e.g. xcodegen) so new files are picked up.
[ ] Build the whole target.
[ ] Run the FULL test suite — not just the changed slice's tests.
[ ] Smoke-test runtime wiring that compiles but can crash (DI/env/config).
[ ] Only when green: tag the wave done in the plan doc; start the next wave.

IF THE GATE FAILS
[ ] Triage: merge conflict | out-of-scope drift | non-compiling slice |
    runtime-only failure | truncated scope. See §9.
[ ] Fix at the gate (usually a small orchestrator commit), re-run the full gate.
```

**The one rule to remember:** *many agents, sequenced into waves; parallel fan-out inside a wave
only where files don't overlap; every wave ends at a serial build-and-test gate you run yourself.*

---

## 1. When to parallelize vs not

There are exactly two kinds of work, and they parallelize differently.

| Kind | Examples | Parallelism | Why |
|---|---|---|---|
| **Independent tracks** | docs, marketing website, app icon, an isolated feature with its own files/tests | **Fan out freely, all at once** | Nothing shares a build. No file overlaps. A failure in one can't break another. |
| **Shared build target** | one Xcode/Gradle/cargo target that must compile + test *together* | **Fan out only on disjoint file sets, then a serial gate** | The target only means anything when it compiles as a whole. Two agents editing files that reference each other can each be internally correct yet fail to build together. |

### The core rule

> **Max agents ≠ max parallelism on one target.** You can run 8 agents against a single build
> target, but only as many *concurrent* ones as you have **non-overlapping, low-coupling slices**.
> Beyond that, adding agents adds merge risk, not speed.

Why parallelism saturates on one target:

- A build target is a single correctness unit. N agents editing it produce N locally-green diffs
  that only matter once combined — combination is serial (build + test), so it's an
  **Amdahl's-law** ceiling: the serial gate caps your speedup.
- Coupling is quadratic. Every pair of agents that touch related code is a potential conflict or
  a broken cross-reference. Disjoint slices drive that pair-count toward zero; overlapping slices
  bring it back.
- Runtime wiring (dependency injection, environment, config) is invisible to any single slice's
  local build. It only surfaces when everything is assembled — again, at the serial gate.

**Baton example.** Wave 0 (website, icon, spec/docs) touches nothing in the Tonebox build, so all
three ran fully parallel with zero coordination. The code extraction is *one* Xcode target, so its
agents fan out only across disjoint directories and every wave ends at `xcodegen + build + full
suite` in the main tree. See `ORCHESTRATION-PLAN.md` → "How we parallelize (the honest rule)".

---

## 2. The wave model

Decompose a big refactor into **waves**. A wave is the atomic unit of orchestration.

> **Wave = a set of agents that can run concurrently + exactly one serial integration gate.**

### Anatomy of a wave

```
WAVE N
├─ Precondition:  main tree is green (previous wave's gate passed)
├─ Coupling map:  which files/modules each agent may touch (disjoint)
├─ Frozen APIs:   public signatures siblings depend on — must not change this wave
├─ Agents (parallel):
│    ├─ Agent N-a  → files {A}   → builds+tests slice A → reports
│    ├─ Agent N-b  → files {B}   → builds+tests slice B → reports
│    └─ Agent N-c  → files {C}   → builds+tests slice C → reports
├─ Merge:         orchestrator combines slices into main tree
└─ GATE (serial): regenerate → build whole → full suite → runtime smoke → green
```

- **Dependencies within a wave** are allowed but discouraged. If N-b needs a symbol from N-a,
  either (a) do them in separate waves, or (b) have N-a land the *public API* first and freeze it,
  and let N-b code against that signature. (Baton W1-lift depends on W1-scaffold, so scaffold is a
  precondition, not a concurrent sibling.)
- **A wave is done only when its gate is green.** Never start wave N+1 on a red or unverified
  wave N.

### Baton's waves (from the plan)

| Wave | Theme | Parallelism |
|---|---|---|
| 0 | Independent tracks: website, icon, spec | Fully parallel (no shared build) |
| 1 | Scaffold + lift player into standalone app | Mostly serial; small disjoint fan-out for decouple |
| 2 | App shell (onboarding, chrome, menu-bar) | Parallel where disjoint |
| 3 | MCP control surface + audio-focus IPC + Tonebox client | Mixed; trickiest correctness |
| 4 | Compete: podcasts, radio, casting, downloads, DSP… | Highly parallel (additive, own files/tests) |
| 5 | Ship: site, appcast/DMG, docs | Serial release |

---

## 3. Disjoint-file decomposition

The whole game on a shared target is slicing work so agents **don't collide**. Three slice axes:

| Axis | Slice by | Good when |
|---|---|---|
| **By directory/module** | `Audio/*` vs `Integrations/Navidrome/*` | Modules are already loosely coupled |
| **By layer** | model vs view vs networking | Change is layer-local; the seam between layers is stable |
| **By feature** | Podcasts vs Radio vs Casting | Additive features that each own new files + tests |

Baton's clean-merged parallel wave used the **directory** axis: one agent on `Audio/*`
(owner-token audio-focus), one on `Integrations/Navidrome/*` (Keychain decouple). No overlap →
two independent merges, no conflict.

### Verify disjointness UP FRONT (grep the coupling first)

Do not trust your mental model of the module boundaries — measure it before spawning.

```bash
# 1. What files will each slice touch? (list them explicitly)
# 2. Does slice A import/reference anything owned by slice B?
grep -rn "NavidromeKeychain\|NavidromeConfig" app/Sources/Baton/Audio/
grep -rn "StreamingPlaybackController"          app/Sources/Baton/Integrations/

# 3. Count shared call-sites of the symbol you're moving — this sizes the blast radius.
grep -rn "appModel.music\b" app/Sources/Baton | wc -l
```

If a grep shows cross-references between two intended slices, they are **not disjoint** — either
merge them into one agent, put them in different waves, or introduce a stable seam first.

### The "keep public APIs stable within a wave" rule

Sibling agents compile against each other's *public surface*. If agent A renames a public method
that agent B calls, B's slice was correct when it started and broken by the time it merges.

> **Within a wave, public API signatures are frozen.** Refactor internals freely; change public
> signatures only in a wave where nobody else depends on them, or in a dedicated seam wave.

**Baton's cleanest example of this rule (Phase 1a, commit `bdeee01d`).** The music stores were
carved into a new `MusicModel` root, but `AppModel` was made to **embed one and forward the 7
members via computed properties**, so all **~367 existing `appModel.music` / `.musicLibrary`
call-sites are byte-for-byte unchanged**. The public surface every other file depends on stayed
identical — behaviour-neutral, full suite green (192). That stable surface is *exactly* what let
later agents fan out without breaking each other.

---

## 4. Isolation strategies

How agents' edits are kept from stepping on each other physically. Pick per wave.

### (a) Same-tree parallel edits on disjoint files

All agents edit the one working tree, each confined to its own file set.

- **Cheap, zero setup.** Works *only if agents don't build concurrently* — concurrent builds in one
  tree collide on derived-data/build dirs and race on generated files.
- Use when slices are truly disjoint and you gate the build centrally (agents edit; orchestrator
  builds). Good for docs, or edits where per-slice compilation isn't required.

### (b) Git worktrees per agent  ← Baton's proven pattern

Each agent gets its own `git worktree` (a separate checkout sharing one `.git`), on its own branch.
Each **builds and tests its own slice in isolation**, then the orchestrator **clean-merges**.

```bash
git worktree add ../wt-audio    -b worktree-agent-audio
git worktree add ../wt-keychain -b worktree-agent-keychain
# agent A works+builds in ../wt-audio, agent B in ../wt-keychain — no shared build dir
# then, in main tree:
git merge worktree-agent-keychain
git merge worktree-agent-audio
git worktree remove ../wt-audio && git worktree remove ../wt-keychain
```

- **Best when slices overlap-in-spirit or each agent must compile/test independently.**
- Baton did exactly this for the two parallel Phase-1 agents. The merges
  (`ace03a00`, `6386c0d3`) were clean because the file sets were disjoint
  (`Integrations/Navidrome/*` vs `Audio/*`).
- **Watch build-dir collisions:** even with separate worktrees, tools that default to a *shared*
  global build/derived-data path (Xcode DerivedData, a shared `target/`, `node_modules` symlinks)
  will race. Give each worktree a **unique build dir** (e.g. `-derivedDataPath ./.dd`,
  `CARGO_TARGET_DIR=./target`, isolated `$TMPDIR`).

### (c) Branch-per-agent (no worktree)

One clone, agents on separate branches, switched serially. Simpler than worktrees but you **can't
run agents truly concurrently** in one checkout without thrashing the tree. Use for sequential
agents or when worktrees aren't available.

### Choosing

| Need | Strategy |
|---|---|
| Disjoint files, orchestrator does all builds | (a) same-tree |
| Each agent must build/test independently, concurrently | (b) worktrees + unique build dirs |
| Sequential agents, or worktrees unsupported | (c) branch-per-agent |

---

## 5. The integration gate

The gate is the serial checkpoint that closes a wave. **It is always run by the orchestrator,
never by an agent** — an agent only sees its own slice; only the orchestrator sees the assembled
whole. This is stated as a guardrail in `ORCHESTRATION-PLAN.md`: "The integration gate (xcodegen +
build + full suite) is run by the orchestrator, not the agents."

### Gate checklist

```
[ ] Merge all slices into the main tree (worktrees/branches).
[ ] REGENERATE the project so new files are wired in.
       e.g. `xcodegen generate`  (XcodeGen auto-discovers new Swift files/resources)
       — skipping this means new files compile in the slice but are absent from the real target.
[ ] BUILD the whole target from clean-ish state.
[ ] Run the FULL test suite — every test, not just the slices' tests. Cross-slice
    interactions and shared fixtures only break here.
[ ] SMOKE-TEST runtime wiring that compiles but can crash:
       - dependency injection / environment objects present at every use site
       - config/secrets/keychain lookups resolve
       - app launches cold, exercises the changed screens
[ ] Green ⇒ mark wave done in the plan doc. Red ⇒ triage (§9), fix, re-run WHOLE gate.
```

### Why the runtime smoke step is non-negotiable

A slice can be perfectly type-correct and still crash the instant it runs, because DI/env wiring is
invisible to a local compile.

**Baton's real catch (commit `3207bda6`).** After Phase 1b repointed the music views to read
`@Environment(MusicModel.self)`, everything **compiled**. But the snapshot tests hosted those views
(`FullScreenNowPlaying`, `NowPlayingBar`, `MusicView`) injecting only `AppModel` — so at *runtime*
the views looked up a `MusicModel` that wasn't in the environment. The integration gate's full-suite
run surfaced it; the fix was to inject `.environment(model.musicModel)` alongside the existing
`AppModel` injection at each host site. **A compile-only gate would have shipped a runtime crash.**

---

## 6. Verification patterns

Landing a change is not the same as trusting it. Layer these on top of the gate.

| Pattern | What it is | When to use |
|---|---|---|
| **Fan-out → adversarial verify** | After a code agent lands a change, a *second, skeptical* agent tries to break it — edge cases, threading, offline, error paths | Default for every non-trivial feature. Baton's stated default. |
| **Judge panel for design forks** | 3 agents produce independent options; a judge scores; you synthesize the winner + graft best ideas | Design decisions with no single right answer: icon, onboarding UX, an MCP tool schema |
| **Loop-until-dry review** | Keep spawning reviewers over the changed code until **two consecutive rounds find nothing new** | Extractions/carve-outs where coupling leaks hide in a long tail |
| **Completeness critic** | An agent whose only job is "what's missing / unverified / untested?" — its findings seed the next wave | At every gate, before declaring the wave done |

Notes:
- The verifier must be a **separate** invocation from the implementer — a fresh, skeptical context,
  not the author grading their own work.
- Make adversarial verifiers *concrete*: "write a failing test that exercises the offline path,"
  not "check if it's robust."
- For the extraction specifically, the loop-until-dry reviewer is hunting for **residual coupling to
  the origin app** (stray `import`, a Tonebox-only type, a shared service id) that compiles fine in
  the monorepo but breaks once the code is standalone.

---

## 7. Agent brief template

Every code agent gets a fill-in-the-blanks brief. Ambiguity here is how agents drift.

```markdown
## Agent brief: <wave>-<short-name>

**Scope — files you MAY edit (exhaustive):**
- path/to/fileA
- path/to/dirB/*

**DO NOT TOUCH (owned by sibling agents / frozen this wave):**
- path/to/other/*
- <any public API listed under Invariants>

**Invariants (must hold when you report):**
- Public API of <X> is FROZEN — do not change signatures other code calls.
- Behaviour-neutral unless the change below says otherwise.
- No new dependency on <origin app>-only types/services.

**The change:**
<one paragraph: what to do and why. Concrete, not aspirational.>

**Verify before reporting (paste exact commands + expected result):**
- Build your slice:  <build cmd>            → compiles clean
- Test your slice:   <test cmd>             → all green (state the count)
- <grep to prove you didn't touch forbidden files / left the API stable>

**Required report (structured — the orchestrator merges from this):**
- Files changed: <list>
- Public APIs others may depend on: <signatures, or "none changed">
- Branch / commit: <name / sha>
- Anything you could NOT do in scope / assumptions made: <list>
```

### Filled example (Baton's Keychain-decouple agent, worktree)

```markdown
## Agent brief: W1-keychain

**Scope — files you MAY edit (exhaustive):**
- app/Sources/Baton/Integrations/Navidrome/NavidromeConfig.swift
- app/Sources/Baton/Integrations/Navidrome/NavidromeKeychain.swift  (new file)

**DO NOT TOUCH:**
- Audio/*  (sibling agent W1-audio-focus owns it this wave)
- AIConfig and its Keychain usage beyond removing the Navidrome coupling

**Invariants:**
- NavidromeConfig's public read/write API stays source-compatible with all call-sites.
- No behaviour change to how the secret is stored for existing installs.

**The change:**
Give NavidromeConfig its own Keychain helper (NavidromeKeychain) so its secret no
longer routes through AIConfig — a required decouple before the player can stand alone.

**Verify:**
- xcodebuild ... -derivedDataPath ./.dd  → compiles clean (own build dir; concurrent-safe)
- swift test / xcodebuild test           → green
- grep -rn "AIConfig" Integrations/Navidrome/  → no residual coupling

**Required report:**
- Files changed: NavidromeConfig.swift (12 lines), NavidromeKeychain.swift (+125, new)
- Public APIs others depend on: NavidromeConfig read/write unchanged
- Branch: worktree-agent-keychain  → merged as ace03a00
- Assumptions: kept service id io.tonebox.secrets (documented; may move to io.tonebox.baton later)
```

This is a lightly-anonymized version of what actually landed in commit `bc6c494e`.

---

## 8. Orchestrator responsibilities

You (the orchestrator) do the work agents can't: see the whole, sequence it, and own correctness.

1. **Map coupling before slicing.** grep imports and call-sites; know the blast radius (Baton's
   ~367 call-sites) *before* deciding what's disjoint. Structural-query tooling (call graphs)
   helps — seed it with real identifiers.
2. **Classify tracks** (independent vs shared-target) and **design the waves.**
3. **Slice into disjoint file sets**, verify disjointness by grep, and **freeze the public APIs**
   for the wave.
4. **Write the briefs** (§7), one per agent, and **choose isolation + model** per agent.
5. **Merge** slices (clean-merge worktrees/branches).
6. **Run the gate** (§5) — regenerate, build, full suite, runtime smoke. Never delegate this.
7. **Triage integration failures** (§9) and fix at the gate with a small orchestrator commit.
8. **Keep a live plan doc** (like `ORCHESTRATION-PLAN.md`): waves, agent→file-set map, frozen APIs,
   gate status. Update it as waves land. It is the shared source of truth across agents and sessions.

### Model-matching (assign the right tier per agent)

| Work | Tier |
|---|---|
| Web / visual / marketing design | A creative-leaning model (Baton uses fable-5 for the site) |
| Standard code slices | The default coding model |
| Trickiest correctness (MCP server, audio-focus IPC, concurrency) | A higher-effort tier |

---

## 9. Failure modes + mitigations

| Failure | Smell | Mitigation |
|---|---|---|
| **Merge conflict** | Two slices edited the same hunk | You weren't disjoint. Re-grep coupling; merge the two into one agent or split into separate waves. Worktrees make the conflict explicit at merge, not silently. |
| **Agent drifts out of scope** | Files changed outside the brief's allow-list | Enforce the DO-NOT-TOUCH list; verify with `git diff --name-only` against the allow-list at merge; reject and re-scope. |
| **Non-compiling slice** | Agent reports "done" but slice doesn't build | Require build+test *in the brief* with pasted output. Worktrees + unique build dirs let each agent actually prove it. |
| **Runtime-only failure** | Compiles, crashes on launch/first use (DI/env/config) | The §5 runtime smoke step exists for this. Baton's `3207bda6` env-injection crash is the canonical case — caught by the full suite, invisible to compile. |
| **Rate / cost blowup** | Too many concurrent high-effort agents | Cap concurrency to your real disjoint-slice count (§1). Use cheaper tiers for mechanical slices; reserve high-effort for genuinely hard correctness. |
| **Silent scope truncation** | Agent quietly did half the file set | Make scope *exhaustive and explicit* in the brief; require a "could NOT do / assumptions" section; completeness critic (§6) at the gate. |
| **Residual origin-app coupling** | Extracted code compiles in the monorepo, breaks standalone | Loop-until-dry reviewer hunting stray imports/types/service-ids; the standalone build IS the real test. |
| **API drift between siblings** | Sibling renamed a public symbol mid-wave | Freeze public APIs per wave (§3). Do signature changes in a dedicated seam wave. |

---

## 10. Harness adaptation

Same abstract model, mapped to each tool. For every harness you need three primitives:
**(1) disjoint-file fan-out, (2) per-agent isolation, (3) the serial integration gate.**

### Claude Code
- **Fan-out:** spawn multiple subagents in one turn (they run concurrently); give each a §7 brief
  with an exhaustive file allow-list. Use background tasks for long-running independent tracks.
- **Isolation:** built-in git-worktree isolation per agent (each builds/tests its slice); or same-tree
  disjoint edits with the orchestrator gating the build. Give each worktree a unique build dir.
- **Gate:** the top-level (orchestrator) session runs regenerate → build → full suite → runtime smoke.
  Subagents never run the gate; they report structured results back.

### Cursor
- **Fan-out:** Background Agents run in parallel, each on its own branch/task; Composer does the
  multi-file edit within a slice. Assign one Background Agent per disjoint file set.
- **Isolation:** Background Agents run in isolated environments/branches → merge via PRs. For local
  Composer work, keep slices disjoint and gate centrally.
- **Gate:** you (or a dedicated "integrator" agent) pull the branches together and run the full
  build+test locally before merging the PRs.

### Windsurf / Cascade
- **Fan-out:** run multiple Cascade sessions, one per disjoint slice; Cascade's multi-file awareness
  keeps each slice coherent.
- **Isolation:** branch- or worktree-per-session; keep concurrent sessions on non-overlapping files.
- **Gate:** a separate session (or you) does the merge + full build/test; don't let a feature session
  self-certify the whole target.

### Aider
- **Fan-out:** Aider is git-native — run **multiple sessions**, each in its own worktree/branch,
  each scoped to an explicit file set (`/add` only the slice's files; nothing else in scope).
- **Isolation:** worktrees are natural here; each session commits to its branch. Unique build dir per
  worktree.
- **Gate:** outside Aider, merge the branches and run the project's real build+test; Aider's
  auto-commits make the merge history clean.

### Generic CLI agents (the universal fallback)
- **Fan-out:** `tmux` with N panes, N git worktrees (or clones), one agent per pane scoped to a
  disjoint file set via its brief.
- **Isolation:** worktree-per-pane; export a unique build dir per pane
  (`CARGO_TARGET_DIR`, `-derivedDataPath ./.dd`, isolated `$TMPDIR`) so concurrent builds don't race.
- **Gate:** a **merge script** the orchestrator runs:
  ```bash
  set -e
  for b in "$@"; do git merge --no-ff "$b"; done   # clean-merge each slice branch
  <regenerate-project>                              # e.g. xcodegen generate
  <build-whole-target>                              # e.g. xcodebuild / cargo build / make
  <run-full-test-suite>                             # every test, not just changed slices
  <runtime-smoke>                                   # launch / DI-env check
  echo "GATE GREEN"
  ```

Whatever the harness, the invariants are constant: **agents get disjoint slices and frozen APIs;
isolation prevents physical collisions; the orchestrator alone runs the assemble-build-test-smoke
gate that closes every wave.**

---

## Appendix — Baton case study at a glance

| Element | What happened | Commit / ref |
|---|---|---|
| Stable-API carve-out | `MusicModel` root created; `AppModel` forwards 7 members → ~367 call-sites byte-for-byte unchanged; full suite green (192) | `bdeee01d` |
| Parallel worktree agent A | Owner-token audio-focus generalizes capture suspend/resume (`Audio/*`) | `26aaee0c`, merge `6386c0d3` |
| Parallel worktree agent B | NavidromeConfig secret via own Keychain helper (`Integrations/Navidrome/*`) — disjoint from A | `bc6c494e`, merge `ace03a00` |
| Clean merge | Two disjoint slices → two conflict-free merges | `ace03a00`, `6386c0d3` |
| Integration gate catch | Views compiled reading `@Environment(MusicModel.self)`; snapshot tests injected only `AppModel` → runtime lookup crash; fixed by injecting `model.musicModel`; suite green (196) | `3207bda6` |
| The plan | Wave 0–5 decomposition, honest-parallelism rule, guardrails | `~/Projects/baton/ORCHESTRATION-PLAN.md` |
```

