# git-branch-sweeper

Safely prune merged branches (local + remote). Dry-run by default.

## Install
Download `git-branch-sweeper.sh` and make it executable:

```bash
chmod +x git-branch-sweeper.sh
````

## Usage

Dry-run:

```bash
./git-branch-sweeper.sh
```

Apply deletions:

```bash
./git-branch-sweeper.sh --apply
```

Change pattern / bases:

```bash
./git-branch-sweeper.sh --pattern "feature/*" --base main --base dev
```

Remote name:

```bash
./git-branch-sweeper.sh --remote upstream
```

Local only / Remote only:

```bash
./git-branch-sweeper.sh --local-only
./git-branch-sweeper.sh --remote-only
```

## Notes

* `--pattern` is a bash glob, not a regex.
* Remote symbolic refs like `origin/HEAD -> origin/main` are ignored.
* Protected branches are never deleted.