# Challenge 2: The Silent Latency Degradation & Health Gate

Lab host: **Killercoda, Ubuntu 24.04**. Jenkins runs from the WAR on port **8080** with security off (no token, no `-u`).

## The incident in one paragraph

An infrastructure slowdown made `lesson9-audit-worker` take **25 s** per build. The script still exited `0`, so Jenkins reported `"result":"SUCCESS"`, and the release pipeline only looked at `result`. Downstream APIs timed out, and nothing in the pipeline caught the regression.

**The fix:** a pre-release gate that checks how **long** the fresh build took and how **healthy** the recent builds are, not only whether the fresh build passed.

## The gate's rules

| # | Check | Rule | REST query used |
| --- | --- | --- | --- |
| 1 | Dispatch & measure | Fresh `TARGET_ENV=prod` build, `REQUEST_ID=SLA-<epoch>`, `delay=0sec`, pinned through its `Location:` queue item | `POST .../buildWithParameters` |
| 2 | SLA: result | `result` = `SUCCESS` | `/<BUILD_NUM>/api/json?tree=number,result,duration` |
| 2 | SLA: latency | `duration` < **8000 ms** | (same query) |
| 3 | Sliding-window health | At least **3 of the last 5** builds = `SUCCESS` | `/api/json?tree=builds[number,result,duration]{0,5}` |
| - | Decision | **PROMOTION APPROVED** only if rules 2 and 3 all pass, otherwise **PROMOTION BLOCKED** with the reasons | - |

**"Without downloading full build histories":** `tree=` limits the response to three fields per build, and `{0,5}` makes Jenkins return only the 5 newest builds. Jenkins does the filtering, so only a few hundred bytes are transferred.

"Pure Bash" here means **bash + curl + grep + sed** only, with no `python3` and no `jq`.

`duration` is **execution time only**, in milliseconds, from build start to build end. Time spent waiting in the queue isn't included. With `delay=0sec` that time is close to zero anyway.

Run everything in the **same terminal tab**.

---

## Step 0: Prerequisites

```bash
export JENKINS_URL="http://localhost:8080"

# Jenkins up? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/api/json"

# Worker present? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/job/lesson9-audit-worker/api/json"

# Preview the 5-build window the gate will audit
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,result,duration]{0,5}"; echo
```

If Jenkins returns `000` or the job is missing, follow [Appendix A of Mission_TaskSet1_Guided_Reinforcement.md](Mission_TaskSet1_Guided_Reinforcement.md#appendix-a-prepare-the-environment-do-this-first) first.

---

## Step 1: Write `challenge6_sla_audit.sh`

```bash
cat << 'EOF' > challenge6_sla_audit.sh
#!/usr/bin/env bash
# challenge6_sla_audit.sh
# Pre-release health & SLA gate for lesson9-audit-worker.
#   1. Dispatch a fresh prod build and pin it through its Location: queue item
#   2. SLA: result == SUCCESS and duration < SLA_MAX_MS (default 8000 ms)
#   3. Health: >= MIN_HEALTHY SUCCESS among the last WINDOW builds ({0,5} slice)
# Pure Bash: curl + grep + sed (no python3, no jq).
# Exit code: 0 = PROMOTION APPROVED, 1 = PROMOTION BLOCKED.
set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JOB="lesson9-audit-worker"
SLA_MAX_MS="${SLA_MAX_MS:-8000}"
WINDOW=5
MIN_HEALTHY=3
REQUEST_ID="SLA-$(date +%s)"
REASONS=()

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; }
json_num() { sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p"; }       # stdin JSON -> numeric field $1
json_str() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }        # stdin JSON -> string field $1

echo "=========================================================="
echo "  CHALLENGE 6: PRE-RELEASE HEALTH & SLA GATE (${JOB})"
echo "=========================================================="

# ---------------------------------------------------------------- 1. dispatch & measure
echo "== 1. Dispatch & measure"
QUEUE_URL=$(curl -s -D - -o /dev/null -X POST \
  "${JENKINS_URL}/job/${JOB}/buildWithParameters?delay=0sec&TARGET_ENV=prod&REQUEST_ID=${REQUEST_ID}&FORCE_FAIL=false" \
  | sed -n 's/^[Ll]ocation: *\(.*\)$/\1/p' | tr -d '\r')
if [ -z "${QUEUE_URL}" ]; then
    echo "[ERROR] Trigger returned no Location: header - is Jenkins up and the job name right?"
    exit 1
fi
QUEUE_ID=$(echo "${QUEUE_URL}" | sed -n 's#.*/queue/item/\([0-9][0-9]*\)/*$#\1#p')
echo "  Triggered TARGET_ENV=prod REQUEST_ID=${REQUEST_ID}"
echo "  Queue item: ${QUEUE_URL}"

# Resolve the queue item to OUR build number (404 = evicted -> match builds[queueId])
BUILD_NUM=""
for _ in $(seq 1 90); do
    RESP=$(curl -s -g -w '\n%{http_code}' "${QUEUE_URL}api/json?tree=executable[number]")
    CODE=$(echo "${RESP}" | tail -n 1)
    if [ "${CODE}" = "200" ]; then
        BUILD_NUM=$(echo "${RESP}" | sed '$d' | json_num number)
    elif [ "${CODE}" = "404" ]; then
        BUILD_NUM=$(curl -s -g "${JENKINS_URL}/job/${JOB}/api/json?tree=builds[number,queueId]" \
          | grep -o '{[^{}]*}' | grep -E "\"queueId\":${QUEUE_ID}[,}]" | json_num number | head -n 1)
    fi
    [ -n "${BUILD_NUM}" ] && break
    sleep 1
done
if [ -z "${BUILD_NUM}" ]; then
    echo "[ERROR] Queue item ${QUEUE_ID} never became a build"
    exit 1
fi
echo "  Build #${BUILD_NUM} started, waiting for completion..."

# Wait for completion (max ~2 min). Until then duration is 0, so never judge a running build.
FINISHED=false
for _ in $(seq 1 120); do
    if curl -s "${JENKINS_URL}/job/${JOB}/${BUILD_NUM}/api/json?tree=building" | grep -q '"building":false'; then
        FINISHED=true
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------- 2. SLA latency check
echo "== 2. SLA latency check (build #${BUILD_NUM})"
BUILD_JSON=$(curl -s "${JENKINS_URL}/job/${JOB}/${BUILD_NUM}/api/json?tree=number,result,duration")
echo "  GET /job/${JOB}/${BUILD_NUM}/api/json?tree=number,result,duration"
echo "  -> ${BUILD_JSON}"
RESULT=$(echo "${BUILD_JSON}" | json_str result)
DURATION=$(echo "${BUILD_JSON}" | json_num duration)
[[ "${DURATION}" =~ ^[0-9]+$ ]] || DURATION=999999999      # unknown duration can never pass

if [ "${FINISHED}" != "true" ]; then
    fail "build #${BUILD_NUM} still running after 2 minutes"
    REASONS+=("build #${BUILD_NUM} did not finish within 2 minutes")
fi

if [ "${RESULT}" = "SUCCESS" ]; then
    pass "result is SUCCESS"
else
    fail "result is ${RESULT:-unknown} (expected SUCCESS)"
    REASONS+=("build #${BUILD_NUM} result is ${RESULT:-unknown}, not SUCCESS")
fi

if [ "${DURATION}" -lt "${SLA_MAX_MS}" ]; then
    pass "duration ${DURATION} ms < ${SLA_MAX_MS} ms"
else
    fail "duration ${DURATION} ms >= ${SLA_MAX_MS} ms (SLA breach)"
    REASONS+=("SLA breach: build #${BUILD_NUM} took ${DURATION} ms (limit ${SLA_MAX_MS} ms)")
fi

# ---------------------------------------------------------------- 3. sliding-window health audit
echo "== 3. Sliding-window health audit (last ${WINDOW} builds)"
WINDOW_JSON=$(curl -s -g "${JENKINS_URL}/job/${JOB}/api/json?tree=builds[number,result,duration]{0,${WINDOW}}")
echo "  GET /job/${JOB}/api/json?tree=builds[number,result,duration]{0,${WINDOW}}  (${#WINDOW_JSON} bytes)"

SUCC=0; FAILS=0; OTHER=0; SEEN=0
printf "  %-8s %-12s %12s   %s\n" "BUILD" "RESULT" "DURATION" "SLA"
while read -r OBJ; do
    [ -n "${OBJ}" ] || continue
    B_NUM=$(echo "${OBJ}" | json_num number)
    B_RES=$(echo "${OBJ}" | json_str result)
    B_DUR=$(echo "${OBJ}" | json_num duration)
    B_RES="${B_RES:-IN_PROGRESS}"                       # "result":null while running
    case "${B_RES}" in
        SUCCESS) SUCC=$((SUCC + 1)) ;;
        FAILURE) FAILS=$((FAILS + 1)) ;;
        *)       OTHER=$((OTHER + 1)) ;;
    esac
    SEEN=$((SEEN + 1))
    if [ "${B_RES}" = "IN_PROGRESS" ]; then SLA_FLAG="-"
    elif [ "${B_DUR:-0}" -lt "${SLA_MAX_MS}" ]; then SLA_FLAG="ok"
    else SLA_FLAG="SLOW"; fi
    printf "  %-8s %-12s %9s ms   %s\n" "#${B_NUM}" "${B_RES}" "${B_DUR:-?}" "${SLA_FLAG}"
done < <(echo "${WINDOW_JSON}" | grep -o '{[^{}]*}')

echo "  SUCCESS=${SUCC}  FAILURE=${FAILS}  OTHER=${OTHER}  (window size ${SEEN})"
if [ "${SUCC}" -ge "${MIN_HEALTHY}" ]; then
    pass "${SUCC} of the last ${SEEN} builds succeeded (need >= ${MIN_HEALTHY})"
else
    fail "only ${SUCC} of the last ${SEEN} builds succeeded (need >= ${MIN_HEALTHY})"
    REASONS+=("health: only ${SUCC}/${SEEN} of the last ${WINDOW} builds are SUCCESS (need >= ${MIN_HEALTHY})")
fi

# ---------------------------------------------------------------- decision
echo "=========================================================="
if [ "${#REASONS[@]}" -eq 0 ]; then
    echo "  PROMOTION APPROVED"
    echo "=========================================================="
    exit 0
fi
echo "  PROMOTION BLOCKED"
for R in "${REASONS[@]}"; do echo "   - ${R}"; done
echo "=========================================================="
exit 1
EOF

chmod +x challenge6_sla_audit.sh
bash -n challenge6_sla_audit.sh && echo "SYNTAX OK"
```

---

## Step 2: Baseline run (healthy system)

```bash
./challenge6_sla_audit.sh; echo "exit code: $?"
```

**Expected output.** Build numbers and durations will differ. A normal worker run takes a few hundred ms:

```text
==========================================================
  CHALLENGE 6: PRE-RELEASE HEALTH & SLA GATE (lesson9-audit-worker)
==========================================================
== 1. Dispatch & measure
  Triggered TARGET_ENV=prod REQUEST_ID=SLA-1794775000
  Queue item: http://localhost:8080/queue/item/61/
  Build #15 started, waiting for completion...
== 2. SLA latency check (build #15)
  GET /job/lesson9-audit-worker/15/api/json?tree=number,result,duration
  -> {"_class":"hudson.model.FreeStyleBuild","duration":187,"number":15,"result":"SUCCESS"}
  [PASS] result is SUCCESS
  [PASS] duration 187 ms < 8000 ms
== 3. Sliding-window health audit (last 5 builds)
  GET /job/lesson9-audit-worker/api/json?tree=builds[number,result,duration]{0,5}  (412 bytes)
  BUILD    RESULT           DURATION   SLA
  #15      SUCCESS            187 ms   ok
  #14      SUCCESS            201 ms   ok
  #13      SUCCESS            176 ms   ok
  #12      SUCCESS            190 ms   ok
  #11      SUCCESS            183 ms   ok
  SUCCESS=5  FAILURE=0  OTHER=0  (window size 5)
  [PASS] 5 of the last 5 builds succeeded (need >= 3)
==========================================================
  PROMOTION APPROVED
==========================================================
exit code: 0
```

The fresh build (#15 here) is the newest build, so it's part of the window too.

Optional: see how much `tree=` and `{0,5}` save compared with downloading the full history:

```bash
echo "full history (depth=1): $(curl -s "${JENKINS_URL}/job/lesson9-audit-worker/api/json?depth=1" | wc -c) bytes"
echo "tree + {0,5} slice    : $(curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,result,duration]{0,5}" | wc -c) bytes"
```

---

## Step 3: Reproduce the incident (slow but "SUCCESS")

Simulate the infrastructure slowdown: add an extra **`sleep 10`** build step in front of the worker's real step. The worker still exits `0`, so `result` stays `SUCCESS`, but every build now takes about 10 s. The step is tagged `SLA-LATENCY-INJECTION` so it can be removed exactly.

### 3.1 Inject the latency

```bash
cat << 'EOF' > inject_latency.groovy
import jenkins.model.Jenkins
import hudson.tasks.Shell

def job = Jenkins.get().getItem('lesson9-audit-worker')
def steps = job.getBuildersList().toList().findAll { !(it instanceof Shell && it.command.contains('SLA-LATENCY-INJECTION')) }
def slow = new Shell('# SLA-LATENCY-INJECTION (simulated infrastructure slowdown)\nsleep 10')
job.getBuildersList().replaceBy([slow] + steps)
job.save()
println "LATENCY_INJECTED: build steps now = ${job.getBuildersList().size()}"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script@inject_latency.groovy"
rm -f inject_latency.groovy
```

**Expected:** `LATENCY_INJECTED: build steps now = 2`

### 3.2 Run the gate

```bash
./challenge6_sla_audit.sh; echo "exit code: $?"
```

**Expected (excerpt):**

```text
== 2. SLA latency check (build #16)
  -> {"_class":"hudson.model.FreeStyleBuild","duration":10236,"number":16,"result":"SUCCESS"}
  [PASS] result is SUCCESS
  [FAIL] duration 10236 ms >= 8000 ms (SLA breach)
== 3. Sliding-window health audit (last 5 builds)
  BUILD    RESULT           DURATION   SLA
  #16      SUCCESS          10236 ms   SLOW
  #15      SUCCESS            187 ms   ok
  ...
  [PASS] 5 of the last 5 builds succeeded (need >= 3)
==========================================================
  PROMOTION BLOCKED
   - SLA breach: build #16 took 10236 ms (limit 8000 ms)
==========================================================
exit code: 1
```

This is the incident caught. `result` is `SUCCESS` and the health window is fully green, yet the gate blocks the promotion because of `duration`. A pipeline that only checks results would have approved this build.

### 3.3 Remove the latency (back to normal)

```bash
cat << 'EOF' > remove_latency.groovy
import jenkins.model.Jenkins
import hudson.tasks.Shell

def job = Jenkins.get().getItem('lesson9-audit-worker')
def steps = job.getBuildersList().toList().findAll { !(it instanceof Shell && it.command.contains('SLA-LATENCY-INJECTION')) }
job.getBuildersList().replaceBy(steps)
job.save()
println "LATENCY_REMOVED: build steps now = ${job.getBuildersList().size()}"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script@remove_latency.groovy"
rm -f remove_latency.groovy
```

**Expected:** `LATENCY_REMOVED: build steps now = 1`

Re-running a Task Set provisioner (Task 1.2 or A.2) also clears the extra step, because it rebuilds the step list from scratch.

---

## Step 4: Break the health window, then watch it recover

### 4.1 Create 3 failed builds

Each failed build gets a unique `REQUEST_ID`, so Jenkins doesn't merge them into one queue item. Then wait until they've all finished:

```bash
for i in 1 2 3; do
  curl -s -o /dev/null -X POST \
    "${JENKINS_URL}/job/lesson9-audit-worker/buildWithParameters?delay=0sec&TARGET_ENV=staging&REQUEST_ID=CHAOS-FAIL-${i}-$(date +%s)&FORCE_FAIL=true"
done

for _ in $(seq 1 60); do
  S=$(curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=inQueue,lastBuild[building]")
  echo "${S}" | grep -q '"inQueue":false' && echo "${S}" | grep -q '"building":false' && break
  sleep 2
done
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,result]{0,3}"; echo
```

**Expected:** the 3 newest builds are all `"result":"FAILURE"`.

### 4.2 Run the gate (health failure)

```bash
./challenge6_sla_audit.sh; echo "exit code: $?"
```

**Expected (excerpt):**

```text
  [PASS] result is SUCCESS
  [PASS] duration 192 ms < 8000 ms
== 3. Sliding-window health audit (last 5 builds)
  BUILD    RESULT           DURATION   SLA
  #20      SUCCESS            192 ms   ok
  #19      FAILURE            150 ms   ok
  #18      FAILURE            148 ms   ok
  #17      FAILURE            151 ms   ok
  #16      SUCCESS          10236 ms   SLOW
  SUCCESS=2  FAILURE=3  OTHER=0  (window size 5)
  [FAIL] only 2 of the last 5 builds succeeded (need >= 3)
==========================================================
  PROMOTION BLOCKED
   - health: only 2/5 of the last 5 builds are SUCCESS (need >= 3)
==========================================================
exit code: 1
```

This time the fresh build is fast and green, but the recent history is unhealthy, so the gate still blocks the promotion.

### 4.3 Recovery: the window slides

Each gate run adds a new successful build at the top of the window, so the failures move down and eventually drop out:

```bash
for run in 1 2; do
  echo "--- gate run ${run}"
  ./challenge6_sla_audit.sh | grep -E 'SUCCESS=|PROMOTION'
done
```

**Expected:**

```text
--- gate run 1
  SUCCESS=2  FAILURE=3  OTHER=0  (window size 5)
  PROMOTION BLOCKED
--- gate run 2
  SUCCESS=3  FAILURE=2  OTHER=0  (window size 5)
  PROMOTION APPROVED
```

---

## Step 5 (optional): Tune the SLA without touching Jenkins

The limit is the variable `SLA_MAX_MS`, which defaults to 8000. Setting a very low limit is a quick way to see the SLA branch fail:

```bash
SLA_MAX_MS=50 ./challenge6_sla_audit.sh | grep -E '\] duration|PROMOTION|SLA breach'
```

**Expected:** `[FAIL] duration ... ms >= 50 ms (SLA breach)`, then `PROMOTION BLOCKED`.

---

## Completion checklist

| Check | Expected |
| --- | --- |
| Fresh build pinned through its `Location:` queue item | `Build #N started` (not `lastBuild`) |
| SLA query | `tree=number,result,duration` with `result=SUCCESS` and `duration < 8000` |
| Window query | `tree=builds[number,result,duration]{0,5}`: only 5 builds, a few hundred bytes |
| Healthy baseline (Step 2) | `PROMOTION APPROVED`, exit code `0` |
| Slow but "SUCCESS" (Step 3) | `SLA breach` → `PROMOTION BLOCKED`, exit code `1` |
| 3 failures in window (Step 4.2) | `only 2/5` → `PROMOTION BLOCKED` |
| Window recovery (Step 4.3) | `SUCCESS=3` → `PROMOTION APPROVED` |
| Latency removed afterwards (Step 3.3) | `LATENCY_REMOVED: build steps now = 1` |

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `[ERROR] Trigger returned no Location: header` | Jenkins down, wrong job name, or a rejected parameter | Redo Step 0 |
| Every run is blocked with `SLA breach` around 10 s | The latency injection is still active | Run Step 3.3 |
| `OTHER=1` in the window | Another build was still running (`"result":null`) when the window was read | Run the gate again once the queue is idle |
| `curl: (3) bad range` / empty window | `-g` missing, so curl tried to expand `[...]` / `{0,5}` itself | Keep `curl -g` on every `tree=` query with brackets or braces |
