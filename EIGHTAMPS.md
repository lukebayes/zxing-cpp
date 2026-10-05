# eightamps fork of zxing-cpp

This repo is a fork of <https://github.com/zxing-cpp/zxing-cpp>. We track upstream every night and build our own WebAssembly (WASM) barcode reader from it on our infra. Everything we add lives in `.gitea/`, `eightamps/`, this file, and the vendored `wrappers/wasm/third_party/stb/`.

`eightamps/bom` fetches the newest non-prerelease `*-ea*` release of this repo at build time. It uses `zxing_reader.js` and `zxing_reader.wasm` from that release. When bom is pushed to integration, it always gets the latest internal build.

## Branches

| Branch | What it is | Who changes it |
|---|---|---|
| `master` | An exact copy of upstream `master`. | Only the nightly job. It fast-forwards. Nobody commits to it. |
| `eightamps` | An upstream release tag, plus our CI, plus our patches. Releases are built from here. | PRs (rebase-merge), and the nightly job. |

If `master` cannot fast-forward to upstream, someone committed to it. The nightly job fails and pushes nothing. Reset `master` to upstream by hand.

The default branch of the repo must be `eightamps`. Gitea runs `schedule` workflows from the default branch only.

## Release names

A release is named `vX.Y.Z-eaN`:

- `vX.Y.Z` is the upstream release it is built on.
- `N` starts at `1`. It goes up each time we release the same upstream version again with our own patches.

Release tags with `-rc` are never merged or released.

Each release has 4 assets:

| Asset | Content |
|---|---|
| `zxing_reader.js` | The Emscripten loader. |
| `zxing_reader.wasm` | The reader. Build target `zxing_reader` of `wrappers/wasm`, readers only, environment `web,worker`. |
| `VERSION` | Where the build came from: release tag, upstream tag, commit, stb commit, emsdk image digest, flags. |
| `SHA256SUMS` | The sha256 of the other 3 files. |

The build is reproducible: the same commit gives the same files. It runs in `docker.io/emscripten/emsdk:4.0.10`, pinned by digest, through `eightamps/build-wasm.sh`. Nothing is fetched from GitHub at build time. The `stb_image.h` header is vendored.

## The nightly job

`.gitea/workflows/upstream-sync.yml` runs at 03:17 UTC and on `workflow_dispatch`. The logic is in `eightamps/upstream-sync.sh`.

1. Fast-forward `master` to upstream. Push upstream's `v*` tags.
2. Find the newest upstream release tag `vX.Y.Z`.
3. If `eightamps` already contains it: exit 0. No release. (If no `vX.Y.Z-eaN` release exists, the job fails and says to run `wasm-release`.)
4. Otherwise merge the tag into `eightamps` in a scratch worktree. Build and smoke-test the result.
5. If all steps pass: push `eightamps` and the tag `vX.Y.Z-ea1`, then create the release. All of this happens in the same job. A tag pushed with the Actions token may not start another workflow, so the job does not wait for one.
6. If the merge conflicts, or the build or the smoke test fails: push nothing. Open the issue below.

To test the conflict path, dispatch the job with `simulate_conflict` set to `true`. It skips the merge and opens an issue titled `[simulated] Upstream vX.Y.Z needs a manual merge`. Close that issue after the test.

The tests for the whole sync logic need no network and no podman:

```
eightamps/test-upstream-sync.sh
```

## When the nightly job opens an issue

The issue is titled `Upstream vX.Y.Z needs a manual merge`. It is assigned to `claude-dev`. It names the reason (conflict, failed build, failed smoke test) and links the job. The job opens at most one such issue at a time. While it is open, the job stays red every night.

1. Create a branch from `eightamps`. Merge the tag: `git fetch origin --tags && git merge vX.Y.Z`.
2. Resolve the conflicts. Keep our patches unless upstream fixed the same problem.
3. Build and test it: `eightamps/build-wasm.sh`, then the smoke test (see below).
4. Open a PR into `eightamps`. Never into `master`.
5. **Merge that PR with the merge-commit style, not rebase-merge.** A rebase rewrites upstream's commits. Then `eightamps` does not contain the upstream tag, and the nightly job tries again.
6. After the merge, dispatch `wasm-release` on `eightamps` with tag `vX.Y.Z-ea1`.
7. Close the issue.

## Our own patches

A merge to `eightamps` that changes anything outside `.gitea/` and `eightamps/` gets a manual release. The nightly job only releases upstream merges, so for our own patches run `wasm-release` yourself:

1. Merge the PR into `eightamps` (rebase-merge is fine for our own patches).
2. Dispatch `wasm-release` on the `eightamps` branch. Set `tag` to the next number for that upstream version, for example `v3.1.1-ea2`.

If the tag does not exist yet, the workflow creates it on the tip of `eightamps`. It refuses a tag that is not built on its upstream release, and it refuses to create a release for a tag that already has one. Use the `dry_run` input to build, smoke-test and rehearse the release without a tag or a release. The rehearsal makes a draft release, uploads the 4 assets and deletes the draft.

## Build and test locally

You need `podman`. Node is optional.

```
eightamps/build-wasm.sh                       # writes eightamps/dist/
node eightamps/smoke-test.js                  # with node on the host
```

Without node on the host, run the smoke test in the emsdk image, which has node:

```
podman run --rm -v "$PWD/eightamps:/e:ro,Z" \
  docker.io/emscripten/emsdk:4.0.10@sha256:90b757eb11fa9a0e3ce4d2d9f76d932a56018e4accc37b5a28b2783751e60eb7 \
  node /e/smoke-test.js /e/dist
```

The build packs the committed files (`git archive HEAD`). Commit your change before you build.

## Files

| Path | Purpose |
|---|---|
| `.gitea/workflows/wasm-release.yml` | Build, smoke-test and release one tag. `workflow_dispatch` with input `tag`. |
| `.gitea/workflows/upstream-sync.yml` | The nightly job. |
| `eightamps/build-wasm.sh` | The reproducible build. Writes `VERSION` and `SHA256SUMS`. |
| `eightamps/smoke-test.js` | Decodes a Digi-Key Data Matrix fixture with the built module. Exit 1 on a miss. |
| `eightamps/release.sh` | Creates the Gitea release and uploads the 4 assets. |
| `eightamps/upstream-sync.sh` | The nightly logic. |
| `eightamps/test-upstream-sync.sh` | Tests for the sync and release scripts. |
| `wrappers/wasm/third_party/stb/` | Vendored `stb_image.h` at a pinned commit, with its license. |
