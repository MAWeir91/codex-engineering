# Configuration ownership

Codex Engineering separates shared project defaults from machine/user configuration.

## User level: `~/.codex/config.toml`

This file is **not managed by this repository**.

Use it for personal or machine-local settings such as provider/auth configuration, notification commands, telemetry, profile selection, desktop-local configuration, or other preferences that should apply across projects.

The deployment manifest protects `config.toml` so normal installs cannot begin managing it accidentally.

## Project level: `.codex/config.toml`

Shared engineering defaults live in the repository's `.codex/config.toml`.

Codex loads project configuration only for trusted projects. Project configuration has higher precedence than user configuration for supported project-scoped settings.

The canonical template for new projects is:

`project-template/.codex/config.toml`

The root `.codex/config.toml` and template copy must remain identical; `scripts/validate.ps1` and the config regression eval enforce this.

## Migration from v1

v1 installed `runtime/config.toml` to `~/.codex/config.toml`.

In v2:

- `runtime/config.toml` is retired;
- the manifest no longer manages user-level config;
- `config.toml` is a protected destination;
- if the prior install record proves that the existing user config is the unchanged v1-managed copy, the installer backs it up transactionally and removes it as stale managed state;
- if that file has been locally modified and `config.toml` is protected by the new manifest, the installer preserves the file and releases it from Codex Engineering ownership;
- other locally modified stale managed files still block installation unless the conflict is explicitly resolved.

After migration, future user-level config files are unowned and preserved. A released v1 config may still contain engineering defaults that were previously global; review it separately before deciding which user-level settings to keep.
