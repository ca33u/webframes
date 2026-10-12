# Public source preparation

The public repository is a clean source export, not a mirror of the maintainer's
Git history. Prepare an archive locally; publication always requires separate
owner approval. These commands do not contact GitHub, Apple or the website,
create a checkout, commit, or upload anything.

For a committed release, use its existing tag:

```sh
python3 Tools/release/prepare_public_source.py release/public-source-TAG --ref TAG
```

Before a release is committed, review the current files as an **unpublished
preview**, including new non-ignored source files:

```sh
python3 Tools/release/prepare_public_source.py release/public-source-preview --working-tree
```

Use a new output directory each time. Both modes produce `public-source.zip`
and a manifest with per-file hashes, permissions, the base commit and the
archive SHA-256. Preview mode records that the base commit is not the complete
release source; do not publish it as a tagged release. Regenerate from the final
tag after all release changes are committed.

Some old tags deliberately fail the documentation check: `v1.1.6-11` predates
the removal of an internal-document reference in `Tools/README.md`. The local
follow-up commit `9416a7d` contains that fix. Do not change old release tags or
silently strip arbitrary documentation to make a failed export pass; select
the reviewed follow-up commit for historical comparison. Future release tags
must include the documentation fixes before export.

The script reads `git archive` in tag mode and never extracts it. It omits private
maintainer documents, local agent configuration, pairing data, runtime packages,
dependency folders, build products and signing files. Only reviewed source
roots are allowed. Symlinks and paths escaping the source folder fail the check.
Older tags have the private layout row removed from their README. The current
README already matches the public layout.

Checks reject common credential formats, personal absolute paths (generic test
placeholders are allowed), unknown binaries and missing local Markdown targets.
Errors report locations and rules, never matched credential values. These
checks are safeguards, not proof that arbitrary source contains no secrets;
review the final archive manifest and any screenshots before publication.

```sh
python3 -m unittest discover -s Tools/release -p 'test_*.py'
```

After explicit publication approval, transfer only the verified archive's
contents to the existing public repository and make one clean release commit
on top of its public main, using the maintainer's GitHub noreply identity.
Do not push private branches, tags or history. Confirm removals as well as
additions against the manifest, then run the public CI and compare the
published tree with the export. Never copy the adjacent manifest into the
public source tree. Keep the separate website repository and deploy unchanged
unless the owner explicitly includes them in the release.
