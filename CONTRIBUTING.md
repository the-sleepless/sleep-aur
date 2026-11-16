# Contributing to sleep-aur

Thanks for taking the time to contribute.

## Requirements

- Arch Linux or a derivative
- Bash 5+
- `base-devel`, `git`, `jq`, `curl`
- `shellcheck` for linting

## Working from a checkout

You can run the helper directly from the repository without installing it:

```bash
./src/sleep-aur --help
./src/sleep-aur search brave
```

To test the installer against a disposable prefix:

```bash
rm -rf /tmp/sleep-aur-test
PREFIX=/tmp/sleep-aur-test ./installer.sh --local --yes
```

The installer skips the install when the same version is already present. Remove
the test prefix, or bump `src/VERSION`, before reinstalling local changes.

## Tests

```bash
./tests/smoke.sh
```

Validate syntax:

```bash
bash -n installer.sh
bash -n src/sleep-aur
bash -n src/lib/*.sh
```

Lint:

```bash
shellcheck -x installer.sh src/sleep-aur src/lib/*.sh tests/smoke.sh
```

## Pull requests

- Keep changes focused and explain the problem they solve.
- Update the README when behavior or configuration changes.
- Add or update smoke tests when touching the helper or installer.
- Do not commit secrets, tokens, or personal information.

## Releases

Releases are cut from tags matching `src/VERSION`:

```bash
git tag v3.1.8
git push origin v3.1.8
```

