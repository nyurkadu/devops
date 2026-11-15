# Task Set 1: Guided Reinforcement (Core Mechanics)

Lab host: **Killercoda, Ubuntu 24.04**. Jenkins runs from the WAR on port **8080** and keeps its data in `JENKINS_HOME=$HOME/jenkins_home` (see the setup in [Lesson_missions.md](Lesson_missions.md)).

Rules for this mission:

- Run every command in the **same terminal tab**. Variables like `B64_WORKER` exist only in the shell where you created them.
- Do the tasks **in order**. Task 3 starts a new worker build (#3), so the checks in Tasks 1 and 2 have to come first.

---

## Step 0: Prerequisites (repeat in every new terminal)

Jenkins was started with `-Djenkins.install.runSetupWizard=false`, so **security is off**. There's no admin user and no API token, and none of the REST calls below need `-u`.

```bash
export JENKINS_URL="http://localhost:8080"

# Jenkins is up? Expect: 200
curl -s -o /dev/null -w "%{http_code}\n" "${JENKINS_URL}/api/json"

# Both Lesson 9 jobs exist? Expect lesson9-audit-worker and lesson9-orchestrator
curl -s -g "${JENKINS_URL}/api/json?tree=jobs[name]"; echo
```

> If the orchestrator was provisioned in class from [Lesson_missions.md](Lesson_missions.md), its script contains `-u "admin:"`, because the token was empty when it was injected. Jenkins ignores that header while security is off. The Appendix version of the orchestrator has no auth at all.

### If you get `000`: Jenkins is not answering

**0a. Find out why:**

```bash
ls -d ~/jenkins/jenkins.war ~/jenkins_home/jobs/* 2>&1
pgrep -af jenkins.war || echo "Jenkins process NOT running"
tail -n 20 ~/jenkins/jenkins.log 2>/dev/null
```

| What you see | Meaning | Do this |
| --- | --- | --- |
| `No such file or directory` for `jenkins.war` | Fresh Killercoda VM, so nothing is installed | Run the whole setup at the top of [Lesson_missions.md](Lesson_missions.md), then the [Appendix](#appendix-killercoda-session-was-reset-rebuild-the-lesson-9-history) |
| Lesson 9 job folders listed, `NOT running` | Process stopped, history is still on disk | Restart with 0b |
| Process running, log doesn't say `Jenkins is fully up and running` yet | Still starting | Wait, then check again (the 0b wait loop) |
| `nohup: failed to run command 'java'` in the log | Java is missing | `sudo apt-get update && sudo apt-get install -y openjdk-17-jdk-headless`, then 0b |

**0b. Restart Jenkins and wait until it's ready.** Set `JENKINS_HOME` first. Without it, Jenkins starts with an empty `~/.jenkins` and your Lesson 9 jobs look like they're gone.

```bash
export JENKINS_DIR=$HOME/jenkins
export JENKINS_HOME=$HOME/jenkins_home

nohup java \
  -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar "$JENKINS_DIR/jenkins.war" --httpPort=8080 \
  > "$JENKINS_DIR/jenkins.log" 2>&1 &
echo $! > "$JENKINS_DIR/jenkins.pid"

# Wait up to 3 minutes for HTTP 200
timeout 180 bash -c 'until [ "$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/json)" = "200" ]; do sleep 3; done' \
  && echo "JENKINS READY" || { echo "NOT READY - check the log:"; tail -n 30 "$JENKINS_DIR/jenkins.log"; }
```

Then run the Step 0 checks again.

If the jobs are missing, Killercoda gave you a fresh VM and the Lesson 9 history is gone. Use the [Appendix](#appendix-killercoda-session-was-reset-rebuild-the-lesson-9-history) to rebuild it first.

---

## Task 1: Idempotency Verification

**Goal:** re-run the provisioner and prove that it **updates** the existing job instead of recreating it. If it recreated the job, the build history would be lost.

### 1.1 Rebuild the worker payload (`B64_WORKER`)

The Groovy provisioner embeds `${B64_WORKER}`. In a new shell that variable is empty, and an empty value would replace the job's build step with an **empty script**. So build it again first:

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

echo "[SUCCESS] audit_report.json generated in ${WORKSPACE}"
EOF

B64_WORKER=$(base64 -w 0 worker_payload.sh)
rm -f worker_payload.sh

# Safety check: must print a long base64 string, NOT "EMPTY"
echo "${B64_WORKER:-EMPTY}" | cut -c1-60
```

### 1.2 Run the provisioner snippet (`provision_lesson9_worker.groovy`)

This is the same snippet as in the lesson. The heredoc delimiter is **unquoted** (`EOF`), so the shell fills in `${B64_WORKER}`, while `\${jobName}` is left for Groovy to expand.

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

// Idempotent lookup: reuse existing project to preserve build history
def job = instance.getItem(jobName)
if (job == null) {
    job = instance.createProject(FreeStyleProject, jobName)
    println "CREATED_NEW_JOB: \${jobName}"
} else {
    println "UPDATED_EXISTING_JOB: \${jobName}"
}

// Explicit LabelAtom binding (safe on fresh installs)
job.setAssignedLabel(new LabelAtom('built-in'))

// Reset and define parameters cleanly
job.removeProperty(ParametersDefinitionProperty.class)
def envParam = new ChoiceParameterDefinition('TARGET_ENV', ['dev', 'staging', 'prod'] as String[], 'Target deployment environment')
def reqParam = new StringParameterDefinition('REQUEST_ID', 'REQ-000', 'Tracking ID from upstream orchestrator')
def failParam = new BooleanParameterDefinition('FORCE_FAIL', false, 'Simulate a worker crash for testing')
job.addProperty(new ParametersDefinitionProperty(envParam, reqParam, failParam))

// Replace build steps cleanly without duplication
String decodedScript = new String("${B64_WORKER}".decodeBase64())
job.getBuildersList().clear()
job.getBuildersList().add(new Shell(decodedScript))

// Replace post-build artifact archiver
job.getPublishersList().clear()
job.getPublishersList().add(new ArtifactArchiver('audit_report.json'))

job.save()
println "LESSON9_WORKER_READY"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" \
  --data-urlencode "script@provision_lesson9_worker.groovy"

rm -f provision_lesson9_worker.groovy
```

**Expected output:**

```
UPDATED_EXISTING_JOB: lesson9-audit-worker
LESSON9_WORKER_READY
```

If you see `CREATED_NEW_JOB: lesson9-audit-worker`, the job did not exist before this run. The history is gone, so use the [Appendix](#appendix-killercoda-session-was-reset-rebuild-the-lesson-9-history).

### 1.3 Confirm `nextBuildNumber` is still 3

```bash
curl -s "${JENKINS_URL}/job/lesson9-audit-worker/api/json" \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
print("Job Name        :", data.get("name"))
print("Label Expression:", data.get("labelExpression"))
print("Next Build #    :", data.get("nextBuildNumber"))
print("Builds kept     :", sorted(b["number"] for b in data.get("builds", [])))
'
```

**Expected output:**

```
Job Name        : lesson9-audit-worker
Label Expression: built-in
Next Build #    : 3
Builds kept     : [1, 2]
```

Optional: check the same thing on disk. The WAR runs directly on the Killercoda host, so `JENKINS_HOME` is a normal folder:

```bash
cat "$HOME/jenkins_home/jobs/lesson9-audit-worker/nextBuildNumber"   # -> 3
ls  "$HOME/jenkins_home/jobs/lesson9-audit-worker/builds"            # -> 1  2  (plus permalink files)
```

**Why the history survives:** `instance.getItem(jobName)` returns the existing project, so `createProject` never runs. The script only replaces the job's configuration (label, parameters, builders, publishers) and calls `job.save()`, which rewrites `config.xml`. The `builds/` folder and the `nextBuildNumber` file are not touched.

---

## Task 2: Tree-Filtered Artifact Inspection

**Goal:** a single `curl` + `python3` one-liner that uses `?tree=` to fetch only `number`, `result` and `artifacts[relativePath]` for every build.

### 2.1 The one-liner

```bash
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,result,artifacts[relativePath]]" | python3 -c 'import sys,json; [print("#%s" % b["number"], b["result"], [a["relativePath"] for a in b["artifacts"]]) for b in sorted(json.load(sys.stdin)["builds"], key=lambda b: b["number"])]'
```

**Expected output:**

```
#1 SUCCESS ['audit_report.json']
#2 FAILURE []
```

To see the raw filtered JSON that Jenkins returns, drop the `python3` part:

```bash
curl -s -g "${JENKINS_URL}/job/lesson9-audit-worker/api/json?tree=builds[number,result,artifacts[relativePath]]"; echo
```

### 2.2 What to notice

- **`-g` (`--globoff`) is required.** Without it, curl reads `[...]` as its own URL range syntax and the request fails. The alternative is to URL-encode the brackets as `%5B` and `%5D`.
- **`tree=` is a field whitelist.** `builds[...]` picks fields of each build, and the nested `artifacts[relativePath]` picks one field of each artifact. Jenkins sends nothing else, so the response is much smaller than with `?depth=1`.
- **Build #1 vs #2:** build #1 was a normal run that wrote `audit_report.json` and the archiver saved it. Build #2 was the `FORCE_FAIL=true` run. It exited before writing the report, so there is nothing archived and `artifacts` is `[]`.

> If build #2 shows `['audit_report.json']`: the Artifact Archiver also runs after failed builds by default. A copy of `audit_report.json` left in the workspace by build #1 can get archived again under build #2. That is the stale-workspace effect, not a fresh report. The Appendix shows how to wipe the workspace to avoid it.

---

## Task 3: Environment Parameter Routing

**Goal:** trigger `lesson9-orchestrator` with `TARGET_ENV=dev` and `FORCE_FAIL=false`, then confirm that the downloaded `ingested_audit.json` contains `"environment": "dev"`.

### 3.1 Check the orchestrator's allowed values (spot the problem)

```bash
curl -s -g "${JENKINS_URL}/job/lesson9-orchestrator/api/json?tree=property[parameterDefinitions[name,choices]]" \
  | python3 -c 'import sys,json; [print(p["name"], p.get("choices")) for prop in json.load(sys.stdin)["property"] for p in prop.get("parameterDefinitions", [])]'
```

**Expected output:**

```
TARGET_ENV ['staging', 'prod']
FORCE_FAIL None
```

The Lesson 9 parent job only allows `staging` and `prod`. The worker accepts `dev`, but the orchestrator does not.

### 3.2 (Optional) See Jenkins reject `dev`

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST \
  "${JENKINS_URL}/job/lesson9-orchestrator/buildWithParameters?TARGET_ENV=dev&FORCE_FAIL=false"
```

**Expected:** an error status, **not** `HTTP 201`. Jenkins checks a choice parameter's value against its list, so no build is queued.

### 3.3 Add `dev` to the orchestrator's choices (without touching its build step)

This patch replaces only the parameter definitions. The orchestrator's shell step (`B64_ORCH`) stays as it is, so you don't need to regenerate the orchestrator payload. The heredoc is quoted (`'EOF'`) because the script has no shell variables in it.

```bash
cat << 'EOF' > patch_orchestrator_params.groovy
import jenkins.model.Jenkins
import hudson.model.ParametersDefinitionProperty
import hudson.model.ChoiceParameterDefinition
import hudson.model.BooleanParameterDefinition

def job = Jenkins.get().getItem('lesson9-orchestrator')
if (job == null) {
    println "MISSING_JOB: lesson9-orchestrator"
    return
}

// First choice = default for UI-triggered builds, so keep 'staging' first
job.removeProperty(ParametersDefinitionProperty.class)
def envParam  = new ChoiceParameterDefinition('TARGET_ENV', ['staging', 'prod', 'dev'] as String[], 'Environment to audit')
def failParam = new BooleanParameterDefinition('FORCE_FAIL', false, 'Pass failure flag to downstream worker')
job.addProperty(new ParametersDefinitionProperty(envParam, failParam))

job.save()
println "ORCHESTRATOR_CHOICES: ${envParam.choices}"
EOF

curl -s -X POST "${JENKINS_URL}/scriptText" \
  --data-urlencode "script@patch_orchestrator_params.groovy"

rm -f patch_orchestrator_params.groovy
```

**Expected output:**

```
ORCHESTRATOR_CHOICES: [staging, prod, dev]
```

Re-run the 3.1 command and it now shows `TARGET_ENV ['staging', 'prod', 'dev']`.

### 3.4 Trigger the orchestrator with `TARGET_ENV=dev`, `FORCE_FAIL=false`

```bash
# Trigger (delay=0sec skips the 5 s quiet period) and capture the queue URL from the Location header
QUEUE_URL=$(curl -s -D - -o /dev/null -X POST \
  "${JENKINS_URL}/job/lesson9-orchestrator/buildWithParameters?delay=0sec&TARGET_ENV=dev&FORCE_FAIL=false" \
  | grep -i '^Location:' | awk '{print $2}' | tr -d '\r\n')
echo "Queue item: ${QUEUE_URL:-<none - trigger failed>}"

# Wait for the queue item to get a build number (max 60 s)
ORCH_BUILD=""
for i in $(seq 1 60); do
  ORCH_BUILD=$(curl -s "${QUEUE_URL}api/json" \
    | python3 -c 'import sys,json; e=json.load(sys.stdin).get("executable"); print(e["number"] if e else "")' 2>/dev/null)
  [ -n "${ORCH_BUILD}" ] && break
  sleep 1
done
echo "Orchestrator build: #${ORCH_BUILD}"

# Wait for the build to finish (max ~2 min)
for i in $(seq 1 60); do
  BUILDING=$(curl -s "${JENKINS_URL}/job/lesson9-orchestrator/${ORCH_BUILD}/api/json?tree=building" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["building"])' 2>/dev/null)
  [ "${BUILDING}" = "False" ] && break
  sleep 2
done

# Print the full console output
curl -s "${JENKINS_URL}/job/lesson9-orchestrator/${ORCH_BUILD}/consoleText"
```

You can also open `http://localhost:8080/job/lesson9-orchestrator/lastBuild/console` from Killercoda's **Traffic / Ports** menu (port 8080).

### 3.5 Confirm `"environment": "dev"`

**Expected console excerpt:**

```
--> Triggering 'lesson9-audit-worker' [ENV=dev, FAIL=false, ID=ORD-<n>-<epoch>]...
--> Queue Item Created: http://localhost:8080/queue/item/<id>/
--> Executor Assigned! Child Build #3 is active.
--> Child Build #3 Finished with Result: SUCCESS
==========================================================
  VERIFIED ARTIFACT PAYLOAD (ingested_audit.json)
==========================================================
{
  "request_id": "ORD-<n>-<epoch>",
  "environment": "dev",
  "worker_build": "3",
  "executed_on": "built-in",
  "checks_passed": true
}

[SUCCESS] Round-trip correlation ID (ORD-<n>-<epoch>) verified!
Finished: SUCCESS
```

Quick filter for just the proof line:

```bash
curl -s "${JENKINS_URL}/job/lesson9-orchestrator/${ORCH_BUILD}/consoleText" | grep '"environment"'
# ->   "environment": "dev",
```

**How the value travels:** the orchestrator parameter `TARGET_ENV=dev` becomes `ENV_CHOICE`. The orchestrator passes it to the worker's `buildWithParameters?TARGET_ENV=dev`. The worker writes it into `audit_report.json`, and the orchestrator downloads that artifact over REST as `ingested_audit.json`.

---

## Completion checklist

| # | Check | Expected |
|---|-------|----------|
| 1 | Provisioner output | `UPDATED_EXISTING_JOB: lesson9-audit-worker` |
| 1 | `nextBuildNumber` (before Task 3) | `3` |
| 2 | Tree query, build #1 | `SUCCESS ['audit_report.json']` |
| 2 | Tree query, build #2 | `FAILURE []` |
| 3 | Orchestrator choices | `staging, prod, dev` |
| 3 | `ingested_audit.json` in console | `"environment": "dev"` |
| 3 | Worker `nextBuildNumber` after Task 3 | `4` (build #3 was created by the orchestrator) |

---

## Appendix: Killercoda session was reset, rebuild the Lesson 9 history

Use this if Step 0 shows Jenkins answering (`200`) but the Lesson 9 jobs are missing, for example `ls ~/jenkins_home/jobs` is empty. Killercoda VMs are temporary, so a new session starts with no jobs.

Jenkins must already be running (Step 0b). Paste the whole block below into the Killercoda terminal. It writes `rebuild_lesson9.sh` and runs it, which:

1. creates `lesson9-audit-worker` with the same Groovy provisioner as Task 1.2,
2. runs worker build **#1** (success, archives `audit_report.json`), wipes the workspace, then runs build **#2** (`FORCE_FAIL=true`, no artifact),
3. creates `lesson9-orchestrator` as in the lesson (choices `staging`, `prod`). Task 3 adds `dev`.

Two changes from the lesson's orchestrator script:

- **No `-u "admin:${API_TOKEN}"`.** Security is off. The script uses `set -u`, so an unset `API_TOKEN` would make it crash.
- **The crumb request uses `curl -sf`.** CSRF protection is disabled, so `/crumbIssuer` returns 404. Plain `curl -s` would put that 404 HTML page into the `CRUMB` header.

```bash
cat << 'REBUILD_EOF' > rebuild_lesson9.sh
#!/usr/bin/env bash
set -euo pipefail
JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
WORKER="lesson9-audit-worker"

# Wait until build $2 of job $1 has finished, then print its result
wait_for_build() {
  local r=""
  for _ in $(seq 1 60); do
    r=$(curl -s "${JENKINS_URL}/job/$1/$2/api/json?tree=building,result" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print("" if d["building"] else d["result"])' 2>/dev/null || true)
    if [ -n "${r}" ]; then echo "--> $1 #$2 finished: ${r}"; return 0; fi
    sleep 2
  done
  echo "[ERROR] $1 #$2 did not finish within 2 minutes"; return 1
}

# ---------- 1. Worker payload ----------
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

echo "[SUCCESS] audit_report.json generated in ${WORKSPACE}"
EOF
B64_WORKER=$(base64 -w 0 worker_payload.sh)
rm -f worker_payload.sh

# ---------- 2. Worker job (same provisioner as Task 1.2) ----------
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

job.getPublishersList().clear()
job.getPublishersList().add(new ArtifactArchiver('audit_report.json'))

job.save()
println "LESSON9_WORKER_READY"
EOF
curl -s -X POST "${JENKINS_URL}/scriptText" --data-urlencode "script@provision_lesson9_worker.groovy"
rm -f provision_lesson9_worker.groovy

# ---------- 3. Worker history: #1 success, #2 failure ----------
NEXT=$(curl -s "${JENKINS_URL}/job/${WORKER}/api/json?tree=nextBuildNumber" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["nextBuildNumber"])')
if [ "${NEXT}" != "1" ]; then
  echo "== Worker already has builds (next is #${NEXT}), so the history rebuild is skipped"
else
  echo "== Worker build #1 (success, archives audit_report.json)"
  curl -s -X POST "${JENKINS_URL}/job/${WORKER}/buildWithParameters?delay=0sec&TARGET_ENV=staging&REQUEST_ID=REQ-001&FORCE_FAIL=false"
  wait_for_build "${WORKER}" 1

  echo "== Wiping workspace so build #2 can't re-archive build #1's file"
  curl -s -o /dev/null -X POST "${JENKINS_URL}/job/${WORKER}/doWipeOutWorkspace"

  echo "== Worker build #2 (forced failure, no artifact)"
  curl -s -X POST "${JENKINS_URL}/job/${WORKER}/buildWithParameters?delay=0sec&TARGET_ENV=staging&REQUEST_ID=REQ-002&FORCE_FAIL=true"
  wait_for_build "${WORKER}" 2
fi

# ---------- 4. Orchestrator payload (lesson version, no auth) ----------
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

# 6. Retrieve & Validate Artifact over REST
ARTIFACT_URL="${JENKINS_URL}/job/${CHILD_JOB}/${CHILD_BUILD_NUM}/artifact/audit_report.json"
curl -s -f -o "ingested_audit.json" "${ARTIFACT_URL}"

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

# ---------- 5. Orchestrator job (lesson version: staging, prod) ----------
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

def job = instance.getItem(jobName) ?: instance.createProject(FreeStyleProject, jobName)
job.setAssignedLabel(new LabelAtom('built-in'))

job.removeProperty(ParametersDefinitionProperty.class)
def envParam = new ChoiceParameterDefinition('TARGET_ENV', ['staging', 'prod'] as String[], 'Environment to audit')
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

# ---------- 6. Summary ----------
echo "== Jobs now in Jenkins:"
curl -s -g "${JENKINS_URL}/api/json?tree=jobs[name]" \
  | python3 -c 'import sys,json; [print("   ", j["name"]) for j in json.load(sys.stdin)["jobs"]]'
curl -s "${JENKINS_URL}/job/${WORKER}/api/json?tree=nextBuildNumber" \
  | python3 -c 'import sys,json; print("== Worker nextBuildNumber:", json.load(sys.stdin)["nextBuildNumber"])'
REBUILD_EOF

bash rebuild_lesson9.sh
```

**Expected output:**

```
CREATED_NEW_JOB: lesson9-audit-worker
LESSON9_WORKER_READY
== Worker build #1 (success, archives audit_report.json)
--> lesson9-audit-worker #1 finished: SUCCESS
== Wiping workspace so build #2 can't re-archive build #1's file
== Worker build #2 (forced failure, no artifact)
--> lesson9-audit-worker #2 finished: FAILURE
LESSON9_PARENT_READY
== Jobs now in Jenkins:
    lesson9-audit-worker
    lesson9-orchestrator
== Worker nextBuildNumber: 3
```

`CREATED_NEW_JOB` is correct here because the job really is new. Now go back to **Task 1**. Its provisioner run must print `UPDATED_EXISTING_JOB`, and `nextBuildNumber` must still be `3`.
