# Defects Found During the WUU2 GUI Uplift

Recorded: 2026-10-06. Scope: Phase 0 (baselines/promotion) and early Phase 1/2 work of the WUU2 GUI
uplift. Donor `WUU2-CLI` was inspected read-only and **not modified** by this work; it was separately
advanced to `v1.5.0-rc.2-cli` by other work, whose state is verified in
`WUU2-CLI\docs\DEFECTS_AND_COVERAGE_20261006.md` §8.

Method: direct source inspection, bounded child-process test runs, and targeted behavioural probes
(not classifier-only or source-regex checks). This is a defects register, not a test report — see
`docs\tasks\phase-0-evidence.md` for the baseline and gate results.

**Current verified state (2026-10-06):** target gate **exit 0**; target suites
**PASS 13 · SKIP 1 · FAIL 0** (14 suites; no STALE category — all suites run on the current tree).

| ID | Severity | Status | Area | Requirement |
|----|----------|--------|------|-------------|
| D1 | CRITICAL | **Fixed in target (2nd attempt, verified)**; fixed in donor | Remote probe / credential verification | R02, R04 |
| D1a | CRITICAL | **Fixed — introduced and repaired same day** | The first D1 fix broke *every* probe (see below) | R01, R02 |
| D2 | HIGH | Fixed in target | Credential identity / silent fallback | R04 |
| D3 | HIGH | **Resolved** — all 3 suites retargeted and green; runner's stale list removed | Test fixtures after module split | R01, R08 |
| D4 | HIGH | **Fixed** — operator data excluded, plus a fail-closed packaging guard | Release packaging ships operator data | R08 |
| D5 | MEDIUM | **Withdrawn — see correction below** | Child-process exit-code capture | R08 |
| D6 | MEDIUM | Fixed in target | Stale instruction files | R08 |
| D7 | MEDIUM | **Fixed in target (T005, verified)** | Target has no version constant | R08 |
| D8 | LOW | Fixed in target | Wasted credential round-trip per computer | R03 |
| D9 | LOW | **Fixed** — replaced with `Test-CredentialContract` | A suite that could not fail asserted a false premise | R08 |
| D10 | MEDIUM | **Fixed (verified)** — recovery reachable, code propagated, 22 assertions | RPC-recovery branch unreachable: `Invoke-AutoRecovery` is not resolvable from `Wuu.Remote` | R03 |
| D11 | HIGH | **Fixed (2026-10-08)** | Case-only clear-list alias overwrote its implementation and self-recursed | R01, R02 |
| D12 | HIGH | **Fixed for observed obsolete-row case (2026-10-08)** | Worker helpers accepted an old row after same-name replacement; atomic race remains open | R02 |
| D13 | HIGH | **Fixed for helper outcome/error visibility (2026-10-08)** | Empty helper catches and absent verdicts let swallowed failures look like refusals | R02, R08 |
| D14 | CRITICAL | **Fixed for the managed submission path (2026-10-08)** | `Start-UpdateCheckJob` started the payload before claiming the row, so a refused claim left unattributed work running; six direct Core handlers remain unconverted | R02, R03 |

**Remediation update (2026-10-08):** 18 suites, 17 PASS / 1 SKIP / 0 FAIL / 0 TIMEOUT; release gate
exit 0. Actual factory-injection coverage now exists (89 assertions in the extended twin suite).
See [phase-1 evidence](tasks/phase-1-evidence.md) for limitations and the independent review.
Submission-before-ownership is now fixed for the managed path (D14); the six direct Core handlers,
atomic validation/write/snapshot, whole-store config replacement and unbounded production pool
shutdown remain open migration findings, not covered by D11-D14 closure.

**D1 is broader in this edition than in the donor.** Here the same envelope-misread defect also leaves
the RPC-recovery branch unreachable and the pre-flight credential/os probes misreporting. The donor
copy of `Invoke-CimWithTimeout` is additionally shadowed in production by a *correct* inlined twin
inside the per-computer payload, so the donor's exposure is narrower. Full CLI-side detail, including
the two-copy divergence and the coverage gaps that let it through, is in
`WUU2-CLI\docs\DEFECTS_AND_COVERAGE_20261006.md`.

---

## D1 — CRITICAL — `Invoke-CimWithTimeout` reported every failed probe as a success

**Where**
- Target: `src\Wuu.Remote.psm1`, function `Invoke-CimWithTimeout`.
- Donor: `src\Wuu.Remote.psm1`, same function — **defect still present** (line ~124 reads
  `if ($cimResult.Success) {` directly off the pool wrapper; the retry path near line ~147 has the
  same shape).

**Cause**
The inner scriptblock deliberately catches its own errors and returns
`@{ Success = $false; Error = <message> }`. `Invoke-WithPoolTimeout` wraps that in its own
`@{ Success; Result; Error }` envelope, where `Success` means only *"the scriptblock ran to
completion"*. The function read the **wrapper's** `Success`. A probe that completed but failed
therefore produced wrapper `Success = $true` with the real failure nested one level down in
`Result.Error`. The failure was never observed.

**Impact**
Every caller branching on `.Success` treated genuine failures as successes. The most serious
consequence is credential verification: it could never report failure, so the "no fallback to
another identity" rule (R04) was **unenforceable** — an operation could proceed under an unintended
identity and report success. The same masking affected service control, RPC-class error recovery and
patch-telemetry probes. This is a silent-failure class defect: nothing surfaced to the operator.

**Evidence**
Probe against a name that cannot resolve:
```
Success = $true
Error   = ''
real cause 'The RPC server is unavailable'  ->  nested in Result.Error
```

**Fix (target only)**
The pool envelope is now unwrapped and the **inner** result is authoritative. A wrapper failure
(timeout, terminated pipeline) or an unexpected shape is a failure carrying the wrapper's reason.
Re-verified by the same probe: failed probes now report `Success = $false` with the real cause.

**The retry path had to be fixed too.** The `0x800706ba` / `0x800706be` branch is unreachable today
(see **D10** below), so the broken retry block was dead code. It was corrected anyway (unwrap
`$retryInner`), because leaving it would re-introduce D1 the moment the recovery path becomes
reachable. This mirrors the CLI edition, which fixed the same block.

> **Correction to an earlier note in this register.** This entry previously said `Invoke-AutoRecovery`
> "has no module-scope definition in this repository — it exists only inside the injected payload".
> That is **wrong**. `Invoke-AutoRecovery` (and `Get-ErrorSuggestions`) *do* exist at module scope in
> `src\Wuu.Core.psm1`, at lines 535 and ~500 respectively. The branch is unreachable for a different
> reason — cross-module visibility — which is recorded properly as D10 below. The earlier statement
> was inferred from a search that matched only the payload copy; the module-scope copy is defined
> before the payload's redefinition and is easy to miss because both appear in the same file.


### D1a — CRITICAL — the first fix broke every probe (introduced and repaired 2026-10-06)

Worth recording because it is the exact failure mode this register exists to catch.

The first version of the fix read the wrapper as `$poolResult` but did **not** rename the capture
line, which still assigned `$cimResult`:

```powershell
$cimResult  = Invoke-WithPoolTimeout …      # captured under the OLD name
…
$cimResult = $null                          # then deliberately reset to unwrap
if ($poolResult -and …) { $cimResult = $poolResult.Result }   # $poolResult is undefined
```

`$poolResult` was therefore never set, so the guard never matched and the function returned
`Success = $false` with *"the CIM probe returned no result"* for **every** probe — including the
`localhost` happy path. The previously-passing `Test-RemoteHelpers` began failing:

```
FAIL: CIM helper returns Win32_ComputerSystem data ()
FAIL: hard timeout fires on unreachable host (the CIM probe returned no result)
```

A silent success had become a silent failure. Repair: capture into `$poolResult`, leaving `$cimResult`
free to hold the unwrapped inner result, with a comment naming both objects so the two-layer shape is
explicit. Verified: `Test-RemoteHelpers` 5/5 PASS with real data returned (`DARREN-PC`), and the full
suite moved from `FAIL 1` to `FAIL 0`.

**Lesson recorded for the promotion step:** the CLI's `Test-RemainingBudget` §12 asserts envelope
agreement by AST inspection, and it did **not** catch this. Structural assertions on source text
confirm the *shape* of the code; only driving the helper catches a mis-named variable. Any future
port of this fix needs a live happy-path probe, not just an unwrap-shape check.

**Residual risk**
None outstanding in this edition (both copies now correct). The donor is likewise fixed as of
`v1.5.0-rc.2-cli`; see the CLI record for its independent verification.

---

## D2 — HIGH — `Get-RemoteCredentials` silently fell back to the process identity

**Where**
- Target: `src\Wuu.Credentials.psm1`, `Get-RemoteCredentials` (pre-fix).

**Cause**
Two overlapping faults:
1. It returned `$null` for **both** "no custom credential configured" and "configured custom
   credential failed". `$null` legitimately means *use the process identity*, so a failed custom
   credential became indistinguishable from no custom credential configured — and the caller
   proceeded, as the wrong identity.
2. When no custom credential was configured it probed the default credential and discarded the
   result, costing one network round trip per computer while changing nothing but the log.

**Impact**
A mis-typed, disabled, or expired custom credential did not fail the operation; it silently ran as
the process account. Combined with D1 (verification could never fail), the fallback was not detectable
by any caller. Direct violation of R04.

**Fix**
`Get-RemoteCredentials` now resolves the mode first, and for custom mode **verifies** the identity and
**throws** with the reason when it is not usable. `$null` is returned only for a genuine `Default`
mode. The wasted default-credential probe was removed. The runtime cache is still honoured but can
never contradict the configured mode.

**Evidence**
`tests\Test-CredentialDeterminism.ps1` added: asserts no silent fallback, deterministic resolution and
state-signature behaviour.

---

## D3 — HIGH — Three test suites broke during the module split (false green / hang)

**Where**
- `tests\Test-ColumnResize.ps1`
- `tests\Test-DragResize.ps1`
- `tests\Test-CredentialTyping.ps1`

**Cause**
The suite fixtures still target the pre-split layout:
- `Test-ColumnResize` / `Test-DragResize` parse a root `WUU.xaml` that no longer exists and extract
  `Set-ColumnProportionalWidths` / `$eventWindowInit` from `WUU.ps1`, which is now a thin launcher.
  The function now lives in `src\Wuu.Core.psm1`; the layout is `ui\MainWindow.xaml`.
- `Test-CredentialTyping` pointed at the removed location. The import path was repaired to
  `src\Wuu.Remote.psm1` (confirmed the function moved there), but each of its three probes targets a
  non-routable DCOM host and burns its full 10s timeout plus up to 10s stop-wait, so it exceeds 180s
  wall-clock and cannot run in CI.

**Impact**
The GUI-specific drag/resize and credential-typing coverage was **absent while appearing present**.
A naive runner reported these as green (see D5), so the regression gate had a real blind spot in
exactly the GUI-behaviour area this uplift touches.

**Status**
**RESOLVED (T025).** All three suites were retargeted and now run as real coverage:

- `Test-ColumnResize.ps1` — parses `src\Wuu.Core.psm1` for `Set-ColumnProportionalWidths` and loads
  `ui\MainWindow.xaml`. PASS, 6 assertions.
- `Test-DragResize.ps1` — same retarget, **and converted from a narrative log into assertions**. It
  previously printed its findings and always exited 0, so it too could not fail; it now asserts the
  drag delta, the `userResizedColumns` recording, the refit keeping the dragged width, and the
  over-shrink floor. PASS, 5 assertions.
- The credential-typing suite was **not** repairable and was replaced — see D9.

The runner's hard-coded stale list (`$script:StaleSuites`) was then **removed entirely**, along with
its `-IncludeStale` parameter and the `STALE` verdict. The category was deleted rather than emptied on
purpose: a stale list is where a suite that has quietly stopped testing anything can hide while still
counting toward the suite total. A suite that cannot run on the current tree should fail loudly.

**Note on the recorded reason:** the stale reason for the credential suite claimed each probe
"burns its full 10s timeout … exceeds 180s wall-clock". Measured: the suite completed in **10.9s**.
The performance claim was wrong; the suite's real problem was vacuity, not duration (D9). The stale
reasons were authored from reasoning, not measurement, which is how they survived.

---

## D4 — HIGH — Release packaging ships operator data (OPEN)

**Where**
- `Scripts\Package-WUU2.ps1`, `$include` list (line ~17: `"ComputerList.config"`).

**Cause**
`ComputerList.config` is the operator's real saved computer list — hostnames, phases and credential
mode/username metadata. It is copied into every release zip.

**Impact**
Disclosure of the operator's fleet inventory and naming to anyone who receives the package. R08
explicitly requires the release to carry no operator data.

**Status**
**FIXED (T027).** `ComputerList.config` was removed from `$include`, and — more importantly — a
fail-closed guard was added to the staging step: if any operator-data or history file would reach the
zip, packaging **throws** instead of warning. A warning would have let the original leak ship for
months, because a successful-looking package is produced either way.

The guard rejects `ComputerList.config`, `WUU_backup*`, `WUU_updated_backup*`, `WUU_v1.1*`,
`WUU_debug*`, `WUU_git_version*`, `WUU_perplexity*` and `*.log`.

**Verified:** a real package was built to a temp directory — 25 entries, exit 0, and the entries
matching `config|backup|debug|perplexity|.log|git_version|v1\.1` returned nothing (`src\Wuu.Configuration.psm1`
matches `config` but is a module, not operator data). `ComputerList.config` **does** exist in the repo
root, so the exclusion is proven meaningful rather than vacuous.

---

## D5 — MEDIUM — WITHDRAWN — Child-process exit codes are unreliable in this environment

> **Correction (2026-10-06, later the same day).** The text below was written during the Phase 0
> baseline and its closing claim about the donor is **wrong**. `WUU2-CLI\Scripts\Invoke-TestSuites.ps1`
> already uses `System.Diagnostics.Process` directly, with an in-source comment recording the exact
> `Start-Process` measurement. The exit-code capture defect was in the **target** runner only, and is
> fixed by the new `WUU2\Scripts\Invoke-TestSuites.ps1`. The environment observation itself (both
> naive capture methods returned `0` for `exit 7`) is retained because it is what justified the
> framework-type approach in both runners. The CLI-side record is at
> `WUU2-CLI\docs\DEFECTS_AND_COVERAGE_20261006.md` §4.

**Where**
- Environment/tooling; affects any script that gates on a child process's exit code.

**Cause**
Both `Start-Process -PassThru` and a `cmd /c ... %ERRORLEVEL%` wrapper silently reported `0` for a
script that ran `exit 7`. The first baseline run therefore reported **ten false PASSes** — the
failure was in the capture, not the suites. Using `System.Diagnostics.Process` is the only capture
that reflected the true exit code (verified against `exit 7`, an unhandled `throw`, and `exit 0`).

**Impact**
Any quality gate built on the unreliable captures would pass while the underlying suite failed —
a false-green mechanism sitting underneath the whole release gate.

**Fix**
`Scripts\Invoke-TestSuites.ps1` uses `System.Diagnostics.Process` exclusively, and classifies
PASS / FAIL / SKIP / TIMEOUT / STALE. Re-running the baseline with it changed the result from
"10 PASS" to the truthful **PASS 7 · SKIP 1 · STALE 3 · FAIL 0 · TIMEOUT 0**.

**Residual risk**
None outstanding. The earlier note claiming the donor runner used the old capture method was
incorrect and is withdrawn (see the correction at the head of this section). The CLI edition's runner
was already correct; the exit-code capture defect was confined to this edition.

**Related traps worth remembering**
- `Test-RemoteTask` exits **1 by design** when not elevated, printing a `SKIP:` marker. A runner that
  treats any non-zero exit as FAIL will misreport it. A SKIP is not coverage.
- PowerShell `-File` argument passing collapses an array into a single string, and
  `Set-StrictMode -Version Latest` then throws on single-element array unrolling. The runner accepts
  a delimited string for filters and guards the unrolling.

---

## D6 — MEDIUM — Instruction files described a code layout that no longer existed

**Where**
- `.github\copilot-instructions.md`
- `.github\instructions\powershell.instructions.md`

**Cause**
Documentation was not updated when the single script was split into modules. The files claimed
`WUU.ps1` was the sole editable code file, referenced root-level `WUU.xaml` / `OUPicker.xaml`, and
stated there was no test suite. The real tree is eight `src\*.psm1` modules, `ui\*.xaml` layouts and a
`tests\` directory.

**Impact**
Any contributor (human or automated) following the instructions would edit the wrong file, look for
non-existent layouts, and skip the test suite entirely — actively steering changes away from the
code that needs them.

**Fix**
Both files reconciled with the real architecture: module list and import order, `WUU.ps1` described as
a thin launcher, UI paths corrected to `ui\*.xaml`, the false "no test suite" claim removed, and the
suite runner documented with an explicit warning that SKIP and STALE are never coverage.

---

## D7 — MEDIUM — The target has no version constant (FIXED)

**Where**
- `WUU2` (whole repo). Donor counterpart: `$global:WuuVersion = 'v1.5.0-rc.1-cli'` in
  `src\Wuu.Configuration.psm1`.

**Cause**
The GUI edition previously never introduced an application version constant; it carried only
`#Requires -Version 5.1` headers and a dated changelog comment.

**Impact**
Released packages could not be traced to a build identity, and audit/report artefacts could not be tied
to the producing version. Blocked provenance for R08.

**Status**
**FIXED (T005).** Introduced target-owned version constant `$global:WuuVersion = 'v1.3.4'` in
`src\Wuu.Configuration.psm1` (`Initialize-WuuConfiguration`), wired to `Resolve-WuuVersion` (exported from
`Wuu.State`) for repository provenance detection. The CLI literal was deliberately **not** transplanted,
preserving independent edition versioning.

**Verification:**
- `tests\Test-ModuleImport.ps1` asserts `$global:WuuVersion` is populated and does not contain `*-cli*` (PASS).
- `Scripts\Validate-Release.ps1` gates on the presence and edition boundary of `$global:WuuVersion` (PASS).

---

## D9 — LOW — A suite that could not fail, asserting a false premise

**Where**
- `tests\Test-CredentialTyping.ps1` (now removed; replaced by `tests\Test-CredentialContract.ps1`).

**Cause**
Three probes, of which none could fail:
- Tests A and B asserted only that the call returned `$false` **and** that the message was not a
  binding error. Against a permanent non-existent host, a hard-coded `$false` satisfies both. The
  assertions proved the call did not throw; they could not distinguish success from failure.
- Test C claimed "a plain STRING must NOT silently become a credential" and counted *not throwing*
  as a pass. Measured: binding a string to a `[pscredential]` parameter yields **`$null`** — it does
  not throw, and it does not use the literal as a password — so the string was never a credential
  and the assertion held regardless of the code. The in-source comment also asserted the conversion
  "fails (no prompt available)"; PowerShell does not prompt on this path.

**Impact**
A suite that reports PASS while testing nothing is worse than a suite that is absent, because it
occupies a line in the suite count and deters anyone from writing the real test. This is the same
class as D3 and C7, and it was the suite I had earlier marked STALE for a *performance* reason that
turned out to be incorrect (`>180s`) — the real problem was never speed, it was vacuity.

**Fix**
Replaced with `tests\Test-CredentialContract.ps1`, which asserts the R04 identity rule that the old
probes were circling:
- the declared parameter type is `[pscredential]` (so a bare string can never *be* the value);
- a string bound to `[pscredential]` becomes `$null`/is refused — the **measured** behaviour, pinned
  so the old misleading comment cannot be reintroduced;
- a real `PSCredential` crosses the pool runspace boundary typed, with username and secret intact
  (the marshalling property the old Test B gestured at but never checked);
- **the security invariant**, driven against a real failing probe (an unresolvable host): the
  resolver stays in `Custom` mode, `Verified` is `$false`, the reason says "no fallback attempted",
  and `Get-RemoteCredentials` **throws** rather than returning `$null`;
- `$null` still legitimately means "process identity" when nothing custom is configured — the
  distinction the old suite conflated.

**Result:** 17 assertions, 5.8s, no mocks. The old suite was 3 assertions, ~11s, two of which could
not fail.

---

## D10 — MEDIUM — The RPC-recovery branch was unreachable (FIXED)

**Where**
- `src\Wuu.Remote.psm1`, inside `Invoke-CimWithTimeout`, the `0x800706ba` / `0x800706be` branch.
- The same defect existed in the CLI edition, where it was fixed in `v1.5.0-rc.4-cli` (C8).

**Cause — two independent defects, either one sufficient to kill the branch**

1. **Resolution.** The branch called `Invoke-AutoRecovery` unqualified, but that function lives in
   `Wuu.Core` (private, unexported) and `Wuu.Remote` defined/exported no equivalent. A module cannot
   resolve another module's private functions, and `-ErrorAction SilentlyContinue` hid the failure.
2. **Code extraction.** It matched an `0x…` HRESULT out of the error **message text**. Measured on a
   genuine failure, the message is the localized sentence `The RPC server is unavailable.` with no hex
   code in it, so `$hresult` stayed `$null` and the branch was skipped even had it resolved.

**Impact**
The `0x800706ba` / `0x800706be` path never attempted recovery or its post-recovery retry. Three layers
of work were dead: `Invoke-AutoRecovery`, `Get-ErrorSuggestions`, and the retry whose envelope bug had
already been fixed as part of D1.

**Fix**
1. `Wuu.Remote` now **owns and exports** `Invoke-AutoRecovery`, with a header explaining why this is not
   a redundant third copy: the Core copy serves Core's own direct caller (the interactive connectivity
   loop at `Wuu.Core.psm1:1787`), and cannot be reached from here. `Invoke-AutoRecovery` is
   normalization-first, so a bare code, an `0x`-prefixed code and a sentence all reach the switch —
   the CLI edition got that wrong on its first attempt and returned `$false` for every input.
2. The worker's `catch` now captures **`HResult` and `ErrorId`** (`FullyQualifiedErrorId`) and returns
   them with the failure. The generic `-2146233088` (`COR_E_EXCEPTION`) wrapper HRESULT is deliberately
   ignored rather than allowed to masquerade as an RPC code.
3. The recovery branch prefers those structured fields, falling back to the message text only as a
   last resort, and passes a **normalized bare code**. The localized sentence is no longer the primary
   signal.
4. The structured code is **propagated to the public result** (`HResult` / `ErrorId` on the failure
   dictionary), so a caller that must distinguish an RPC failure from an access-denied failure is not
   forced back onto message parsing — the very reliance that caused this defect.

**Verified** — `tests\Test-RecoveryPath.ps1`, 22 assertions, exit 0:
- resolves inside the `Wuu.Remote` **module scope** (not merely in the session);
- normalization accepts `800706be`, `0x800706BE` and a sentence form;
- refuses `80070005`, an unknown code, and an empty code **without touching the target**;
- a real failing probe returns `HResult` and `ErrorId`, and the happy path is unaffected;
- source wiring asserts the branch reads the structured fields and passes a normalized code.

`Test-RemoteHelpers` still passes (5/5). Full suite **13 PASS / 1 SKIP / 0 FAIL**, gate exit 0.

**Recorded incident while writing the test.** The first version of the empty-code assertion was a bare
assignment:

```powershell
$empty = Invoke-AutoRecovery -ComputerName 'localhost' -ErrorCode ''
Assert-True (-not $empty) 'an empty code is NOT auto-recovered'
```

Binding an empty string to a mandatory parameter **throws**, the assignment never completes, `$empty`
stays `$null`, and `-not $null` is `$true` — so the assertion passed because the call never happened.
That is the same class as D9 (a test passing for the wrong reason) and it appeared in the fix for D10,
which is why it is written down. The replacement asserts the throw, then asserts that nothing was
recovered.

**Also recorded:** the Core copy waits 5s after restarting `RpcSs` plus a further 3s, while this copy
waits 2s. The divergence is deliberate (this copy's caller is already bounded by an operation deadline,
so a longer sleep would eat the budget the retry needs) and is documented in the function header, but
it is the same class as C2 — diverged duplicate helpers — and should be unified deliberately rather
than by accident.

---

## D8 — LOW — Wasted credential round trip per computer

**Where**
- Target: `src\Wuu.Credentials.psm1`, `Get-RemoteCredentials` (pre-fix).

**Cause**
When no custom credential was configured, the function probed the default credential and then
returned `$null` regardless of the probe outcome.

**Impact**
One unnecessary network round trip per computer on the default-credential path — a measurable cost on
large fleets, and it produced log noise that misrepresented a probe as meaningful. Fixed as part of
D2.

---

## D11-D13 - Initial Remediation Findings (2026-10-08)

**D11:** PowerShell variable names are case-insensitive. Core assigned the real `$clearComputerList`
body and then assigned `$ClearComputerList = { &$clearComputerList }` to that same binding. The alias
called itself. An AST regression first failed with two assignments; removing the redundant alias
restores the original body. The store suite now executes that body with a synthetic two-row removal
delegate and passes (37 assertions total). Full operational removal/retirement remains separate work.

**D12:** injected state and timeout helpers checked only whether a row existed under the computer key.
They could mutate an obsolete row when a replacement had the same name. A focused regression observed
old-row State/deadline mutation and revision 25 to 27. Both helpers now require reference equality with
the live store row. Direct and actual-runspace replacement cases pass. This does not solve replacement
between validation and write; the atomic protocol remains a required gate.

**D13:** injected helpers used bare returns and empty catches. A swallowed exception could produce the
same unchanged-state evidence as a deliberate refusal. Helpers now validate mandatory fields before
writes, return explicit Applied/Refused/Reason verdicts and surface unexpected errors. Production
timeout callers consume those verdicts; stale refusals stop retry/follow-up work at those sites.
Real-worker tests assert accepted/refused results, an accepted revision positive control and visible
malformed-row errors. Broad payload routing, full funnel parity and action authorization remain open.

Initial and follow-up independent reviews plus commands/provenance are recorded in
[phase-1 evidence](tasks/phase-1-evidence.md). No donor files were changed in this remediation.

## Referenced but not re-documented here

Six logic defects in the **CLI** edition (`WUU2-CLI`) were found and remediated before this phase:
failed-install outcome masking, main/worker reset-guard divergence, scheduler consuming pending work
before admission, cleanup leaving a stale operation id, implicit phase transition bypassing the
terminal guard, and `ClearOperation` laundering a terminal state into `Queued`. They are already fixed
in the donor at the accepted revision (`0566164`) and verified by its own suites
(`Test-InstallOutcome`, `Test-WorkerIdentityFence`, `Test-PendingPolicy`, `Test-CleanupIdentityRetire`,
`Test-TerminalStates`, … — 14/14 PASS). They are listed here only so this register is not read as
claiming the donor is defect-free: it is not, per D1. (D5 was withdrawn — the exit-code capture
defect was this edition's alone.) The CLI edition has its own defects record at
`WUU2-CLI\docs\DEFECTS_AND_COVERAGE_20261006.md`, which also lists what was checked and found sound
there.
