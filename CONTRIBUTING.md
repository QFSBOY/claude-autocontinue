# Contributing

Thanks for considering a contribution to claude-autocontinue.

## Reporting bugs

Open an [issue](https://github.com/QFSBOY/claude-autocontinue/issues/new) with:

- macOS version (`sw_vers -productVersion`) and chip (Apple Silicon / Intel)
- Claude Code version (`claude --version`)
- Relevant lines from `~/.claude/autocontinue/watch.log`
- Output of `/autocontinue status`

## Development

The scripts are plain Bash + Python3, no build step. To iterate locally:

```bash
git clone https://github.com/QFSBOY/claude-autocontinue
cd claude-autocontinue
bash install.sh          # installs from your local checkout, not GitHub
```

After editing a script under `bin/`, re-run `install.sh` to copy the change
into `~/.claude/autocontinue/`, then re-arm (`/autocontinue`) to pick it up —
a running watcher has the old version loaded in memory until re-armed.

**Never edit a script while its watcher is mid-run.** Bash reads scripts by
byte offset as it executes; an in-place edit while a watcher process is alive
can corrupt that run. Kill the watcher first (`/autocontinue off`), edit,
reinstall, then re-arm.

### Testing

There's no formal test suite — this is a systems-integration tool (launchd,
pmset, tmux, AppleScript, a real OAuth endpoint) that's impractical to unit
test meaningfully. Instead:

```bash
bash -n bin/*.sh                # syntax check every script
/autocontinue test 30           # full live rehearsal, fires in 30s
/autocontinue status            # confirm state + logs look right
```

For changes to `install.sh` / `uninstall.sh`, test against a throwaway `HOME`
so you don't touch your real `~/.claude`:

```bash
mkdir -p /tmp/ac_test/.claude && echo '{}' > /tmp/ac_test/.claude/settings.json
HOME=/tmp/ac_test bash install.sh
# ... inspect /tmp/ac_test/.claude ...
HOME=/tmp/ac_test bash /tmp/ac_test/.claude/autocontinue/uninstall.sh
rm -rf /tmp/ac_test
```

## Pull requests

- Keep changes scoped — one logical concern per PR.
- Run `bash -n` on every script you touch before opening the PR.
- Update `README.md` if you change user-facing behavior.
- Add a line to `CHANGELOG.md` under `Unreleased`.

## Code style

- Bash: prefer `[ ]` over `[[ ]]` except where extended globs are needed
  (existing code uses `shopt -s extglob` where required).
- No dependencies beyond what macOS ships (plus optional `tmux`).
- Comments explain *why*, not *what* — keep them sparse and load-bearing.
