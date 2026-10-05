#!/usr/bin/env bash
# Create the Gitea release for TAG with the four build assets.
#
# The release starts as a draft and is published only after every asset has
# uploaded. If anything fails, the draft is deleted, so a failed run leaves no
# half-made release. The script refuses to touch a tag that already has a
# release: it never creates a duplicate.
#
# With --rehearse the script does everything except publish: it creates the
# draft, uploads the assets, checks them, and deletes the draft. The wasm-release
# dry run uses it to prove the token can release without leaving a release.
#
# Usage: eightamps/release.sh [--rehearse] TAG DIST_DIR
# Env:   GITEA_URL         e.g. https://git.eightamps.com
#        GITEA_REPOSITORY  org/repo
#        GITEA_TOKEN       token with write access to releases
#        GITEA_API_URL     override for $GITEA_URL/api/v1 (tests)
set -euo pipefail

rehearse=false
if [[ ${1:-} == --rehearse ]]; then rehearse=true; shift; fi
tag=${1:?usage: release.sh [--rehearse] TAG DIST_DIR}
dist=${2:?usage: release.sh [--rehearse] TAG DIST_DIR}
api=${GITEA_API_URL:-${GITEA_URL:?}/api/v1}/repos/${GITEA_REPOSITORY:?}
auth=(-H "Authorization: token ${GITEA_TOKEN:?}")
assets=(zxing_reader.js zxing_reader.wasm VERSION SHA256SUMS)

for name in "${assets[@]}"; do
  [[ -s $dist/$name ]] || { echo "error: missing or empty asset: $dist/$name" >&2; exit 1; }
done

code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "$api/releases/tags/$tag")
case $code in
  404) ;;
  200) echo "error: a release for $tag already exists; not creating a duplicate" >&2; exit 1 ;;
  *) echo "error: checking for an existing $tag release returned HTTP $code" >&2; exit 1 ;;
esac

body=$(printf 'Internal WASM build of zxing-cpp `%s` for eightamps/bom.\n\n```\n%s\n```\n\n```\n%s\n```\n' \
  "${tag%-ea*}" "$(cat "$dist/VERSION")" "$(cat "$dist/SHA256SUMS")")

id=$(jq -n --arg tag "$tag" --arg body "$body" \
  '{tag_name: $tag, name: $tag, body: $body, draft: true, prerelease: false}' |
  curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' --data-binary @- "$api/releases" |
  jq -er .id)

drop_draft() {
  echo "error: release $tag failed; deleting the draft" >&2
  curl -sS -X DELETE "${auth[@]}" "$api/releases/$id" >/dev/null || true
}
trap drop_draft ERR

for name in "${assets[@]}"; do
  curl -fsS -X POST "${auth[@]}" -F "attachment=@$dist/$name" "$api/releases/$id/assets?name=$name" >/dev/null
  echo "uploaded $name"
done

count=$(curl -fsS "${auth[@]}" "$api/releases/$id" | jq -er '.assets | length')
[[ $count -eq ${#assets[@]} ]] || { echo "error: release has $count assets, expected ${#assets[@]}" >&2; false; }

if $rehearse; then
  curl -fsS -X DELETE "${auth[@]}" "$api/releases/$id" >/dev/null
  trap - ERR
  echo "rehearsal ok: created a draft $tag with ${#assets[@]} assets, then deleted it"
  exit 0
fi

url=$(jq -n '{draft: false}' |
  curl -fsS -X PATCH "${auth[@]}" -H 'Content-Type: application/json' --data-binary @- "$api/releases/$id" |
  jq -er .html_url)
trap - ERR
echo "released $tag: $url"
