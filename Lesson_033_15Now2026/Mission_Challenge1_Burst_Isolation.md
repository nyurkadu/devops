# Challenge 1: The Flash-Sale Burst & Queue Isolation Incident

Lab host: **Killercoda, Ubuntu 24.04**. Jenkins runs from the WAR on port **8080** with security off (no token, no `-u`).

## The incident in one paragraph

Two upstream services triggered `lesson9-audit-worker` in the same second: the Checkout Service with `TARGET_ENV=prod` and the Staging Smoke-Test Bot with `TARGET_ENV=staging`. Both then polled **`/lastBuild/api/json`**. `lastBuild` means "the newest build of the job", not "**my** build", so both callers read the same build and the staging bot got the prod `audit_report.json`.

**The fix:** never guess. Each `buildWithParameters` call returns its **own** queue item in the `Location:` header. Follow that queue item to its **own** build number, and download the artifact from that exact build only.

## What the script must prove

| # | Requirement | How the script does it |
| --- | --- | --- |
| 1 | Simultaneous dispatch | Two `buildWithParameters?delay=0sec` POSTs back-to-back, no `sleep` |
| 2 | Independent queue pinning | `QUEUE_A` / `QUEUE_B` from the `Location:` headers, each resolved to its own `BUILD_A` / `BUILD_B` via `executable.number` |
| 2 | 404 fast-eviction fallback | If a queue item returns **404**, find the build whose **`queueId`** equals that queue item's ID. **Not** `lastBuild`, which is the original bug |
| 3 | Zero cross-talk | Download each build's own `audit_report.json` to `audit_A.json` / `audit_B.json` and assert the IDs, environments and build numbers |

"Pure Bash" here means **bash + curl + grep + sed** only, with no `python3` and no `jq`. JSON fields are pulled out with `sed`, in the same style as the lesson's Angle 3 script.

Run everything in the **same terminal tab**.

---

## Step 0: Prerequisites

```bash
export JENKINS_URL="http://localhost:8080"

# Jenkins up? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/api/json"

# Worker job present? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/job/lesson9-audit-worker/api/json"

# Worker accepts staging and prod? Expect: TARGET_ENV choices include staging and prod
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=property[parameterDefinitions[name,choices]]"; echo
```

The worker from Task Set 1 or Task Set 2 works. Both accept `dev/staging/prod` and archive `audit_report.json`.

If Jenkins returns `000` or the job is missing, follow Step 0 and the Appendix of [Mission_TaskSet1_Guided_Reinforcement.md](Mission_TaskSet1_Guided_Reinforcement.md) first.

---

## Step 1: Write `challenge5_burst_isolation.sh`

```bash
cat << 'EOF' > challenge5_burst_isolation.sh
#!/usr/bin/env bash
# challenge5_burst_isolation.sh
# Proves that two simultaneous triggers of lesson9-audit-worker are pinned to their
# own queue items, builds and artifacts (zero cross-talk).
# Pure Bash: curl + grep + sed (no python3, no jq).
# Exit code: 0 = every assertion passed, 1 = otherwise.
set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JOB="lesson9-audit-worker"
FORCE_FALLBACK="${FORCE_FALLBACK:-false}"   # true = treat queue items as evicted (404) to test the fallback
EPOCH=$(date +%s)
REQ_A="BURST-STG-${EPOCH}"
REQ_B="BURST-PRD-${EPOCH}"
PASSED=0
FAILED=0

# ---------------------------------------------------------------- helpers
pass() { echo "  [PASS] $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }
check() {   # check "<description>" <test command...>
    local desc="$1"; shift
    if "$@"; then pass "${desc}"; else fail "${desc}"; fi
}
has()     { grep -qs -- "$2" "$1"; }                     # file $1 matches regex $2
has_not() { [ -s "$1" ] && ! grep -qs -- "$2" "$1"; }    # file exists and does NOT match

# POST one parameterized build, print the queue URL from the Location: header
dispatch() {   # $1 = TARGET_ENV, $2 = REQUEST_ID
    curl -s -D - -o /dev/null -X POST \
      "${JENKINS_URL}/job/${JOB}/buildWithParameters?delay=0sec&TARGET_ENV=$1&REQUEST_ID=$2&FORCE_FAIL=false" \
      | sed -n 's/^[Ll]ocation: *\(.*\)$/\1/p' | tr -d '\r'
}

# "http://localhost:8080/queue/item/42/" -> "42"
queue_id_of() { echo "$1" | sed -n 's#.*/queue/item/\([0-9][0-9]*\)/*$#\1#p'; }

# 404 fallback: find the build that was created FROM queue item $1 (Run.queueId).
# Never use /lastBuild here - that is exactly the bug from the incident.
build_by_queue_id() {   # $1 = queue id
    curl -s -g "${JENKINS_URL}/job/${JOB}/api/json?tree=builds[number,queueId]" \
      | grep -o '{[^{}]*}' \
      | grep -E "\"queueId\":$1[,}]" \
      | sed -n 's/.*"number":\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# Resolve one queue URL to its own build number (status messages go to stderr)
resolve_build() {   # $1 = queue URL
    local url="$1" qid="" resp="" code="" body="" num="" warned=false
    qid=$(queue_id_of "${url}")
    for _ in $(seq 1 90); do
        if [ "${FORCE_FALLBACK}" = "true" ]; then
            code=404
        else
            resp=$(curl -s -g -w '\n%{http_code}' "${url}api/json?tree=cancelled,executable[number]")
            code=$(echo "${resp}" | tail -n 1)
            body=$(echo "${resp}" | sed '$d')
        fi
        case "${code}" in
            200)
                if echo "${body}" | grep -q '"cancelled":true'; then
                    echo "  [ERROR] queue item ${qid} was cancelled" >&2
                    return 1
                fi
                num=$(echo "${body}" | sed -n 's/.*"executable":{[^}]*"number":\([0-9][0-9]*\).*/\1/p')
                ;;
            404)
                if [ "${warned}" = false ]; then
                    echo "  queue item ${qid}: HTTP 404 (already evicted) -> fallback: match builds[queueId=${qid}]" >&2
                    warned=true
                fi
                num=$(build_by_queue_id "${qid}")
                ;;
        esac
        if [ -n "${num}" ]; then echo "${num}"; return 0; fi
        sleep 1
    done
    echo "  [ERROR] queue item ${qid} never resolved to a build" >&2
    return 1
}

# Wait until a build finishes, print its result (SUCCESS / FAILURE / ...)
wait_result() {   # $1 = build number
    local resp=""
    for _ in $(seq 1 90); do
        resp=$(curl -s "${JENKINS_URL}/job/${JOB}/$1/api/json?tree=building,result")
        if echo "${resp}" | grep -q '"building":false'; then
            echo "${resp}" | sed -n 's/.*"result":"\([A-Z_]*\)".*/\1/p'
            return 0
        fi
        sleep 2
    done
    echo "TIMEOUT"
}

echo "=========================================================="
echo "  CHALLENGE 5: BURST ISOLATION TEST (${JOB})"
echo "=========================================================="

# ---------------------------------------------------------------- 1. dispatch
echo "== 1. Simultaneous dispatch (no sleep between requests)"
T_START=$(date +%s%3N)
QUEUE_A=$(dispatch staging "${REQ_A}")
QUEUE_B=$(dispatch prod    "${REQ_B}")
T_END=$(date +%s%3N)
echo "  Request A: TARGET_ENV=staging REQUEST_ID=${REQ_A}"
echo "  Request B: TARGET_ENV=prod    REQUEST_ID=${REQ_B}"
echo "  QUEUE_A = ${QUEUE_A:-<none>}"
echo "  QUEUE_B = ${QUEUE_B:-<none>}"
echo "  Both requests dispatched within $((T_END - T_START)) ms"

if [ -z "${QUEUE_A}" ] || [ -z "${QUEUE_B}" ]; then
    echo "[ERROR] A trigger returned no Location: header - is Jenkins up and the job name right?"
    exit 1
fi

# ---------------------------------------------------------------- 2. queue pinning
echo "== 2. Independent queue pinning"
BUILD_A=$(resolve_build "${QUEUE_A}") || exit 1
echo "  QUEUE_A (item $(queue_id_of "${QUEUE_A}")) -> BUILD_A = #${BUILD_A}"
BUILD_B=$(resolve_build "${QUEUE_B}") || exit 1
echo "  QUEUE_B (item $(queue_id_of "${QUEUE_B}")) -> BUILD_B = #${BUILD_B}"

RESULT_A=$(wait_result "${BUILD_A}")
RESULT_B=$(wait_result "${BUILD_B}")
echo "  BUILD_A #${BUILD_A} finished: ${RESULT_A}"
echo "  BUILD_B #${BUILD_B} finished: ${RESULT_B}"

# ---------------------------------------------------------------- 3. assertions
echo "== 3. Download each build's OWN artifact"
rm -f audit_A.json audit_B.json
curl -s -f -o audit_A.json "${JENKINS_URL}/job/${JOB}/${BUILD_A}/artifact/audit_report.json" \
  || echo "  [WARN] could not download audit_report.json from build #${BUILD_A}"
curl -s -f -o audit_B.json "${JENKINS_URL}/job/${JOB}/${BUILD_B}/artifact/audit_report.json" \
  || echo "  [WARN] could not download audit_report.json from build #${BUILD_B}"
echo "  -- audit_A.json (build #${BUILD_A})"; sed 's/^/     /' audit_A.json 2>/dev/null
echo "  -- audit_B.json (build #${BUILD_B})"; sed 's/^/     /' audit_B.json 2>/dev/null

echo "== 4. Zero cross-talk assertions"
check "QUEUE_A != QUEUE_B (two distinct queue items)"        [ "${QUEUE_A}" != "${QUEUE_B}" ]
check "BUILD_A (#${BUILD_A}) != BUILD_B (#${BUILD_B})"        [ "${BUILD_A}" != "${BUILD_B}" ]
check "BUILD_A result is SUCCESS (got ${RESULT_A:-none})"     [ "${RESULT_A}" = "SUCCESS" ]
check "BUILD_B result is SUCCESS (got ${RESULT_B:-none})"     [ "${RESULT_B}" = "SUCCESS" ]
check "audit_A.json contains ${REQ_A}"                        has audit_A.json "\"request_id\": *\"${REQ_A}\""
check "audit_A.json contains \"environment\": \"staging\""    has audit_A.json '"environment": *"staging"'
check "audit_B.json contains ${REQ_B}"                        has audit_B.json "\"request_id\": *\"${REQ_B}\""
check "audit_B.json contains \"environment\": \"prod\""       has audit_B.json '"environment": *"prod"'
check "audit_A.json has no trace of ${REQ_B}"                 has_not audit_A.json "${REQ_B}"
check "audit_B.json has no trace of ${REQ_A}"                 has_not audit_B.json "${REQ_A}"

# ---------------------------------------------------------------- info: the old bug
echo "== INFO: what yesterday's /lastBuild poller would have seen"
LAST_NUM=$(curl -s "${JENKINS_URL}/job/${JOB}/lastBuild/api/json?tree=number" \
  | sed -n 's/.*"number":\([0-9][0-9]*\).*/\1/p')
LAST_REQ=$(curl -s "${JENKINS_URL}/job/${JOB}/lastBuild/artifact/audit_report.json" \
  | sed -n 's/.*"request_id": *"\([^"]*\)".*/\1/p')
echo "  /lastBuild -> #${LAST_NUM:-?} (request_id ${LAST_REQ:-?})"
echo "  Both bots polling /lastBuild would read this SAME report, so one of them gets the wrong one."

# ---------------------------------------------------------------- summary
TOTAL=$((PASSED + FAILED))
echo "=========================================================="
if [ "${FAILED}" -eq 0 ]; then
    echo "  RESULT: ZERO CROSS-TALK VERIFIED (${PASSED}/${TOTAL} assertions passed)"
else
    echo "  RESULT: ISOLATION BROKEN (${FAILED}/${TOTAL} assertions failed)"
fi
echo "=========================================================="
[ "${FAILED}" -eq 0 ] && exit 0 || exit 1
EOF

chmod +x challenge5_burst_isolation.sh
bash -n challenge5_burst_isolation.sh && echo "SYNTAX OK"
```

---

## Step 2: Run the burst test

```bash
./challenge5_burst_isolation.sh; echo "exit code: $?"
```

**Expected output.** Your queue items, build numbers and epoch will differ:

```text
==========================================================
  CHALLENGE 5: BURST ISOLATION TEST (lesson9-audit-worker)
==========================================================
== 1. Simultaneous dispatch (no sleep between requests)
  Request A: TARGET_ENV=staging REQUEST_ID=BURST-STG-1794771263
  Request B: TARGET_ENV=prod    REQUEST_ID=BURST-PRD-1794771263
  QUEUE_A = http://localhost:8080/queue/item/41/
  QUEUE_B = http://localhost:8080/queue/item/42/
  Both requests dispatched within 35 ms
== 2. Independent queue pinning
  QUEUE_A (item 41) -> BUILD_A = #9
  QUEUE_B (item 42) -> BUILD_B = #10
  BUILD_A #9 finished: SUCCESS
  BUILD_B #10 finished: SUCCESS
== 3. Download each build's OWN artifact
  -- audit_A.json (build #9)
     {
       "request_id": "BURST-STG-1794771263",
       "environment": "staging",
       ...
     }
  -- audit_B.json (build #10)
     {
       "request_id": "BURST-PRD-1794771263",
       "environment": "prod",
       ...
     }
== 4. Zero cross-talk assertions
  [PASS] QUEUE_A != QUEUE_B (two distinct queue items)
  [PASS] BUILD_A (#9) != BUILD_B (#10)
  [PASS] BUILD_A result is SUCCESS (got SUCCESS)
  [PASS] BUILD_B result is SUCCESS (got SUCCESS)
  [PASS] audit_A.json contains BURST-STG-1794771263
  [PASS] audit_A.json contains "environment": "staging"
  [PASS] audit_B.json contains BURST-PRD-1794771263
  [PASS] audit_B.json contains "environment": "prod"
  [PASS] audit_A.json has no trace of BURST-PRD-1794771263
  [PASS] audit_B.json has no trace of BURST-STG-1794771263
== INFO: what yesterday's /lastBuild poller would have seen
  /lastBuild -> #10 (request_id BURST-PRD-1794771263)
  Both bots polling /lastBuild would read this SAME report, so one of them gets the wrong one.
==========================================================
  RESULT: ZERO CROSS-TALK VERIFIED (10/10 assertions passed)
==========================================================
exit code: 0
```

The INFO block shows the original incident: `/lastBuild` points to the **prod** build, so a staging bot polling it would have read the Checkout Service's report.

The local files stay in the current folder, so you can inspect them:

```bash
cat audit_A.json audit_B.json
```

---

## Step 3: Test the 404 fast-eviction fallback

Jenkins keeps a finished ("left") queue item for about **5 minutes**, then `/queue/item/<id>/api/json` returns **404**. A fast build can finish and be evicted before a slow poller gets to it. The script then falls back to the job's build list and picks the build whose **`queueId`** matches the queue item. That build was created from **our** queue item, whatever finished last.

You don't have to wait 5 minutes. `FORCE_FALLBACK=true` makes the script treat every queue item as a 404:

```bash
FORCE_FALLBACK=true ./challenge5_burst_isolation.sh; echo "exit code: $?"
```

**Expected:** two fallback lines in step 2, and still `10/10` passed:

```text
== 2. Independent queue pinning
  queue item 43: HTTP 404 (already evicted) -> fallback: match builds[queueId=43]
  QUEUE_A (item 43) -> BUILD_A = #11
  queue item 44: HTTP 404 (already evicted) -> fallback: match builds[queueId=44]
  QUEUE_B (item 44) -> BUILD_B = #12
...
  RESULT: ZERO CROSS-TALK VERIFIED (10/10 assertions passed)
exit code: 0
```

You can see the field the fallback uses. Every build records the queue item it came from:

```bash
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,queueId]{0,4}"; echo
# -> {"_class":"...","builds":[{"_class":"...","number":12,"queueId":44},{"_class":"...","number":11,"queueId":43},...]}
```

`{0,4}` limits the list to the newest 4 builds. That's another `tree=` feature, and it's one more reason `curl` needs `-g`.

---

## Step 4 (optional): Stress variant with truly parallel builds

By default a Freestyle job **doesn't run concurrent builds**. Build B waits in the queue (blocked) until build A finishes. To make the burst fully parallel, enable concurrent builds. Jenkins then runs B in a second workspace, `lesson9-audit-worker@2`, on the second executor of the built-in node. Run the test again, then switch it back:

```bash
# Enable concurrent builds
curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script=
def job = jenkins.model.Jenkins.get().getItem('lesson9-audit-worker')
job.setConcurrentBuild(true); job.save()
println 'CONCURRENT_BUILDS: ' + job.isConcurrentBuild()"

./challenge5_burst_isolation.sh; echo "exit code: $?"

# Restore the default
curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script=
def job = jenkins.model.Jenkins.get().getItem('lesson9-audit-worker')
job.setConcurrentBuild(false); job.save()
println 'CONCURRENT_BUILDS: ' + job.isConcurrentBuild()"
```

**Expected:** `CONCURRENT_BUILDS: true`, then `10/10 assertions passed`, then `CONCURRENT_BUILDS: false`. Isolation holds because each build is pinned through its own queue item, whether the builds run one after the other or at the same time.

---

## Why the old and new approaches differ

| Question | `/lastBuild` polling (incident) | Queue pinning (this script) |
| --- | --- | --- |
| Which build do I read? | Whatever build is newest **right now** | The build created from **my** queue item |
| Two triggers in the same second | Both callers can get the same build | Each caller gets its own `executable.number` |
| Queue item already gone (404) | n/a | Match `builds[queueId]` to my queue ID, never `lastBuild` |
| How is it proven? | n/a | Distinct build numbers, own `REQUEST_ID`, own `environment`, no foreign ID in the file |

There's one more reason the two requests stay separate. Jenkins **merges** a new request into an existing queue item when the job and **all parameters** are identical. Both requests would then get the same `Location:`. Here the `REQUEST_ID` values differ (`BURST-STG-…` / `BURST-PRD-…`), so Jenkins creates two queue items. The `QUEUE_A != QUEUE_B` assertion would catch it if that ever broke.

---

## Completion checklist

| Check | Expected |
| --- | --- |
| Two `Location:` headers captured with no sleep between POSTs | `QUEUE_A` and `QUEUE_B` are different URLs |
| Each queue item resolved to its own build | `BUILD_A != BUILD_B` |
| `audit_A.json` | contains `BURST-STG-<epoch>` and `"environment": "staging"` |
| `audit_B.json` | contains `BURST-PRD-<epoch>` and `"environment": "prod"` |
| No cross-talk | neither file contains the other request's ID |
| 404 fallback (`FORCE_FALLBACK=true`) | resolves through `queueId`, still `10/10` |
| Script exit code | `0` when isolated, `1` on any failed assertion |

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `[ERROR] A trigger returned no Location: header` | Jenkins down, wrong job name, or a rejected parameter value | Redo Step 0 |
| `BUILD_A result is SUCCESS (got FAILURE)` | Worker failed. Check its console | `curl -s "${JENKINS_URL}/job/lesson9-audit-worker/<n>/consoleText"` |
| `[WARN] could not download audit_report.json` | That build archived nothing (it failed) | Fix the worker first. The assertions will show which file is missing |
| `queue item N never resolved to a build` | Queue stuck (no free executor) | Check `http://localhost:8080/queue/api/json` and the executors on the built-in node |
