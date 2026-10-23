# Contributing to Meterlark

## Branches and pull requests

Develop changes on a feature branch based on the latest `main`, then open a pull
request targeting `main`. Agents use the `codex/` branch prefix. Push the feature
branch to `xingyu-shi/meterlark`; direct pushes to `main` are blocked, including
pushes made with an administrator account.

Normal merging requires at least one approving review from another collaborator
with write access. New reviewable commits dismiss earlier approvals, so the
approval must cover the current changes. A name in GitHub's Contributors list
does not itself grant review or merge permissions.

Collaborators with Write, Maintain, or Admin access may deliberately bypass the
approval requirement and merge through the pull request. This exception applies
only to pull requests: it does not permit direct pushes, force pushes, or deletion
of `main`. Here, **force merge** means using the PR's explicit bypass action;
it never means `git push --force` to `main`.

Check the PR diff and CI results before merging. Automation must leave a PR for
review unless a human contributor explicitly requests bypassing review for that
specific PR. A token's bypass permission is not an instruction to use it.

The enforced configuration is visible in the repository's
[main ruleset](https://github.com/xingyu-shi/meterlark/rules/25752245).

## Releases

Create release tags from commits already merged into `main`. Follow the
[release checks](docs/release-checklist.md) before publishing source or binaries.
Do not tag an unmerged feature branch to publish a release.
