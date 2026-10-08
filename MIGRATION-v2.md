# v2 update application

Extract this ZIP over `C:\Users\TradeStation\codex-engineering`.

Then remove the retired source file before validation:

```powershell
Remove-Item .\runtime\config.toml
```

The new project-scoped config lives at:

- `.codex\config.toml`
- `project-template\.codex\config.toml`

Run:

```powershell
.\scripts\validate.ps1
.\scripts\test.ps1
.\scripts\install.ps1 -DryRun
```

For the v1 → v2 migration, the dry run should normally show the old user-level
`config.toml` as a stale managed removal if it has not been locally modified.
The real installer backs it up within the deployment transaction before removing it.
