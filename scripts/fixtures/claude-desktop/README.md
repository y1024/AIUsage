# Claude Desktop 3P schema fixtures

These fixtures capture the JSON *shape* observed on macOS with Claude Desktop
`1.12603.1` on 2026-07-21. They are deliberately synthetic:

- every credential, endpoint, profile ID, account ID, path, and display name is
  replaced with a fixed placeholder;
- no file is copied from the user's live Claude directories;
- booleans and container shapes are retained because they affect merge and
  round-trip behavior;
- all four observed live files used POSIX mode `0600`.

Observed locations:

```text
~/Library/Application Support/Claude/claude_desktop_config.json
~/Library/Application Support/Claude-3p/claude_desktop_config.json
~/Library/Application Support/Claude-3p/configLibrary/_meta.json
~/Library/Application Support/Claude-3p/configLibrary/<profile-id>.json
```

Compatibility rules derived from the fixtures:

1. Both deployment config files are JSON objects. A missing file is treated as
   an empty object when applying a profile, but restore must preserve the fact
   that it did not exist.
2. Unknown preferences and account-keyed dictionaries must survive a merge.
3. `_meta.json` may contain several profiles. AIUsage may update only its own
   entry and `appliedId`; other entries keep their order and fields.
4. A first-party profile can contain only `inferenceProvider`.
5. A mapped Gateway profile contains a local API key and an array of model
   objects. `supports1m` is optional per model.
6. `inferenceGatewayAuthScheme` and `labelOverride` were not present in the
   sampled local mapped profile, so both must be capability-tested rather than
   assumed from third-party examples.

Run the schema regression with:

```bash
swift scripts/ClaudeDesktopFixtureRegression.swift
```
