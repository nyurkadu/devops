
# ---- Install Java 17 (replaces the jdk17 image) ----
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk-headless wget

# ---- Settings (replaces -p and -v) ----
JENKINS_DIR=$HOME/jenkins
export JENKINS_HOME=$HOME/jenkins_home   # replaces the jenkins_home volume
mkdir -p "$JENKINS_DIR" "$JENKINS_HOME"

# ---- Download the LTS WAR once ----
[ -f "$JENKINS_DIR/jenkins.war" ] || wget -O "$JENKINS_DIR/jenkins.war" https://get.jenkins.io/war-stable/latest/jenkins.war

# ---- Start in background WITHOUT WIZARD (replaces docker run -d and JAVA_OPTS) ----
nohup java \
  -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar "$JENKINS_DIR/jenkins.war" --httpPort=8080 \
  > "$JENKINS_DIR/jenkins.log" 2>&1 &
echo $! > "$JENKINS_DIR/jenkins.pid"
## 1. Create the worker shell payload
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

B64_WORKER=$(base64 -w 0 worker_payload.sh 2>/dev/null || base64 worker_payload.sh | tr -d '\n')
rm -f worker_payload.sh

********************************************

# 2. Create the idempotent Groovy provisioner
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

# 3. Deploy via REST scriptText
curl -s -X POST "http://localhost:8080/scriptText" \
  -u "admin:${API_TOKEN}" \
  --data-urlencode "script@provision_lesson9_worker.groovy"

rm -f provision_lesson9_worker.groovy


*********************************

curl -s -u "admin:${API_TOKEN}" "http://localhost:8080/job/lesson9-audit-worker/api/json" \
  | python3 -c '
import sys, json
data = json.load(sys.stdin)
print("Job Name        :", data.get("name"))
print("Label Expression:", data.get("labelExpression"))
print("Next Build #    :", data.get("nextBuildNumber"))
'





# 1. Create the orchestrator shell script
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

# 1. Obtain CSRF Crumb cleanly
CRUMB=$(curl -s -u "admin:${API_TOKEN}" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)

# 2. Trigger parameterized child job and capture response headers
echo "--> Triggering '${CHILD_JOB}' [ENV=${ENV_CHOICE}, FAIL=${SIMULATE_FAIL}, ID=${TRACKING_ID}]..."
HEADER_FILE="/tmp/headers_${BUILD_NUMBER}.txt"

TRIGGER_URL="${JENKINS_URL}/job/${CHILD_JOB}/buildWithParameters?TARGET_ENV=${ENV_CHOICE}&REQUEST_ID=${TRACKING_ID}&FORCE_FAIL=${SIMULATE_FAIL}"

if [ -n "${CRUMB}" ]; then
    curl -s -D "${HEADER_FILE}" -X POST -H "${CRUMB}" -u "admin:${API_TOKEN}" "${TRIGGER_URL}" > /dev/null
else
    curl -s -D "${HEADER_FILE}" -X POST -u "admin:${API_TOKEN}" "${TRIGGER_URL}" > /dev/null
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

    QUEUE_JSON=$(curl -s -u "admin:${API_TOKEN}" "${QUEUE_URL}api/json")

    # Check if item was cancelled while queued
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
    BUILD_JSON=$(curl -s -u "admin:${API_TOKEN}" "${JENKINS_URL}/job/${CHILD_JOB}/${CHILD_BUILD_NUM}/api/json")
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
curl -s -f -u "admin:${API_TOKEN}" -o "ingested_audit.json" "${ARTIFACT_URL}"

echo "=========================================================="
echo "  VERIFIED ARTIFACT PAYLOAD (ingested_audit.json)"
echo "=========================================================="
cat ingested_audit.json
echo ""

# Verify tracking ID round-trip
RETURNED_ID=$(python3 -c 'import json; print(json.load(open("ingested_audit.json")).get("request_id"))')
if [ "${RETURNED_ID}" != "${TRACKING_ID}" ]; then
    echo "[ERROR] Artifact mismatch! Expected ${TRACKING_ID}, got ${RETURNED_ID}"
    exit 1
fi

echo "[SUCCESS] Round-trip correlation ID (${RETURNED_ID}) verified!"
EOF



# Inject API_TOKEN safely into payload before encoding
sed -i "s/\${API_TOKEN}/${API_TOKEN}/g" orchestrator_payload.sh
B64_ORCH=$(base64 -w 0 orchestrator_payload.sh 2>/dev/null || base64 orchestrator_payload.sh | tr -d '\n')
rm -f orchestrator_payload.sh



*******************************


# 2. Provision Parent Job via Groovy
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

curl -s -X POST "http://localhost:8080/scriptText" \
  -u "admin:${API_TOKEN}" \
  --data-urlencode "script@provision_lesson9_parent.groovy"

rm -f provision_lesson9_parent.groovy

*************************************************

JENKINS_URL="http://localhost:8080"
JOB_NAME="lesson9-audit-worker"
TRACKING_ID="ORD-$(date +%s)"

echo "=========================================================="
echo "  ANGLE 3: END-TO-END CONTRACT VALIDATION"
echo "=========================================================="

# 1. Trigger with delay=0sec (skips 5s quiet period) & capture Queue URL
QUEUE_URL=$(curl -s -D - -o /dev/null -X POST \
  "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters?delay=0sec&TARGET_ENV=prod&REQUEST_ID=${TRACKING_ID}&FORCE_FAIL=false" \
  | grep -i "^Location:" | awk '{print $2}' | tr -d '\r\n')

echo "--> Dispatched REQUEST_ID=${TRACKING_ID} -> Queue: ${QUEUE_URL}"
sleep 3

# 2. Resolve exact Build Number from the Queue Item (fallback to lastBuild if already evicted)
BUILD_NUM=$(curl -s "${QUEUE_URL}api/json?tree=executable[number]" \
  | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
[ -z "${BUILD_NUM}" ] && BUILD_NUM=$(curl -s "${JENKINS_URL}/job/${JOB_NAME}/lastBuild/api/json?tree=number" \
  | sed -n 's/.*"number":\([0-9]*\).*/\1/p')

RESULT=$(curl -s "${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/api/json?tree=result" \
  | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
echo "--> Exact Build #${BUILD_NUM} Result: ${RESULT}"

# 3. Download artifact from that exact build and verify contract
curl -s -f -o "verified_audit.json" "${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}/artifact/audit_report.json"

echo -e "\n=== DOWNLOADED ARTIFACT (verified_audit.json) ==="
cat verified_audit.json
echo ""

RETURNED_ID=$(sed -n 's/.*"request_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' verified_audit.json)

if [ "${RETURNED_ID}" = "${TRACKING_ID}" ]; then
    echo "[VERIFIED] Round-trip contract passed! Sent '${TRACKING_ID}' == Received '${RETURNED_ID}'."
else
    echo "[FAILED] Contract mismatch! Expected '${TRACKING_ID}', got '${RETURNED_ID}'."
fi

*********************************