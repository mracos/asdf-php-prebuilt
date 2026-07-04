# Integration tests

Full end-to-end flows. Slow (real `mise install`, real GHCR pulls,
real PHP invocations). Gated behind `ASDF_PHP_RUN_INTEGRATION=1` so
`npm test` stays fast for the inner-loop.

Run:

```sh
ASDF_PHP_RUN_INTEGRATION=1 npm run test:integration
```

Each test file at the top does:

```bash
[[ "${ASDF_PHP_RUN_INTEGRATION:-0}" == "1" ]] || skip "set ASDF_PHP_RUN_INTEGRATION=1 to run"
```

so an unfocused run is a no-op.

Because these tests do full installs, they need:

- The plugin `mise plugin link`ed as `php`.
- Network + GHCR reachable.
- `gh auth login` done (for historical patch installs).

They leave the mise install intact on success. On failure, inspect
`~/.local/share/mise/installs/php/<version>/` for the partial state.
