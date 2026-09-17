# Release: GUI hang fixes, resizable columns, credential hardening

## Highlights

- **Fixed the GUI hang at "Validating connectivity and services..."** — a
  two-thread deadlock between worker runspaces and the WPF UI thread, with a
  second latent deadlock in the job-cleanup path. Both are eliminated and
  covered by headless regression harnesses.
- **Columns now auto-fit the window and are drag-resizable** — the header
  always spans the viewport, each column has a resize grip, and user-dragged
  widths are respected while the remaining columns redistribute.
- **All credential parameters are typed `[pscredential]`** — a plain-string
  password can no longer be passed as a credential anywhere in the app.
- **Fixed a latent PS 5.1 bug that would have broken custom credentials
  everywhere** — `Get-CimInstance` has no `-Credential` parameter on
  Windows PowerShell 5.1; alternate credentials now flow through
  `New-CimSession` (DCOM) + `Get-CimInstance -CimSession`.

---

## Fixes

### GUI hangs (root-caused and eliminated)

1. **Dispatcher-action deadlock** — a `[action]{...}` passed to
   `Dispatcher.Invoke` from a worker runspace executes on the UI thread but
   is bound to the *worker's* session state. Any pipeline cmdlet inside the
   action (`Where-Object`/`Select-Object`) then needs the worker's PowerShell
   engine — which is blocked inside `Invoke` waiting for that same action.
   Permanent two-thread deadlock: frozen UI, worker stuck, no logs.
   Fixed by replacing pipelines with `foreach` loops in
   `SafeUpdateListViewItemScript` and the jobCleanup timeout handler.
2. **Runspace function injection** — helper scriptblocks injected into
   isolated worker runspaces are now unbound (`[scriptblock]::Create`)
   and reference only injected variables; worker scriptblocks no longer
   call main-script functions.
3. **COM timeout protection** — the Windows Update search runs on an
   in-process background thread (never `Start-Job`, which serializes COM
   objects) with bounded waits, so a hung COM call can no longer block a job
   forever.
4. **Stale `ViewportWidth` during resize** — column auto-fit now runs at
   Render dispatcher priority with burst coalescing, so it always computes
   from the current viewport size.

### Resizable / auto-fitting columns

- The header Thumb must be named **`PART_HeaderGripper`** (with "er") —
  WPF's `GridViewColumnHeader` wires native drag-resize only to that exact
  name. Widely-documented `PART_HeaderGrip` is wrong and silently disables
  resizing.
- WPF's native gripper marks drag events handled, so our bookkeeping
  handlers register with `handledEventsToo=$true`.
- `GridViewColumn` has no `MinWidth`; a `DragDelta` clamp enforces a 40px
  floor so a column cannot be dragged to zero width.
- Water-filling distribution: user-dragged columns keep their width, free
  columns split the remaining space, and when even the minimums don't fit
  the ListView scrolls horizontally.

### Credentials (SecureString everywhere)

- Every `$Cred`/`$Credential` parameter is now `[pscredential]` (main-script
  helpers, worker-runspace copies, and the injected credential-probe).
- **PS 5.1 CIM credential fix**: `Get-CimInstance @params` with
  `$params.Credential` always threw "A parameter cannot be found that
  matches parameter name 'Credential'". Alternate credentials now go through
  `New-CimSession -Credential` + `Get-CimInstance -CimSession` (DCOM, with
  session cleanup in `finally`).
- The injected credential probe previously built a params hashtable but
  never ran the query — the "credential test" always succeeded. It now
  actually validates credentials and reachability.
- `Unprotect-ComputerListData` no longer leaks the BSTR holding the
  decrypted plaintext.

### Other

- Removed dead code and silent variable shadowing (`$RemoveEntry`/`$GetErrors`
  duplicates that shadowed the live implementations).
- PS 5.1 compatibility: `Test-Connection -TimeoutSeconds` (PS6+) replaced
  with `System.Net.NetworkInformation.Ping`; `Get-Service -ComputerName`
  in workers replaced with `Invoke-Command` remoting.

## New regression tests

- `Scripts/Test-ColumnResize.ps1` — window-resize auto-fit, small-window
  water-fill minimums, grip presence, user-resize honoring.
- `Scripts/Test-DragResize.ps1` — native drag wiring, 40px floor, drag
  redistribution.
- `Scripts/Test-CredentialTyping.ps1` — null-credential binding,
  PSCredential crossing the job boundary, plain strings never becoming
  working credentials.
- `Scripts/Validate-Release.ps1` — XAML load + control wiring (all pass).

## Repo hygiene

- `.gitignore`: runtime debug logs, `dist/` output, historical backup
  scripts, `psexec.exe`, encrypted `ComputerList.config`.

## Validation

PowerShell parser: 0 errors · `Validate-Release.ps1`: all checks pass ·
All functional test suites pass against the real XAML + real extracted code
under Windows PowerShell 5.1 STA.