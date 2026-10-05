#!/usr/bin/env bash
# Tests for upstream-sync.sh and release.sh. They run against throwaway local
# git repos (an "upstream" and an "origin") and a stub Gitea API, so they need
# no network and no podman. Requires git, jq, curl and python3.
#
# Usage: eightamps/test-upstream-sync.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
S=$T/state STUB=$T/stubs
mkdir -p "$S" "$STUB"
stub_pid=
trap '[[ -n $stub_pid ]] && kill "$stub_pid" 2>/dev/null; rm -rf "$T"' EXIT

export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch master
export STUB_STATE=$S

# --- stub Gitea API: records every request, serves issues and releases ---
cat > "$T/stub.py" <<'EOF'
import json, os, re, sys, http.server

state = sys.argv[1]

def load(name, default):
    try:
        with open(os.path.join(state, name)) as f:
            return json.load(f)
    except FileNotFoundError:
        return default

def save(name, value):
    with open(os.path.join(state, name), 'w') as f:
        json.dump(value, f)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, obj=None):
        data = json.dumps({} if obj is None else obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, body=b''):
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = body.decode('utf-8', 'replace')[:200]
        with open(os.path.join(state, 'requests.log'), 'a') as f:
            f.write(json.dumps({'method': self.command, 'path': self.path, 'body': parsed}) + '\n')

    def body(self):
        return self.rfile.read(int(self.headers.get('Content-Length') or 0))

    def do_GET(self):
        self.record()
        path = self.path.split('?')[0]
        if path.endswith('/issues'):
            self.reply(200, load('issues.json', []))
        elif path.endswith('/releases'):
            self.reply(200, load('releases.json', []))
        elif '/releases/tags/' in path:
            found = [r for r in load('releases.json', []) if r['tag_name'] == path.rsplit('/', 1)[1]]
            self.reply(200, found[0]) if found else self.reply(404)
        elif re.search(r'/releases/\d+$', path):
            self.reply(200, {'assets': load('assets.json', [])})
        else:
            self.reply(404)

    def do_POST(self):
        body = self.body()
        self.record(body)
        path = self.path.split('?')[0]
        if path.endswith('/issues'):
            issues = load('issues.json', [])
            issues.append({'number': len(issues) + 1, 'title': json.loads(body)['title']})
            save('issues.json', issues)
            self.reply(201, {'number': len(issues)})
        elif path.endswith('/releases'):
            self.reply(201, {'id': 7})
        elif path.endswith('/assets'):
            assets = load('assets.json', [])
            assets.append(self.path.split('name=')[1])
            save('assets.json', assets)
            self.reply(201)
        else:
            self.reply(404)

    def do_PATCH(self):
        self.record(self.body())
        self.reply(200, {'html_url': 'http://stub/releases/7'})

    def do_DELETE(self):
        self.record()
        self.reply(204)

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(state, 'port'), 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 "$T/stub.py" "$S" &
stub_pid=$!
for _ in $(seq 50); do [[ -s $S/port ]] && break; sleep 0.1; done
port=$(<"$S/port")
export GITEA_API_URL=http://127.0.0.1:$port GITEA_REPOSITORY=eightamps/zxing-cpp GITEA_TOKEN=test

# --- stand-ins for the build, smoke test and release steps ---
cat > "$STUB/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "$RELEASE_TAG $*" >> "$STUB_STATE/build.log"
if [[ -n ${STUB_BUILD_FAIL:-} ]]; then echo "stub: compile error"; exit 1; fi
mkdir -p "$1"
for f in zxing_reader.js zxing_reader.wasm VERSION SHA256SUMS; do echo "$f" > "$1/$f"; done
EOF
cat > "$STUB/smoke.sh" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${STUB_SMOKE_FAIL:-} ]]; then echo "stub: decode miss"; exit 1; fi
echo "stub: smoke ok"
EOF
cat > "$STUB/release.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_STATE/release.log"
EOF
chmod +x "$STUB"/*.sh

# --- helpers ---
fails=0
ok() { echo "ok   - $1"; }
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else echo "FAIL - $desc"; fails=$((fails + 1)); fi; }
not() { ! "$@"; }
jqe() { jq -e "$@" >/dev/null; }
og() { git --git-dir="$T/o.git" "$@"; }
ug() { git --git-dir="$T/u.git" "$@"; }
posts() { jq -s "[.[] | select(.method == \"POST\" and (.path | split(\"?\")[0] | endswith(\"$1\")))]" "$S/requests.log" 2>/dev/null || echo '[]'; }
n_posts() { posts "$1" | jq length; }
out_has() { grep -q -- "$1" "$T/out.log"; }

# upstream: v1.0.0. origin: a mirror of it plus an eightamps branch with our own
# commit that changes a.txt (so upstream edits to a.txt conflict).
setup() {
  rm -rf "$T/u.git" "$T/o.git" "$T/up" "$T/me" "$S"/*.json "$S/requests.log" "$S"/*.log
  git init -q --bare "$T/u.git"
  git clone -q "$T/u.git" "$T/up" 2>/dev/null
  (cd "$T/up" && printf 'one\n' > a.txt && printf 'b1\n' > b.txt && git add . && git commit -qm c1 &&
    git tag v1.0.0 && git push -q origin master --tags)
  git clone -q --bare "$T/u.git" "$T/o.git"
  git clone -q "$T/o.git" "$T/me"
  (cd "$T/me" && git checkout -q -b eightamps v1.0.0 && printf 'ours\n' > a.txt && mkdir eightamps &&
    echo x > eightamps/x && git add . && git commit -qm ours && git push -q origin eightamps)
  echo '[{"tag_name": "v1.0.0-ea1", "draft": false}]' > "$S/releases.json"
  : > "$S/requests.log"
}

# up FILE CONTENT [TAG]: commit to upstream master, optionally tag it
up() {
  (cd "$T/up" && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm "up $1" &&
    { [[ -z ${3:-} ]] || git tag "$3"; } && git push -q origin master --tags)
}

# run_sync [ENV=VALUE...]: run upstream-sync.sh in a fresh clone of origin
run_sync() {
  rm -rf "$T/run" "$T/out.log"
  git clone -q "$T/o.git" "$T/run"
  (cd "$T/run" && env UPSTREAM_URL="$T/u.git" JOB_URL=http://job/1 \
    BUILD_CMD="$STUB/build.sh" SMOKE_CMD="$STUB/smoke.sh" RELEASE_CMD="$STUB/release.sh" \
    "$@" "$here/upstream-sync.sh") > "$T/out.log" 2>&1
}

echo "== nothing new upstream, release exists =="
setup
before=$(og rev-parse eightamps)
run_sync; rc=$?
check "exits 0" [ $rc -eq 0 ]
check "eightamps untouched" [ "$(og rev-parse eightamps)" = "$before" ]
check "no issue opened" [ "$(n_posts /issues)" -eq 0 ]
check "no release created" [ ! -e "$S/release.log" ]

echo "== nothing new upstream, but no release for the tag =="
setup
echo '[]' > "$S/releases.json"
run_sync; rc=$?
check "fails loudly" [ $rc -ne 0 ]
check "says to run wasm-release" out_has 'Run the wasm-release workflow with tag v1.0.0-ea1'

echo "== master fast-forwards and new tags are mirrored =="
setup
up c.txt c1 v1.1.0-rc1
run_sync; rc=$?
check "exits 0" [ $rc -eq 0 ]
check "master equals upstream master" [ "$(og rev-parse master)" = "$(ug rev-parse master)" ]
check "rc tag is mirrored" [ -n "$(og tag -l v1.1.0-rc1)" ]
check "rc tag is not released" [ ! -e "$S/release.log" ]

echo "== clean merge of a new release =="
setup
up b.txt b2 v1.1.0
up c.txt c1 v1.2.0-rc1
before=$(og rev-parse eightamps)
run_sync; rc=$?
check "exits 0" [ $rc -eq 0 ]
check "eightamps moved" [ "$(og rev-parse eightamps)" != "$before" ]
check "eightamps contains v1.1.0" og merge-base --is-ancestor v1.1.0 eightamps
check "eightamps keeps our commit" og merge-base --is-ancestor "$before" eightamps
check "the rc commit is not merged" not og cat-file -e eightamps:c.txt
check "tag v1.1.0-ea1 is on the eightamps tip" [ "$(og rev-parse v1.1.0-ea1)" = "$(og rev-parse eightamps)" ]
check "master equals upstream master" [ "$(og rev-parse master)" = "$(ug rev-parse master)" ]
check "upstream tag v1.1.0 was pushed" [ -n "$(og tag -l v1.1.0)" ]
check "built with RELEASE_TAG=v1.1.0-ea1" grep -q '^v1.1.0-ea1 ' "$S/build.log"
check "released v1.1.0-ea1" grep -q '^v1.1.0-ea1 ' "$S/release.log"
check "no issue opened" [ "$(n_posts /issues)" -eq 0 ]

echo "== merge conflict =="
setup
up a.txt theirs v1.1.0
before=$(og rev-parse eightamps)
run_sync; rc=$?
check "job fails" [ $rc -eq 1 ]
check "eightamps untouched" [ "$(og rev-parse eightamps)" = "$before" ]
check "no -ea tag pushed" [ -z "$(og tag -l 'v1.1.0-ea*')" ]
check "no build or release" [ ! -e "$S/build.log" ] && [ ! -e "$S/release.log" ]
check "1 issue opened" [ "$(n_posts /issues)" -eq 1 ]
issue=$(posts /issues | jq '.[0].body')
check "issue title" [ "$(jq -r .title <<<"$issue")" = "Upstream v1.1.0 needs a manual merge" ]
check "issue is assigned to claude-dev" [ "$(jq -r '.assignees[0]' <<<"$issue")" = "claude-dev" ]
check "issue lists the conflicting file" jqe '.body | contains("`a.txt`")' <(printf '%s' "$issue")
check "issue links the job" jqe '.body | contains("http://job/1")' <(printf '%s' "$issue")
check "issue names the base branch" jqe '.body | contains("Base branch: eightamps")' <(printf '%s' "$issue")
run_sync; rc=$?
check "second run still fails" [ $rc -eq 1 ]
check "second run files no duplicate issue" [ "$(n_posts /issues)" -eq 1 ]

echo "== simulated conflict =="
setup
before=$(og rev-parse eightamps)
run_sync SIMULATE_CONFLICT=true; rc=$?
check "exits 0" [ $rc -eq 0 ]
check "eightamps untouched" [ "$(og rev-parse eightamps)" = "$before" ]
check "opens a [simulated] issue" [ "$(posts /issues | jq -r '.[0].body.title')" = "[simulated] Upstream v1.0.0 needs a manual merge" ]
run_sync SIMULATE_CONFLICT=true
check "a second simulated run files no duplicate" [ "$(n_posts /issues)" -eq 1 ]

echo "== failed build =="
setup
up b.txt b2 v1.1.0
before=$(og rev-parse eightamps)
run_sync STUB_BUILD_FAIL=1; rc=$?
check "job fails" [ $rc -eq 1 ]
check "eightamps untouched" [ "$(og rev-parse eightamps)" = "$before" ]
check "no -ea tag pushed" [ -z "$(og tag -l 'v1.1.0-ea*')" ]
check "issue opened with the build log" jqe '.[0].body.body | contains("build failed") and contains("compile error")' <(posts /issues)
check "no release" [ ! -e "$S/release.log" ]

echo "== failed smoke test =="
setup
up b.txt b2 v1.1.0
before=$(og rev-parse eightamps)
run_sync STUB_SMOKE_FAIL=1; rc=$?
check "job fails" [ $rc -eq 1 ]
check "eightamps untouched" [ "$(og rev-parse eightamps)" = "$before" ]
check "issue opened with the smoke log" jqe '.[0].body.body | contains("smoke test failed") and contains("decode miss")' <(posts /issues)
check "no release" [ ! -e "$S/release.log" ]

echo "== someone committed to master =="
setup
(cd "$T/me" && git checkout -q master && echo hand > hand.txt && git add . && git commit -qm "by hand" && git push -q origin master)
up b.txt b2 v1.1.0
mirror=$(og rev-parse master)
run_sync; rc=$?
check "job fails" [ $rc -ne 0 ]
check "says master cannot fast-forward" out_has 'cannot fast-forward'
check "master untouched" [ "$(og rev-parse master)" = "$mirror" ]
check "no -ea tag pushed" [ -z "$(og tag -l 'v1.1.0-ea*')" ]

echo "== release.sh =="
dist=$T/dist
mkdir -p "$dist"
for f in zxing_reader.js zxing_reader.wasm VERSION SHA256SUMS; do echo "$f" > "$dist/$f"; done
setup
echo '[]' > "$S/releases.json"
out=$("$here/release.sh" v1.1.0-ea1 "$dist" 2>&1); rc=$?
check "release.sh exits 0" [ $rc -eq 0 ]
check "created a draft release" [ "$(posts /releases | jq -r '.[0].body.draft')" = "true" ]
check "uploaded 4 assets" [ "$(n_posts /assets)" -eq 4 ]
check "published it" jqe -s 'map(select(.method == "PATCH" and .body.draft == false)) | length == 1' "$S/requests.log"
echo '[{"tag_name": "v1.1.0-ea1", "draft": false}]' > "$S/releases.json"
: > "$S/requests.log"
"$here/release.sh" v1.1.0-ea1 "$dist" >/dev/null 2>&1; rc=$?
check "refuses a duplicate release" [ $rc -ne 0 ]
check "creates nothing for a duplicate" [ "$(n_posts /releases)" -eq 0 ]
rm "$dist/SHA256SUMS"
echo '[]' > "$S/releases.json"
: > "$S/requests.log"
"$here/release.sh" v1.2.0-ea1 "$dist" >/dev/null 2>&1; rc=$?
check "refuses a missing asset" [ $rc -ne 0 ]
check "creates nothing for a missing asset" [ "$(n_posts /releases)" -eq 0 ]

echo
if [[ $fails -eq 0 ]]; then echo "all tests passed"; else echo "$fails test(s) FAILED"; fi
[[ $fails -eq 0 ]]
