# GDID Privacy Tool v2 Hardening Design

Date: 2026-08-02
Status: Draft approved for planning review
Scope: Conservative hardening update for the existing `gdid-privacy` project

## Goal

Ship a major update that keeps the current tool recognizable while making it more truthful, safer, and easier to validate. The update preserves the existing command surface where practical, but changes the internal model and documentation so the project no longer overstates what it can do.

The tool continues to support local registry masking, CDP blocking, HOSTS-based endpoint blocking, installation, uninstallation, status reporting, and configuration management. The update does not attempt to implement server-side Microsoft identity rotation or any other claim that cannot be verified by the local code.

## Problem Statement

The current project works as a local privacy-hardening tool, but it blends together three different ideas:

1. Local registry masking of GDID-related values.
2. Service and endpoint blocking that can reduce reporting paths.
3. Stronger claims about "rotation" than the implementation can support.

That mismatch creates four problems:

1. The documentation implies stronger identity change guarantees than the code can prove.
2. The scheduled task design uses elevated persistence for behavior that is largely `HKCU`-scoped.
3. The optional API/AppInit hook mode is exposed as a supported feature even though it lacks a trustworthy deployment and verification story.
4. The project lacks a strong validation pipeline for PowerShell parsing, configuration handling, and release packaging.

## Non-Goals

- Implement true server-side Device PUID rotation.
- Implement DeviceTicket rewriting, replacement, or forgery.
- Expand the tool into a broad Windows telemetry blocker beyond the current project scope.
- Merge the audited fork wholesale.
- Introduce a large product redesign that changes the CLI or core user workflow without compatibility reasons.

## Product Positioning

The updated project is a **local GDID privacy hardening tool**.

It can:

- inspect local GDID-related values;
- replace local `HKCU` copies with a generated mask value;
- disable or re-enable Connected Devices Platform behavior as configured;
- apply exact-name HOSTS file blocks for selected domains; and
- report the local state of those protections.

It cannot:

- prove unlinkability against Microsoft services;
- replace Microsoft's authoritative identity record; or
- guarantee that every relevant transmission path is blocked in all Windows configurations.

### Terminology Update

The CLI may continue to use `rotate` for compatibility, but the documentation and status model will define it as:

- **local mask rotation** when the tool is only changing local values; and
- **persistent local mask** when CDP is disabled and the tool verifies that the local value is not being immediately restored by managed services.

The term "real GDID rotation" will not be used.

## Design Principles

- Preserve the current command surface where reasonable.
- Fail closed when configuration is invalid or unsafe.
- Prefer removing weak claims over adding fragile behavior.
- Separate user-editable configuration from protected restoration state.
- Use verification to support every strong status or install claim.
- Make machine-wide changes require elevation and keep user-scoped behavior user-scoped.

## User-Facing Behavior

### Commands

The tool will continue to expose:

- `status`
- `rotate`
- `install`
- `uninstall`
- `config`
- `help`

No new top-level commands are required for v2.

### Behavioral Expectations

#### `rotate`

`rotate` will:

1. Validate configuration.
2. Refuse unsupported modes.
3. Generate a new local mask value.
4. Update the supported local registry destinations.
5. Record runtime metadata for status and recovery.
6. Verify whether the value appears to persist locally under the current CDP state.

If the current configuration leaves CDP active, the command must clearly report that the change is a local mask that may be reverted by Windows. It must not imply a durable identity change.

#### `install`

`install` will:

1. Validate configuration and environment.
2. Back up restorable state into a protected state store.
3. Apply CDP-related controls.
4. Apply HOSTS file controls.
5. Apply optional feature policies already within the project's scope.
6. Register or update the safe scheduled task model if automatic rotation is enabled.
7. Run post-apply verification and fail if the requested managed state is not achieved.

#### `uninstall`

`uninstall` will:

1. Remove scheduled tasks managed by the tool.
2. Remove the tool-managed HOSTS block.
3. Restore managed registry and service state from the protected backup where available.
4. Leave clear warnings if restoration is partial or impossible.

#### `status`

`status` must distinguish between:

- observed local identity values;
- configured protections;
- live service state;
- scheduled-task state;
- whether the current local mask is likely persistent or only temporary; and
- any unsupported or legacy settings that reduce trust in the current setup.

## Configuration Design

### Goals

The configuration model must become strict, versioned, and migration-friendly.

### Required Changes

- Add `schemaVersion`.
- Normalize enum values for keys like `rotationMode`.
- Parse booleans strictly rather than relying on loose PowerShell coercion.
- Reject unknown configuration keys.
- Preserve backward compatibility through explicit migrations, not silent acceptance.

### Proposed Configuration Shape

The user-editable `gdid-config.json` remains in the project root next to the script and optional executable. It continues to control user intent, not backups or runtime state.

Initial v2 schema:

```json
{
  "schemaVersion": 2,
  "rotationMode": "onDemand",
  "timedIntervalMin": 30,
  "blockCDP": true,
  "blockHosts": true,
  "killPhoneLink": false,
  "killOneDrive": false,
  "killStore": false,
  "killTimeline": false,
  "blockDO": false,
  "hookMethod": "registry"
}
```

### Rotation Mode Semantics

- `onDemand`: no automatic scheduled rotation.
- `timed`: current-user scheduled rotation at an interval.
- `perLogon`: current-user scheduled rotation at logon.

`perBoot` is retained as a legacy alias during migration, but it will be rewritten to `perLogon` in saved config and documentation because the underlying masked values are `HKCU`-scoped.

### Hook Method Semantics

- `registry`: supported.
- `none`: supported optional disable mode.
- `api`: deprecated immediately, rejected by v2 config validation, and removed from user-facing documentation.

## State and Runtime Data

### Separation of Concerns

The current config file stores both preferences and mutable runtime/back-up data. v2 separates them into three layers:

1. **User config**: intended settings in `gdid-config.json`.
2. **Protected state**: pre-change values needed for uninstall or rollback.
3. **Runtime state**: last applied operation details for diagnostics and status only.

### Protected State

Protected state will move to a separate machine-local location outside the user-editable config file. The exact path can be finalized in implementation, but the design target is a per-user state file under `%ProgramData%` with permissions limited to trusted principals for modification.

Protected state stores:

- original local GDID-related values that v2 manages;
- service startup configuration changed by the tool;
- whether tool-managed scheduled tasks existed before migration;
- HOSTS block ownership markers or baseline information needed for safe removal; and
- schema metadata for migration.

### Runtime State

Runtime state stores:

- last local mask value applied by the tool;
- last attempted operation;
- last successful verification timestamp; and
- last known warnings that should surface in `status`.

Runtime state is not authoritative for rollback and may be discarded without breaking uninstall.

## Scheduled Task Redesign

### Current Problem

The current task runs with highest privileges from the script location. That is hard to justify for `HKCU`-scoped mutation and increases the risk of a user-writable script path becoming an elevation boundary problem.

### New Model

Automatic local mask rotation will use a **non-elevated current-user scheduled task**.

Task characteristics:

- Task name is stable but may include a migration-safe suffix if needed.
- Principal is the current user.
- Run level is limited.
- Trigger is:
  - `AtLogOn` for `perLogon`
  - interval-based for `timed`
- No task is installed for `onDemand`.

### Migration Behavior

- On install, detect and remove legacy `GDIDRotator` tasks created by older versions.
- On install, create the current-user task only when automatic rotation is enabled.
- On uninstall, remove both legacy and v2 task names that the tool owns.

## Service and Registry Behavior

### CDP Controls

`blockCDP=true` remains a core feature, but status and install output must clearly separate:

- desired state from config;
- startup type the tool applied;
- whether services are currently stopped;
- whether local masking should be considered durable under the observed state.

The tool must verify live service state after mutation rather than assume success.

### Local Registry Masking

Local registry masking remains the supported mask mechanism.

Rules:

- Only manage documented current destinations already used by the project.
- Avoid claiming that values outside these paths are fully covered.
- Do not present cache deletion or service restart as proof of true rotation.
- Record exactly which destinations were written for accurate status and rollback.

### API Hook Mode

The DLL hook path will be removed from the supported product surface in v2.

Conservative hardening path:

- Immediately stop advertising `api` in the README and config help.
- Reject `hookMethod=api` during config validation with a clear explanation.
- Remove or isolate `gdid-hook-dll/` in a follow-up cleanup step during the v2 release cycle.

## HOSTS File Management

### Goals

Keep the existing HOSTS approach, but make it safer and more precise.

### v2 Requirements

- Preserve explicit begin/end markers.
- Ensure removal affects only tool-managed entries.
- Verify that configured domains are present after install.
- Preserve file structure and avoid unnecessary rewriting.
- Keep the default managed list small and clearly documented.

This remains a best-effort exact-name block list, not a proof of endpoint completeness.

## Output and Status Model

### Status Sections

`status` should report:

- tool version;
- config schema version;
- local observed GDID value(s);
- local mask state summary;
- CDP config and live state;
- HOSTS block state;
- scheduled-task mode and live task state;
- deprecated or unsafe config usage; and
- known limitations relevant to the current configuration.

### Example Status Language

Good:

- "Local mask applied to 2 registry destinations."
- "CDP is disabled and stopped; local mask is expected to persist locally."
- "CDP is active; the local mask may be restored by Windows-managed services."

Bad:

- "Real GDID rotated."
- "Tracking fully blocked."
- "Identity changed everywhere."

## Error Handling

### Rules

- Invalid config must fail before any mutation.
- Partial installs must report what changed and what did not.
- Verification failures must be surfaced as failures, not warnings disguised as success.
- Uninstall must attempt best-effort restoration and report incomplete recovery explicitly.
- Legacy unsupported settings must trigger actionable guidance.

### Transactional Intent

Full system transactions are not required, but mutating operations should be structured as staged changes with verification and rollback where practical:

1. Validate.
2. Capture protected state.
3. Apply one subsystem at a time.
4. Verify after each subsystem or after well-bounded groups.
5. Stop and report on first unrecoverable failure.

## Testing and Validation

### CI

Add a Windows GitHub Actions workflow that runs on push and pull request for:

- PowerShell parse checks across all `.ps1` files;
- PSScriptAnalyzer;
- smoke tests for `help`, `config`, and `status`; and
- packaging validation for release-oriented scripts where applicable.

### Local Test Assets

Add a `tests/` directory with:

- a parse-all script;
- a validation runner script;
- targeted configuration validation tests; and
- smoke-test wrappers for the main script.

### What v2 Must Verify

- no PowerShell parser errors under Windows PowerShell 5.1;
- no parser errors under PowerShell 7 when available;
- config rejects invalid booleans, enums, and unknown keys;
- legacy config migration works for expected old keys;
- scheduled task creation/removal works for each rotation mode;
- install and uninstall correctly manage only tool-owned HOSTS entries.

## Documentation Plan

### README Rewrite

The README must be rewritten to reflect:

- the local-hardening product position;
- exact command meanings;
- side effects of disabling CDP;
- the difference between local masking and authoritative identity rotation;
- supported versus deprecated config values; and
- safe install and run instructions.

### Additional Docs

Add:

- a migration note for users upgrading from v1;
- a release note describing behavior changes; and
- a validation/testing doc for maintainers.

## Migration Strategy

### User Config Migration

On first load of legacy config:

- migrate `perBoot` to `perLogon`;
- strip deprecated fields such as `lastRotation` and `originalGDID` out of user config responsibility;
- reject `hookMethod=api` and instruct the user to choose `registry` or `none`;
- preserve current feature toggles where semantics are unchanged.

### Runtime and State Migration

- If legacy backup data exists only in config, import it into protected state once during migration if it is safe to do so.
- If migration cannot trust old backup data, keep uninstall best-effort and tell the user what cannot be restored automatically.

## Release Structure

### Phase 1: Credibility Patch

- Rewrite user-facing claims.
- Add CI, parse checks, linting, and smoke tests.
- Deprecate `api` in docs and config validation.

### Phase 2: Core Hardening

- Implement strict config schema.
- Separate config, protected state, and runtime state.
- Redesign scheduled task behavior.
- Improve live verification and status output.

### Phase 3: Cleanup Release

- Remove or isolate unsupported hook artifacts.
- Add migration and release notes.
- Finalize documentation for v2 behavior.

## Risks

- Changing task semantics from `perBoot` to `perLogon` may surprise existing users.
- Rejecting `hookMethod=api` may break niche workflows that relied on undocumented behavior.
- Stronger verification may surface previously hidden failures and make installs appear "less successful" even though the tool is becoming more honest.
- State migration may be imperfect for users with hand-edited or inconsistent config files.

## Success Criteria

v2 is successful if:

- the README and help output only make claims the code can support;
- `rotate` clearly communicates local masking semantics;
- current-user automatic rotation no longer depends on elevated persistence;
- `hookMethod=api` is no longer presented as a supported feature;
- config and state handling are versioned, strict, and recoverable; and
- Windows CI consistently validates parsing, analysis, and smoke-test behavior.

## Open Decisions Resolved For Planning

The following decisions are fixed for implementation planning unless new evidence appears:

- The update remains conservative, not a wholesale fork adoption.
- CLI command names remain stable.
- `rotate` remains the command name for compatibility.
- `perBoot` becomes a legacy alias for `perLogon`.
- `api` hook mode is deprecated and rejected in v2 behavior.
- Protected state is separated from user config.
- Windows CI is required before the major update ships.

## Implementation Outline

Implementation should proceed in this order:

1. Introduce config schema validation and migration.
2. Introduce protected state and runtime state separation.
3. Redesign scheduled task management.
4. Improve status and verification behavior.
5. Rewrite README and user-facing help.
6. Add CI and test tooling.
7. Remove or isolate unsupported hook-mode artifacts.

This order reduces documentation drift and keeps the highest-risk behavioral changes behind stronger validation.
