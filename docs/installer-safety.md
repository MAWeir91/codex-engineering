# Installer safety and recovery

The Windows installer rejects existing junctions, symlinks, and other reparse
points in CodexHome, its ancestors, managed destinations, journal/install-record
paths, and transaction backup paths. It checks relevant paths during planning
and immediately before file operations. Protected destinations retain the
existing ownership migration rules: modified formerly managed config is
preserved and released, while an unchanged legacy managed copy may be retired.

One global named OS mutex is held from before recovery and manifest validation
through planning, deployment, commit, rollback, and cleanup. Its key uses the
canonical volume GUID directory path plus any not-yet-created components, so
case, trailing separators, short names, and alternate drive mappings do not
create separate locks for the same home. A contender fails without creating or
changing installer files. Process exit releases ownership automatically.
Paths whose canonical local-volume identity cannot be established (including
unsupported network filesystem layouts) fail safely before mutation.

Transaction schema 2 records SHA-256 before/after content states (null means
absence), including the install record. All recovery entries and backups are
checked before any reversal. Recognized before states need no action;
recognized after states can be reversed. Any other state is ambiguous: recovery
preserves the file and journal and reports the destination requiring review.
Recovery is resumable if interrupted during reversal. Files newly created by
the transaction are removed only when their content matches the recorded after
state. An independently created/changed file is preserved.

The journal content identity is checked under lock before publication,
mutation, and deletion. A missing or changed owned journal is an error.
The installed record must match its journaled after hash before the journal can
be deleted. A mismatched record fails the transaction, and ambiguous recovery
preserves both the record and journal.
Older schema 1 journals lack the state evidence needed for safe automatic
recovery and are preserved for manual review; -Force does not bypass recovery
safety checks. Review ambiguous files and their retained backups before manually
restoring known transaction states or retiring a journal.

## Residual limits

PowerShell path checks and filesystem mutations are separate operations. An
unrelated process with write access can replace an ancestor, file, backup, or
journal between a check and its operation. These checks do not eliminate that
TOCTOU race, and the installer mutex coordinates installers only. Use trusted
local directory ancestors and avoid concurrent external edits during installation.
Content hashes recognize byte states, not provenance: an external file with
exactly the same bytes as a recorded state is indistinguishable from that state.
The journal and backups are not authenticated against a malicious local writer.
Backups are retained; successful no-op installs also journal the install-record
update so interruption cannot leave an untracked record mutation.

From the repository root, run the deterministic Windows regression suite with
Windows PowerShell 5.1:

    powershell -NoProfile -File evals/bootstrap/test-bootstrap.ps1 -RepoRoot .

PowerShell 7 is also supported:

    pwsh -NoProfile -File evals/bootstrap/test-bootstrap.ps1 -RepoRoot .

The suite uses disposable homes, real child installer processes, and junctions.
Child-process argument encoding uses .NET Framework-compatible process APIs;
the suite verifies special-character arguments through the running host.
Junctions are unlinked before temporary directories are recursively cleaned up.
