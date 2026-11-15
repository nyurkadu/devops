# Task Set 2: Applied Engineering Challenge (Extending the Pattern)

Lab host: **Killercoda, Ubuntu 24.04**. Jenkins runs from the WAR on port **8080** with security off, so there's no admin user, no API token and no `-u`.

**No plugins are installed.** Everything here uses Jenkins core only: the `/scriptText` Groovy console, the Shell build step, `ArtifactArchiver` and the REST API. Plus `sha256sum` from Ubuntu's coreutils.

| Challenge | What changes |
| --- | --- |
| **A**: SHA-256 checksum | Worker writes and archives `audit_report.sha256`. Orchestrator downloads both files and runs `sha256sum -c` before reading the JSON |
| **B**: Fan-out loop | New external script runs the orchestrator for `dev`, `staging` and `prod` one after another, then prints a summary table |

Rules:

- Run everything in the **same terminal tab**. Step 0 defines variables and a helper function that later steps use.
- Do Challenge A before B. Challenge B relies on the orchestrator accepting `dev`, which A.5 sets up.

---

## Step 0: Prerequisites (repeat in every new terminal)

You need Task Set 1 finished: Jenkins running and both Lesson 9 jobs present. If they're missing, see Step 0 and the Appendix of [Mission_TaskSet1_Guided_Reinforcement.md](Mission_TaskSet1_Guided_Reinforcement.md).

```bash
export JENKINS_URL="http://localhost:8080"

# Jenkins up? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/api/json"

# Both jobs present? Expect lesson9-audit-worker and lesson9-orchestrator
curl -s -g "${JENKINS_URL}/api/json?tree=jobs[name]"; echo
```

Define the helper function `run_job`. It triggers a job, waits for the build to finish and prints `<build-number> <RESULT>`:

```bash
run_job() {   # usage: run_job <job-name> "<query-string>"
  local q="" n="" r=""
  q=$(curl -s -D - -o /dev/null -X POST "${JENKINS_URL}/job/$1/buildWithParameters?delay=0sec&$2" \
      | grep -i '^Location:' | awk '{print $2}' | tr -d '\r\n')
  [ -n "$q" ] || { echo "- TRIGGER_FAILED"; return 1; }
  for _ in $(seq 1 60); do
    n=$(curl -s "${q}api/json" \
        | python3 -c 'import sys,json; e=json.load(sys.stdin).get("executable"); print(e["number"] if e else "")' 2>/dev/null)
    [ -n "$n" ] && break; sleep 1
  done
  [ -n "$n" ] || { echo "- QUEUE_TIMEOUT"; return 1; }
  for _ in $(seq 1 150); do
    r=$(curl -s "${JENKINS_URL}/job/$1/$n/api/json?tree=building,result" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print("" if d["building"] else d["result"])' 2>/dev/null)
    [ -n "$r" ] && break; sleep 2
  done
  echo "$n ${r:-TIMEOUT}"
}
```

---

## Challenge A: Artifact Checksum Verification (SHA-256)

### A.1 Update `worker_payload.sh`

The new lines are marked `# NEW (Challenge A)`:

- After `audit_report.json` is written, `sha256sum audit_report.json > audit_report.sha256` stores the hash in the exact format that `sha256sum -c` reads back: `<hash>  audit_report.json`.
- **Extra hardening:** the script first deletes old report files. A failed build then can't re-archive a stale report left in the workspace by an earlier run (the stale-workspace effect from Task Set 1).

```bash
cat << 'EOF' > worker_payload.sh
#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo "  LESSON 9 WORKER: AUDIT & METADATA GENERATOR"
echo "=========================================================="

TARGET_ENV="${TARGET_ENV:-staging}"
REQUEST_ID="${REQUEST_ID:-unknown}"
FORCE_FAIL="${FORCE_FAIL:-false}"

echo "--> Environment : ${TARGET_ENV}"
echo "--> Request ID  : ${REQUEST_ID}"
echo "--> Force Fail  : ${FORCE_FAIL}"
echo "--> Node Name   : ${NODE_NAME:-built-in}"

# NEW (Challenge A): start clean so a failed run can't re-archive an old report
rm -f audit_report.json audit_report.sha256

if [ "${FORCE_FAIL}" = "true" ]; then
    echo "[ERROR] Simulated failure triggered via FORCE_FAIL=true!"
    exit 1
fi

# Generate structured JSON report
cat << JSON_EOF > audit_report.json
{
  "request_id": "${REQUEST_ID}",
  "environment": "${TARGET_ENV}",
  "worker_build": "${BUILD_NUMBER}",
  "executed_on": "${NODE_NAME:-built-in}",
  "checks_passed": true
}
JSON_EOF

# NEW (Challenge A): SHA-256 of the report, in "sha256sum -c" format
sha256sum audit_report.json > audit_report.sha256
echo "--> SHA-256     : $(cut -d' ' -f1 audit_report.sha256)"

echo "[SUCCESS] audit_report.json + audit_report.sha256 generated in ${WORKSPACE}"
EOF

B64_WORKER=$(base64 -w 0 worker_payload.sh)
rm -f worker_payload.sh
echo "${B64_WORKER:-EMPTY}" | cut -c1-60    # must NOT print EMPTY
```

### A.2 Re-provision the worker so it archives both files

This is the same idempotent provisioner as Task Set 1 with one change: `ArtifactArchiver` now takes a **comma-separated** list of patterns.

```bash
cat << EOF > provision_lesson9_worker.groovy
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.ParametersDefinitionProperty
import hudson.model.StringParameterDefinition
import hudson.model.ChoiceParameterDefinition
import hudson.model.BooleanParameterDefinition
import hudson.model.labels.LabelAtom
import hudson.tasks.Shell
import hudson.tasks.ArtifactArchiver

def instance = Jenkins.get()
def jobName = 'lesson9-audit-worker'

def job = instance.getItem(jobName)
if (job == null) {
    job = instance.createProject(FreeStyleProject, jobName)
    println "CREATED_NEW_JOB: \${jobName}"
} else {
    println "UPDATED_EXISTING_JOB: \${jobName}"
}

job.setAssignedLabel(new LabelAtom('built-in'))

job.removeProperty(ParametersDefinitionProperty.class)
def envParam = new ChoiceParameterDefinition('TARGET_ENV', ['dev', 'staging', 'prod'] as String[], 'Target deployment environment')
def reqParam = new StringParameterDefinition('REQUEST_ID', 'REQ-000', 'Tracking ID from upstream orchestrator')
def failParam = new BooleanParameterDefinition('FORCE_FAIL', false, 'Simulate a worker crash for testing')
job.addProperty(new ParametersDefinitionProperty(envParam, reqParam, failParam))

String decodedScript = new String("${B64_WORKER}".decodeBase64())
job.getBuildersList().clear()
job.getBuildersList().add(new Shell(decodedScript))

// NEW (Challenge A): archive the report AND its checksum
job.getPublishersList().clear()
job.getPublishersList().add(new ArtifactArchiver('audit_report.json,audit_report.sha256'))

job.save()
println "LESSON9_WORKER_READY"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script@provision_lesson9_worker.groovy"
rm -f provision_lesson9_worker.groovy
```

**Expected output:**

```text
UPDATED_EXISTING_JOB: lesson9-audit-worker
LESSON9_WORKER_READY
```

### A.3 Test the worker on its own

Run one worker build, then confirm that both files were archived and the checksum matches:

```bash
read -r WB WR < <(run_job lesson9-audit-worker "TARGET_ENV=staging&REQUEST_ID=REQ-SHA-TEST&FORCE_FAIL=false")
echo "Worker build #${WB} -> ${WR}"

# Both files archived?
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/${WB}/api/json?tree=artifacts[relativePath]" \
  | python3 -c 'import sys,json; print([a["relativePath"] for a in json.load(sys.stdin)["artifacts"]])'

# Download both into a temp folder and verify, the same way the orchestrator will
T=$(mktemp -d)
curl -s -f -o "$T/audit_report.json"   "${JENKINS_URL}/job/lesson9-audit-worker/${WB}/artifact/audit_report.json"
curl -s -f -o "$T/audit_report.sha256" "${JENKINS_URL}/job/lesson9-audit-worker/${WB}/artifact/audit_report.sha256"
cat "$T/audit_report.sha256"
(cd "$T" && sha256sum -c audit_report.sha256)
```

**Expected output** (the build number and hash will differ):

```text
Worker build #4 -> SUCCESS
['audit_report.json', 'audit_report.sha256']
3f5c...e9a1  audit_report.json
audit_report.json: OK
```

`sha256sum -c` gets the file name from the `.sha256` file itself. That's why the JSON has to be saved as **`audit_report.json`** in the same folder, and why the check runs inside `$T`.

### A.4 Update `orchestrator_payload.sh`

Only **step 6** changes. The orchestrator now:

1. downloads **both** artifacts over REST,
2. runs `sha256sum -c audit_report.sha256` **before** reading the JSON,
3. stops with `exit 1` if the checksum doesn't match,
4. copies the verified file to `ingested_audit.json` and runs the usual round-trip ID check.

This is the Task Set 1 Appendix version: no `-u`, and the crumb request uses `curl -sf`.

```bash
cat << 'EOF' > orchestrator_payload.sh
#!/usr/bin/env bash
set -euo pipefail

JENKINS_URL="http://localhost:8080"
CHILD_JOB="lesson9-audit-worker"
ENV_CHOICE="${TARGET_ENV:-staging}"
SIMULATE_FAIL="${FORCE_FAIL:-false}"
TRACKING_ID="ORD-${BUILD_NUMBER}-$(date +%s)"

echo "=========================================================="
echo "  LESSON 9 ORCHESTRATOR (BUILD #${BUILD_NUMBER})"
echo "=========================================================="

# 1. Obtain CSRF crumb (-f: stays empty when CSRF protection is disabled)
CRUMB=$(curl -sf \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)

# 2. Trigger parameterized child job and capture response headers
echo "--> Triggering '${CHILD_JOB}' [ENV=${ENV_CHOICE}, FAIL=${SIMULATE_FAIL}, ID=${TRACKING_ID}]..."
HEADER_FILE="/tmp/headers_${BUILD_NUMBER}.txt"

TRIGGER_URL="${JENKINS_URL}/job/${CHILD_JOB}/buildWithParameters?TARGET_ENV=${ENV_CHOICE}&REQUEST_ID=${TRACKING_ID}&FORCE_FAIL=${SIMULATE_FAIL}"

if [ -n "${CRUMB}" ]; then
    curl -s -D "${HEADER_FILE}" -X POST -H "${CRUMB}" "${TRIGGER_URL}" > /dev/null
else
    curl -s -D "${HEADER_FILE}" -X POST "${TRIGGER_URL}" > /dev/null
fi

HTTP_STATUS=$(grep -i "^HTTP/" "${HEADER_FILE}" | tail -n 1 | awk '{print $2}' | tr -d '\r\n')
QUEUE_URL=$(grep -i "^Location:" "${HEADER_FILE}" | awk '{print $2}' | tr -d '\r\n')
rm -f "${HEADER_FILE}"

if [ "${HTTP_STATUS}" != "201" ] || [ -z "${QUEUE_URL}" ]; then
    echo "[ERROR] Trigger failed! HTTP Status: ${HTTP_STATUS}"
    exit 1
fi

echo "--> Queue Item Created: ${QUEUE_URL}"

# 3. Poll Queue State Machine until executable number is assigned
CHILD_BUILD_NUM=""
WAIT_SECONDS=0
MAX_QUEUE_WAIT=45

while [ -z "${CHILD_BUILD_NUM}" ]; do
    if [ "${WAIT_SECONDS}" -ge "${MAX_QUEUE_WAIT}" ]; then
        echo "[ERROR] Timed out waiting in queue after ${MAX_QUEUE_WAIT}s."
        exit 1
    fi

    QUEUE_JSON=$(curl -s "${QUEUE_URL}api/json")

    IS_CANCELLED=$(echo "${QUEUE_JSON}" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("cancelled", False))' 2>/dev/null || echo "False")
    if [ "${IS_CANCELLED}" = "True" ]; then
        echo "[ERROR] Downstream job was cancelled while in queue!"
        exit 1
    fi

    CHILD_BUILD_NUM=$(echo "${QUEUE_JSON}" | python3 -c 'import sys, json; exe=json.load(sys.stdin).get("executable"); print(exe.get("number") if exe else "")' 2>/dev/null || true)

    if [ -z "${CHILD_BUILD_NUM}" ]; then
        sleep 1
        WAIT_SECONDS=$((WAIT_SECONDS + 1))
    fi
done

echo "--> Executor Assigned! Child Build #${CHILD_BUILD_NUM} is active."

# 4. Poll Build Execution until building == false
while true; do
    BUILD_JSON=$(curl -s "${JENKINS_URL}/job/${CHILD_JOB}/${CHILD_BUILD_NUM}/api/json")
    IS_BUILDING=$(echo "${BUILD_JSON}" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("building", True))')

    if [ "${IS_BUILDING}" = "False" ]; then
        BUILD_RESULT=$(echo "${BUILD_JSON}" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("result", "UNKNOWN"))')
        echo "--> Child Build #${CHILD_BUILD_NUM} Finished with Result: ${BUILD_RESULT}"
        break
    fi
    sleep 2
done

# 5. Propagate Failure if Child Did Not Succeed
if [ "${BUILD_RESULT}" != "SUCCESS" ]; then
    echo "[ERROR] Downstream job failed (${BUILD_RESULT}). Aborting parent pipeline."
    exit 1
fi

# 6. NEW (Challenge A): download BOTH artifacts, verify SHA-256 BEFORE reading the JSON
ARTIFACT_BASE="${JENKINS_URL}/job/${CHILD_JOB}/${CHILD_BUILD_NUM}/artifact"
rm -f audit_report.json audit_report.sha256 ingested_audit.json

for f in audit_report.json audit_report.sha256; do
    if ! curl -s -f -o "${f}" "${ARTIFACT_BASE}/${f}"; then
        echo "[ERROR] Could not download artifact '${f}' from build #${CHILD_BUILD_NUM}"
        exit 1
    fi
done
echo "--> Downloaded audit_report.json + audit_report.sha256 from build #${CHILD_BUILD_NUM}"

echo "--> Verifying SHA-256 checksum..."
if ! sha256sum -c audit_report.sha256; then
    echo "[ERROR] SHA-256 checksum mismatch for audit_report.json! Artifact is corrupted or tampered. Aborting."
    exit 1
fi
echo "[SUCCESS] SHA-256 checksum verified."

# Only a verified file becomes the ingested payload
cp audit_report.json ingested_audit.json

echo "=========================================================="
echo "  VERIFIED ARTIFACT PAYLOAD (ingested_audit.json)"
echo "=========================================================="
cat ingested_audit.json
echo ""

RETURNED_ID=$(python3 -c 'import json; print(json.load(open("ingested_audit.json")).get("request_id"))')
if [ "${RETURNED_ID}" != "${TRACKING_ID}" ]; then
    echo "[ERROR] Artifact mismatch! Expected ${TRACKING_ID}, got ${RETURNED_ID}"
    exit 1
fi

echo "[SUCCESS] Round-trip correlation ID (${RETURNED_ID}) verified!"
EOF

B64_ORCH=$(base64 -w 0 orchestrator_payload.sh)
rm -f orchestrator_payload.sh
echo "${B64_ORCH:-EMPTY}" | cut -c1-60    # must NOT print EMPTY
```

### A.5 Re-provision the orchestrator

This is the lesson's idempotent parent provisioner. It keeps **`dev`** in the choices from Task Set 1 (Task 3), and Challenge B needs it. `staging` stays first, so it remains the default.

```bash
cat << EOF > provision_lesson9_parent.groovy
import jenkins.model.Jenkins
import hudson.model.FreeStyleProject
import hudson.model.ParametersDefinitionProperty
import hudson.model.ChoiceParameterDefinition
import hudson.model.BooleanParameterDefinition
import hudson.model.labels.LabelAtom
import hudson.tasks.Shell

def instance = Jenkins.get()
def jobName = 'lesson9-orchestrator'

def job = instance.getItem(jobName)
println(job == null ? "CREATED_NEW_JOB: \${jobName}" : "UPDATED_EXISTING_JOB: \${jobName}")
if (job == null) { job = instance.createProject(FreeStyleProject, jobName) }
job.setAssignedLabel(new LabelAtom('built-in'))

job.removeProperty(ParametersDefinitionProperty.class)
def envParam = new ChoiceParameterDefinition('TARGET_ENV', ['staging', 'prod', 'dev'] as String[], 'Environment to audit')
def failParam = new BooleanParameterDefinition('FORCE_FAIL', false, 'Pass failure flag to downstream worker')
job.addProperty(new ParametersDefinitionProperty(envParam, failParam))

String decodedScript = new String("${B64_ORCH}".decodeBase64())
job.getBuildersList().clear()
job.getBuildersList().add(new Shell(decodedScript))

job.save()
println "LESSON9_PARENT_READY"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script@provision_lesson9_parent.groovy"
rm -f provision_lesson9_parent.groovy
```

**Expected output:**

```text
UPDATED_EXISTING_JOB: lesson9-orchestrator
LESSON9_PARENT_READY
```

### A.6 Run the orchestrator end to end

```bash
read -r OB OR < <(run_job lesson9-orchestrator "TARGET_ENV=staging&FORCE_FAIL=false")
echo "Orchestrator build #${OB} -> ${OR}"

curl -s "${JENKINS_URL}/job/lesson9-orchestrator/${OB}/consoleText"
```

**Expected console excerpt:**

```text
--> Child Build #5 Finished with Result: SUCCESS
--> Downloaded audit_report.json + audit_report.sha256 from build #5
--> Verifying SHA-256 checksum...
audit_report.json: OK
[SUCCESS] SHA-256 checksum verified.
==========================================================
  VERIFIED ARTIFACT PAYLOAD (ingested_audit.json)
==========================================================
{
  "request_id": "ORD-<n>-<epoch>",
  "environment": "staging",
  "worker_build": "5",
  "executed_on": "built-in",
  "checks_passed": true
}

[SUCCESS] Round-trip correlation ID (ORD-<n>-<epoch>) verified!
Finished: SUCCESS
```

`audit_report.json: OK` is printed **before** the JSON payload. That shows the checksum is verified before anything reads the file.

### A.7 Negative test: a tampered artifact must fail the check

Jenkins serves archived artifacts straight from `$JENKINS_HOME/jobs/<job>/builds/<n>/archive/`. On the Killercoda host you can edit one to simulate tampering. This test flips `checks_passed` to `false` in the latest successful worker build, then runs the orchestrator's step 6 check against it. The check runs in a **subshell** `( ... )`, so `exit 1` doesn't close your terminal.

```bash
WB=$(curl -s "${JENKINS_URL}/job/lesson9-audit-worker/lastSuccessfulBuild/api/json?tree=number" \
     | python3 -c 'import sys,json; print(json.load(sys.stdin)["number"])')
ARCH="$HOME/jenkins_home/jobs/lesson9-audit-worker/builds/${WB}/archive"

# 1. Back up, then tamper with the archived report (the .sha256 stays untouched)
cp "$ARCH/audit_report.json" /tmp/audit_report.json.bak
sed -i 's/"checks_passed": true/"checks_passed": false/' "$ARCH/audit_report.json"

# 2. Same download + verify logic as orchestrator step 6
T=$(mktemp -d)
(
  cd "$T"
  for f in audit_report.json audit_report.sha256; do
    curl -s -f -o "$f" "${JENKINS_URL}/job/lesson9-audit-worker/${WB}/artifact/$f" || exit 1
  done
  if ! sha256sum -c audit_report.sha256; then
    echo "[ERROR] SHA-256 checksum mismatch for audit_report.json! Aborting."
    exit 1
  fi
  echo "[SUCCESS] SHA-256 checksum verified."
)
echo "verification exit code: $?"

# 3. Restore the original artifact
cp /tmp/audit_report.json.bak "$ARCH/audit_report.json"
(cd "$ARCH" && sha256sum -c audit_report.sha256)
```

**Expected output:**

```text
audit_report.json: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
[ERROR] SHA-256 checksum mismatch for audit_report.json! Aborting.
verification exit code: 1
audit_report.json: OK
```

The last line is the check after the restore. It confirms the archived build is back to its original state.

---

## Challenge B: Multi-Environment Fan-Out Loop

### B.1 Write the external script `fanout_orchestrator.sh`

The script runs **outside** Jenkins, on the Killercoda host. For each environment in `for ENV in dev staging prod`, it:

1. triggers `lesson9-orchestrator` with `delay=0sec` and keeps the queue URL from the `Location` header,
2. polls the queue item until Jenkins assigns a **parent build number**,
3. polls that build until `building` is `false`, then reads its **result**,
4. only then moves on to the next environment. That's what makes it sequential.

Finally it prints the summary table. It exits `0` if every run succeeded and `1` otherwise, so a CI system could use it as a gate. A failed or rejected run is recorded and the loop continues. Set `FAIL_ENV=<env>` to force one environment to fail on purpose (used in B.3).

```bash
cat << 'EOF' > fanout_orchestrator.sh
#!/usr/bin/env bash
# Challenge B: trigger lesson9-orchestrator once per environment, sequentially,
# then print a summary table. Exit code: 0 = all SUCCESS, 1 = anything else.
set -uo pipefail

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
PARENT_JOB="lesson9-orchestrator"
FAIL_ENV="${FAIL_ENV:-}"     # optional: FAIL_ENV=staging forces that run to fail
ROWS=()
OVERALL=0

for ENV in dev staging prod; do
    FORCE_FAIL=false
    [ "${ENV}" = "${FAIL_ENV}" ] && FORCE_FAIL=true

    echo "=========================================================="
    echo "  [${ENV}] Triggering ${PARENT_JOB} (FORCE_FAIL=${FORCE_FAIL})"
    echo "=========================================================="

    # 1. Trigger and capture HTTP status + queue URL
    HEADERS=$(curl -s -D - -o /dev/null -X POST \
      "${JENKINS_URL}/job/${PARENT_JOB}/buildWithParameters?delay=0sec&TARGET_ENV=${ENV}&FORCE_FAIL=${FORCE_FAIL}")
    STATUS=$(echo "${HEADERS}" | grep -i '^HTTP/' | tail -n 1 | awk '{print $2}' | tr -d '\r')
    QUEUE_URL=$(echo "${HEADERS}" | grep -i '^Location:' | awk '{print $2}' | tr -d '\r\n')

    if [ "${STATUS}" != "201" ] || [ -z "${QUEUE_URL}" ]; then
        echo "--> Trigger rejected (HTTP ${STATUS:-none})"
        ROWS+=("-|${ENV}|TRIGGER_FAILED")
        OVERALL=1
        continue
    fi
    echo "--> Queued: ${QUEUE_URL}"

    # 2. Wait for the queue item to become a parent build (max 60 s)
    BUILD_NUM=""
    for _ in $(seq 1 60); do
        BUILD_NUM=$(curl -s "${QUEUE_URL}api/json" \
          | python3 -c 'import sys,json; e=json.load(sys.stdin).get("executable"); print(e["number"] if e else "")' 2>/dev/null)
        [ -n "${BUILD_NUM}" ] && break
        sleep 1
    done
    if [ -z "${BUILD_NUM}" ]; then
        echo "--> Still queued after 60 s"
        ROWS+=("-|${ENV}|QUEUE_TIMEOUT")
        OVERALL=1
        continue
    fi
    echo "--> Parent build #${BUILD_NUM} started"

    # 3. Wait for the parent build to finish (max 5 min), then read its result
    RESULT=""
    for _ in $(seq 1 150); do
        RESULT=$(curl -s "${JENKINS_URL}/job/${PARENT_JOB}/${BUILD_NUM}/api/json?tree=building,result" \
          | python3 -c 'import sys,json; d=json.load(sys.stdin); print("" if d["building"] else d["result"])' 2>/dev/null)
        [ -n "${RESULT}" ] && break
        sleep 2
    done
    RESULT="${RESULT:-TIMEOUT}"
    echo "--> Parent build #${BUILD_NUM} finished: ${RESULT}"

    [ "${RESULT}" = "SUCCESS" ] || OVERALL=1
    ROWS+=("#${BUILD_NUM}|${ENV}|${RESULT}")
done

# 4. Final summary table
echo
echo "=========================================================="
echo "  FAN-OUT SUMMARY: ${PARENT_JOB}"
echo "=========================================================="
printf "%-14s %-13s %s\n" "PARENT BUILD" "ENVIRONMENT" "RESULT"
printf "%-14s %-13s %s\n" "------------" "-----------" "--------------"
for row in "${ROWS[@]}"; do
    IFS='|' read -r r_build r_env r_result <<< "${row}"
    printf "%-14s %-13s %s\n" "${r_build}" "${r_env}" "${r_result}"
done

exit "${OVERALL}"
EOF

chmod +x fanout_orchestrator.sh
```

### B.2 Run it: all three environments

```bash
./fanout_orchestrator.sh; echo "exit code: $?"
```

**Expected output** (build numbers depend on your history):

```text
==========================================================
  [dev] Triggering lesson9-orchestrator (FORCE_FAIL=false)
==========================================================
--> Queued: http://localhost:8080/queue/item/12/
--> Parent build #3 started
--> Parent build #3 finished: SUCCESS
==========================================================
  [staging] Triggering lesson9-orchestrator (FORCE_FAIL=false)
==========================================================
...
==========================================================
  FAN-OUT SUMMARY: lesson9-orchestrator
==========================================================
PARENT BUILD   ENVIRONMENT   RESULT
------------   -----------   --------------
#3             dev           SUCCESS
#4             staging       SUCCESS
#5             prod          SUCCESS
exit code: 0
```

Each parent build runs a full Challenge A cycle: it triggers the worker, verifies the SHA-256 and checks the round-trip ID. To see which environment a parent build actually sent to the worker, check its console:

```bash
curl -s "${JENKINS_URL}/job/lesson9-orchestrator/lastBuild/consoleText" | grep -E '"environment"|audit_report.json: OK'
# ->   audit_report.json: OK
# ->     "environment": "prod",
```

### B.3 (Optional) Failure path: one environment fails, the loop keeps going

```bash
FAIL_ENV=staging ./fanout_orchestrator.sh; echo "exit code: $?"
```

**Expected summary:**

```text
PARENT BUILD   ENVIRONMENT   RESULT
------------   -----------   --------------
#6             dev           SUCCESS
#7             staging       FAILURE
#8             prod          SUCCESS
exit code: 1
```

`staging` passes `FORCE_FAIL=true` to the worker. The worker exits 1, step 5 of the orchestrator propagates the failure, and the parent build ends as `FAILURE`. The fan-out records it, still runs `prod`, and returns exit code `1`.

### Why one at a time

- The built-in node has 2 executors by default. Each orchestrator run takes one and its worker takes the other. Running the three in parallel would leave workers waiting in the queue, and the orchestrator's 45 s queue timeout could fail them.
- One run at a time means each row of the table maps to exactly one parent build and one worker build.

---

## Completion checklist

| Challenge | Check | Expected |
| --- | --- | --- |
| A | Worker re-provision | `UPDATED_EXISTING_JOB: lesson9-audit-worker` (history kept) |
| A | Worker artifacts | `['audit_report.json', 'audit_report.sha256']` |
| A | Orchestrator console | `audit_report.json: OK` printed before the JSON payload |
| A | Tampered artifact | `audit_report.json: FAILED`, exit code `1` |
| B | Fan-out (all OK) | 3 rows: `dev`, `staging`, `prod`, all `SUCCESS`, exit code `0` |
| B | Fan-out (`FAIL_ENV=staging`) | `staging` = `FAILURE`, `prod` still runs, exit code `1` |
| Both | Plugins installed | none: only core Jenkins, REST and `sha256sum` |

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `[ERROR] Could not download artifact 'audit_report.sha256'` | Orchestrator updated but the worker wasn't (no `.sha256` archived) | Redo A.1 and A.2 |
| `sha256sum: audit_report.json: No such file or directory` | JSON saved under another name or in another folder | Save it as `audit_report.json` next to the `.sha256` |
| Fan-out row `dev ... TRIGGER_FAILED` | Orchestrator choices don't include `dev` | Redo A.5 (or Task Set 1, Task 3.3) |
| Groovy prints `CREATED_NEW_JOB` | Jobs were missing (new Killercoda VM) | Rebuild via the Task Set 1 Appendix, then start Task Set 2 again |
| JSON decode traceback in any check | `JENKINS_URL` unset in this tab, or Jenkins down | Redo Step 0 |
