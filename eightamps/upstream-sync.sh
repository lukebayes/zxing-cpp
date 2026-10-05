#!/usr/bin/env bash
# Nightly upstream sync for the eightamps fork (see EIGHTAMPS.md).
#
#  a. Fast-forward `master` to upstream and push upstream's v* tags. If master
#     cannot fast-forward, someone committed to it: fail.
#  b. Find the newest upstream release tag vX.Y.Z (not -rc). If `eightamps`
#     already contains it, there is nothing to merge (e).
#  c. Otherwise merge the tag into `eightamps` in a scratch worktree, build and
#     smoke-test the merge result, and only then push `eightamps` and the tag
#     vX.Y.Z-ea1, and create the release.
#  d. On a conflict, a failed build or a failed smoke test: push nothing, open
#     an issue titled "Upstream vX.Y.Z needs a manual merge" unless one is open.
#
# Run it in a full clone whose `origin` is the fork, with write access.
# Env:   GITEA_URL, GITEA_REPOSITORY, GITEA_TOKEN   Gitea API access
#        JOB_URL            link to the job, put in the issue
#        SIMULATE_CONFLICT  "true": skip the merge and open a "[simulated]"
#                           issue, to test the conflict path
#        UPSTREAM_URL, BASE_BRANCH, MIRROR_BRANCH, ISSUE_ASSIGNEE   overrides
#        GITEA_API_URL, BUILD_CMD, SMOKE_CMD, RELEASE_CMD           for tests
set -euo pipefail

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/zxing-cpp/zxing-cpp}
BASE_BRANCH=${BASE_BRANCH:-eightamps}
MIRROR_BRANCH=${MIRROR_BRANCH:-master}
ISSUE_ASSIGNEE=${ISSUE_ASSIGNEE:-claude-dev}
SIMULATE_CONFLICT=${SIMULATE_CONFLICT:-false}
JOB_URL=${JOB_URL:-"(no job URL)"}
api=${GITEA_API_URL:-${GITEA_URL:?}/api/v1}/repos/${GITEA_REPOSITORY:?}
auth=(-H "Authorization: token ${GITEA_TOKEN:?}")

export GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-gitea-actions} GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-gitea-actions@git.eightamps.com}
export GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME} GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}

die() { echo "error: $*" >&2; exit 1; }

# Open the "needs a manual merge" issue unless one is already open.
# $1 reason, $2 detail (markdown), $3 detail heading
report_problem() {
  local reason=$1 detail=$2 heading=$3 title existing body number note=
  title="Upstream $newest needs a manual merge"
  if [[ $SIMULATE_CONFLICT == true ]]; then
    title="[simulated] $title"
    note=$'**This is a test of the conflict path. Nothing is wrong. Do no work: close this issue.**\n\n'
  fi

  existing=$(curl -fsS "${auth[@]}" "$api/issues?state=open&type=issues&limit=100" |
    jq -r --arg t "$title" '[.[] | select(.title == $t) | .number] | first // empty')
  if [[ -n $existing ]]; then
    echo "issue #$existing ($title) is already open; not filing another"
    return 0
  fi

  body=$(cat <<EOF
Model: sonnet

> **Base branch: $BASE_BRANCH** (open the PR against \`$BASE_BRANCH\`, never \`$MIRROR_BRANCH\`)

${note}The nightly upstream sync could not release upstream \`$newest\` on its own. Nothing was pushed.

- Reason: $reason
- Job: $JOB_URL
- Upstream tag: ${UPSTREAM_URL}/releases/tag/$newest

### $heading
$detail

### What to do
Follow "When the nightly job opens an issue" in \`EIGHTAMPS.md\`.
EOF
)
  number=$(jq -n --arg title "$title" --arg body "$body" --arg who "$ISSUE_ASSIGNEE" \
    '{title: $title, body: $body, assignees: [$who]}' |
    curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' --data-binary @- "$api/issues" |
    jq -er .number)
  echo "opened issue #$number: $title"
}

# A real problem leaves the job red after the issue is filed. A simulated one
# is a test of this path, so it ends clean.
finish_problem() {
  if [[ $SIMULATE_CONFLICT == true ]]; then exit 0; fi
  exit 1
}

git remote get-url upstream >/dev/null 2>&1 && git remote set-url upstream "$UPSTREAM_URL" ||
  git remote add upstream "$UPSTREAM_URL"

# --- a. mirror upstream into master ---
git fetch --quiet --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
git fetch --quiet --tags origin
git fetch --quiet --no-tags upstream "+refs/heads/$MIRROR_BRANCH:refs/remotes/upstream/$MIRROR_BRANCH"
# No force: an upstream tag that moved fails here instead of rewriting ours.
git fetch --quiet --no-tags upstream 'refs/tags/v*:refs/tags/v*'

up=$(git rev-parse "refs/remotes/upstream/$MIRROR_BRANCH")
mirror=$(git rev-parse "refs/remotes/origin/$MIRROR_BRANCH")
if [[ $up != "$mirror" ]]; then
  git merge-base --is-ancestor "$mirror" "$up" ||
    die "$MIRROR_BRANCH cannot fast-forward to upstream: someone committed to it. Fix it by hand; nothing was pushed."
  git push --quiet origin "$up:refs/heads/$MIRROR_BRANCH"
  echo "fast-forwarded $MIRROR_BRANCH to ${up:0:12}"
fi
git push --quiet origin 'refs/tags/v*:refs/tags/v*'

# --- b. newest upstream release tag (not -rc, not our -eaN) ---
newest=$(git tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[[ -n $newest ]] || die "no upstream release tag found"
echo "newest upstream release: $newest"

if [[ $SIMULATE_CONFLICT == true ]]; then
  echo "simulating a merge conflict for $newest; no merge is attempted"
  report_problem "simulated merge conflict (no merge was attempted)" \
    '- `(simulated)`' "Conflicting files"
  finish_problem
fi

# --- e. nothing new ---
if git merge-base --is-ancestor "refs/tags/$newest" "refs/remotes/origin/$BASE_BRANCH"; then
  echo "$BASE_BRANCH already contains $newest"
  released=$(curl -fsS "${auth[@]}" "$api/releases?draft=false&limit=50" |
    jq -r --arg p "$newest-ea" '[.[] | select(.tag_name | startswith($p))] | length')
  [[ $released -gt 0 ]] ||
    die "$BASE_BRANCH contains $newest but there is no $newest-eaN release. Run the wasm-release workflow with tag $newest-ea1."
  echo "release $newest-eaN exists; nothing to do"
  exit 0
fi

# --- c. merge in a scratch worktree ---
ea_tag="$newest-ea1"
git rev-parse -q --verify "refs/tags/$ea_tag" >/dev/null &&
  die "tag $ea_tag exists but $BASE_BRANCH does not contain $newest"

scratch=$(mktemp -d)
trap 'git worktree remove --force "$scratch/wt" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
git worktree add --quiet --detach "$scratch/wt" "refs/remotes/origin/$BASE_BRANCH"
cd "$scratch/wt"

if ! git merge --no-edit -m "Merge upstream $newest into $BASE_BRANCH" "refs/tags/$newest" >"$scratch/merge.log" 2>&1; then
  files=$(git diff --name-only --diff-filter=U | sed 's/.*/- `&`/')
  git merge --abort || true
  cat "$scratch/merge.log"
  report_problem "merge conflict" "${files:-"- (none listed; see the job log)"}" "Conflicting files"
  finish_problem
fi

build_cmd=${BUILD_CMD:-"$scratch/wt/eightamps/build-wasm.sh"}
smoke_cmd=${SMOKE_CMD:-"node $scratch/wt/eightamps/smoke-test.js"}
release_cmd=${RELEASE_CMD:-"$scratch/wt/eightamps/release.sh"}
dist=$scratch/dist

stage_failed() {
  local stage=$1 log=$2
  tail -n 40 "$log"
  report_problem "$stage" "$(printf '```\n%s\n```' "$(tail -n 40 "$log")")" "Log tail"
  finish_problem
}

# shellcheck disable=SC2086 # the *_CMD variables hold a command and its arguments
RELEASE_TAG=$ea_tag $build_cmd "$dist" >"$scratch/build.log" 2>&1 || stage_failed "build failed" "$scratch/build.log"
# shellcheck disable=SC2086
$smoke_cmd "$dist" >"$scratch/smoke.log" 2>&1 || stage_failed "smoke test failed" "$scratch/smoke.log"
cat "$scratch/smoke.log"

# Tag and branch go up together; a release workflow is not relied on to fire.
git tag "$ea_tag"
git push --quiet --atomic origin "HEAD:refs/heads/$BASE_BRANCH" "refs/tags/$ea_tag"
echo "pushed $BASE_BRANCH and $ea_tag"

# shellcheck disable=SC2086
$release_cmd "$ea_tag" "$dist" ||
  die "$BASE_BRANCH and $ea_tag are pushed but the release failed. Run the wasm-release workflow with tag $ea_tag."
