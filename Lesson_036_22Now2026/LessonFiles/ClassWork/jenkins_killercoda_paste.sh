# Jenkins on Killercoda (Ubuntu 24.04) - paste-ready blocks
# Same scripts as jenkins_killercoda_install.md (full explanation and troubleshooting there).
#
# DO NOT run this file and DO NOT paste the whole file.
# Copy ONE block, from "#=== BEGIN x ===" to "#=== END x ===", and paste it into the
# Killercoda terminal (Ctrl+V or right-click -> Paste). Blocks A and B create the script and run it.
#
#   GET - download this file from GitHub into Killercoda and extract both scripts
#         (a short block: paste it instead of the long A or B blocks)
#   A  - install Jenkins WITH the setup wizard
#   A2 - after the wizard: save your API token (asks you to paste it)
#   B  - install Jenkins WITHOUT the setup wizard (admin/admin123 + API token)
#        set CREATE_ADMIN=no on its first line for a Jenkins with no login
#   C  - status: URL, HTTP check, last log lines (safe to paste any time)
#   D  - restart Jenkins and KEEP jobs/users (A and B always wipe ~/jenkins_home)
#   E  - stop Jenkins
#
# Both install scripts: apt-get update + upgrade, Java 21, Jenkins LTS WAR on port 8080,
# data in ~/jenkins_home, log in ~/jenkins/jenkins.log, variables in ~/jenkins.env.
#
# Copy a block from the VS Code PowerShell terminal instead of selecting it by hand:
#   cd C:\Users\avila\devops\CloudLessons\Lesson_036_22Now2026\LessonFiles\ClassWork
#   $f = Get-Content -Raw .\jenkins_killercoda_paste.sh
#   [regex]::Match($f, '(?sm)^#=== BEGIN A ===\r?$.*?^#=== END A ===\r?$').Value.Replace("`r","") | Set-Clipboard
#   (for another block, replace both A with GET, A2, B, C, D or E)

# Guard: stop if someone runs this file with bash instead of pasting one block.
[ -z "${BASH_SOURCE[0]:-}" ] || { echo "Don't run this file. Paste one block into the Killercoda terminal."; return 1 2>/dev/null || exit 1; }


#=== BEGIN GET ===
# GET - download the scripts from GitHub (public repo nyurkadu/devops) into Killercoda.
# Works only after this file is pushed to the master branch.
URL=https://raw.githubusercontent.com/nyurkadu/devops/master/Lesson_036_22Now2026/LessonFiles/ClassWork/jenkins_killercoda_paste.sh
curl -fsSL "$URL" -o ~/jenkins_killercoda_paste.sh && echo "downloaded: $(grep -c '^#=== BEGIN' ~/jenkins_killercoda_paste.sh) blocks (must be 7)"
for s in jenkins_with_wizard jenkins_no_wizard; do
  awk -v s="cat > ~/$s.sh" '$0=="SCRIPT"{f=0} f; index($0,s)==1{f=1}' ~/jenkins_killercoda_paste.sh > ~/$s.sh
  bash -n ~/$s.sh && echo "~/$s.sh ready ($(wc -l < ~/$s.sh) lines)"
done
echo "Next, run ONE of these:"
echo '  bash ~/jenkins_with_wizard.sh                                        # A: WITH wizard'
echo '  bash ~/jenkins_no_wizard.sh && source ~/jenkins.env                  # B: WITHOUT wizard, admin/admin123'
echo '  CREATE_ADMIN=no bash ~/jenkins_no_wizard.sh && source ~/jenkins.env  # B: WITHOUT wizard, no login'
#=== END GET ===


#=== BEGIN A ===
# A - install Jenkins WITH the setup wizard. Prints the unlock password at the end.
cat > ~/jenkins_with_wizard.sh << 'SCRIPT'
#!/usr/bin/env bash
# Jenkins on Killercoda (Ubuntu 24.04) - WITH the setup wizard.
# Fresh start: stops any running jenkins.war and deletes ~/jenkins_home.
set -euo pipefail

PORT="${PORT:-8080}"
JENKINS_DIR="$HOME/jenkins"                # jenkins.war, jenkins.log, jenkins.pid
export JENKINS_HOME="$HOME/jenkins_home"   # jobs, users, plugins
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

step() { echo; echo "==> $*"; }
apt_get() {
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

step "1/5 System update and upgrade (1-3 minutes)"
apt_get update
apt_get upgrade

step "2/5 Install Java 21, fontconfig, wget, curl"
apt_get install openjdk-21-jre-headless fontconfig wget curl
JAVA_BIN=$(ls -d /usr/lib/jvm/java-21-openjdk-*/bin/java | head -n1)
"$JAVA_BIN" -version 2>&1 | head -n1

step "3/5 Stop old Jenkins and wipe old data"
pkill -f 'jenkins\.war' || true
for i in $(seq 1 30); do pgrep -f 'jenkins\.war' >/dev/null || break; sleep 1; done
if curl -s -o /dev/null --max-time 3 "http://localhost:$PORT/"; then
  echo "[ERROR] Port $PORT is still in use:"; $SUDO ss -ltnp | grep ":$PORT " || true
  echo "If it is the Docker container, remove it: docker rm -f my-jenkins"; exit 1
fi
rm -rf "$JENKINS_HOME"
mkdir -p "$JENKINS_DIR" "$JENKINS_HOME"

step "4/5 Download Jenkins LTS (~95 MB) and start it on port $PORT"
if [ ! -s "$JENKINS_DIR/jenkins.war" ]; then
  wget -q --show-progress -O "$JENKINS_DIR/jenkins.war.part" https://get.jenkins.io/war-stable/latest/jenkins.war
  mv "$JENKINS_DIR/jenkins.war.part" "$JENKINS_DIR/jenkins.war"
fi
nohup "$JAVA_BIN" -Djava.awt.headless=true \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar "$JENKINS_DIR/jenkins.war" --httpPort="$PORT" > "$JENKINS_DIR/jenkins.log" 2>&1 &
echo $! > "$JENKINS_DIR/jenkins.pid"

step "5/5 Wait for Jenkins (up to 3 minutes)"
for i in $(seq 1 90); do
  grep -qF "Jenkins is fully up and running" "$JENKINS_DIR/jenkins.log" && break
  kill -0 "$(cat "$JENKINS_DIR/jenkins.pid")" 2>/dev/null || break
  sleep 2
done
if ! grep -qF "Jenkins is fully up and running" "$JENKINS_DIR/jenkins.log"; then
  echo "[ERROR] Jenkins did not start. Last lines of $JENKINS_DIR/jenkins.log:"
  tail -n 30 "$JENKINS_DIR/jenkins.log"; exit 1
fi

UNLOCK=$(cat "$JENKINS_HOME/secrets/initialAdminPassword")
echo "export JENKINS_URL=\"http://localhost:$PORT\"" > "$HOME/jenkins.env"

cat << MSG

==================================================================
 Jenkins is running - WITH setup wizard
 URL (this terminal) : http://localhost:$PORT
 URL (browser)       : Killercoda menu -> Traffic / Ports -> $PORT
 Unlock password     : $UNLOCK
 Password file       : $JENKINS_HOME/secrets/initialAdminPassword
 Log                 : $JENKINS_DIR/jenkins.log
==================================================================
Finish in the browser:
 1. Paste the unlock password -> Continue
 2. Install suggested plugins (2-4 minutes)
 3. Create First Admin User: admin / admin123
 4. Instance Configuration -> Save and Finish -> Start using Jenkins
 5. Create an API token (see "A.3" in the guide)
MSG
SCRIPT
bash -n ~/jenkins_with_wizard.sh && bash ~/jenkins_with_wizard.sh
#=== END A ===


#=== BEGIN A2 ===
# A2 - after the wizard: admin (top right) -> Security -> API Token -> Add new Token -> Generate -> copy.
# Paste this line, then paste the token when it asks and press Enter.
read -rp "Paste the API token: " T && echo "export API_TOKEN=\"$T\"" >> ~/jenkins.env && source ~/jenkins.env && curl -s -u "admin:${API_TOKEN}" "${JENKINS_URL}/whoAmI/api/json"; echo
#=== END A2 ===


#=== BEGIN B ===
# B - install Jenkins WITHOUT the setup wizard.
# CREATE_ADMIN=yes -> user admin / admin123 + API token (anonymous gets 403)
# CREATE_ADMIN=no  -> no login at all (security off, like Lessons 033/034)
CREATE_ADMIN=yes
cat > ~/jenkins_no_wizard.sh << 'SCRIPT'
#!/usr/bin/env bash
# Jenkins on Killercoda (Ubuntu 24.04) - WITHOUT the setup wizard.
# Fresh start: stops any running jenkins.war and deletes ~/jenkins_home.
# CREATE_ADMIN=yes (default): user admin/admin123 + API token, anonymous gets 403.
# CREATE_ADMIN=no           : no login at all (security off, like Lessons 033/034).
set -euo pipefail

PORT="${PORT:-8080}"
CREATE_ADMIN="${CREATE_ADMIN:-yes}"
ADMIN_USER="admin"; ADMIN_PASS="admin123"
JENKINS_DIR="$HOME/jenkins"                # jenkins.war, jenkins.log, jenkins.pid
export JENKINS_HOME="$HOME/jenkins_home"   # jobs, users, plugins
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

step() { echo; echo "==> $*"; }
apt_get() {
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y -q \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

step "1/6 System update and upgrade (1-3 minutes)"
apt_get update
apt_get upgrade

step "2/6 Install Java 21, fontconfig, wget, curl"
apt_get install openjdk-21-jre-headless fontconfig wget curl
JAVA_BIN=$(ls -d /usr/lib/jvm/java-21-openjdk-*/bin/java | head -n1)
"$JAVA_BIN" -version 2>&1 | head -n1

step "3/6 Stop old Jenkins and wipe old data"
pkill -f 'jenkins\.war' || true
for i in $(seq 1 30); do pgrep -f 'jenkins\.war' >/dev/null || break; sleep 1; done
if curl -s -o /dev/null --max-time 3 "http://localhost:$PORT/"; then
  echo "[ERROR] Port $PORT is still in use:"; $SUDO ss -ltnp | grep ":$PORT " || true
  echo "If it is the Docker container, remove it: docker rm -f my-jenkins"; exit 1
fi
rm -rf "$JENKINS_HOME"
mkdir -p "$JENKINS_DIR" "$JENKINS_HOME"

step "4/6 Download Jenkins LTS (~95 MB) and start it on port $PORT, no wizard"
if [ ! -s "$JENKINS_DIR/jenkins.war" ]; then
  wget -q --show-progress -O "$JENKINS_DIR/jenkins.war.part" https://get.jenkins.io/war-stable/latest/jenkins.war
  mv "$JENKINS_DIR/jenkins.war.part" "$JENKINS_DIR/jenkins.war"
fi
nohup "$JAVA_BIN" -Djava.awt.headless=true \
  -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar "$JENKINS_DIR/jenkins.war" --httpPort="$PORT" > "$JENKINS_DIR/jenkins.log" 2>&1 &
echo $! > "$JENKINS_DIR/jenkins.pid"

step "5/6 Wait for Jenkins (up to 3 minutes)"
for i in $(seq 1 90); do
  grep -qF "Jenkins is fully up and running" "$JENKINS_DIR/jenkins.log" && break
  kill -0 "$(cat "$JENKINS_DIR/jenkins.pid")" 2>/dev/null || break
  sleep 2
done
if ! grep -qF "Jenkins is fully up and running" "$JENKINS_DIR/jenkins.log"; then
  echo "[ERROR] Jenkins did not start. Last lines of $JENKINS_DIR/jenkins.log:"
  tail -n 30 "$JENKINS_DIR/jenkins.log"; exit 1
fi

URL="http://localhost:$PORT"
echo "export JENKINS_URL=\"$URL\"" > "$HOME/jenkins.env"
if [ "$CREATE_ADMIN" = "yes" ]; then
  step "6/6 Create user $ADMIN_USER and an API token"
  API_TOKEN=$(curl -s -X POST "$URL/scriptText" --data-urlencode "script=
import jenkins.model.*
import hudson.security.*
import jenkins.security.ApiTokenProperty
def j = Jenkins.get()
def realm = new HudsonPrivateSecurityRealm(false)
def u = realm.createAccount('$ADMIN_USER', '$ADMIN_PASS')
u.save()
j.setSecurityRealm(realm)
def s = new FullControlOnceLoggedInAuthorizationStrategy()
s.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(s)
def t = u.getProperty(ApiTokenProperty.class).tokenStore.generateNewToken('MasterKey')
u.save()
j.save()
print t.plainValue" | tr -d '\r\n')
  if ! [[ "$API_TOKEN" =~ ^[0-9a-f]{32,}$ ]]; then
    echo "[ERROR] No API token returned:"; echo "$API_TOKEN" | head -c 500; echo; exit 1
  fi
  echo "export API_TOKEN=\"$API_TOKEN\"" >> "$HOME/jenkins.env"
  AUTH=(-u "$ADMIN_USER:$API_TOKEN")
  LOGIN="$ADMIN_USER / $ADMIN_PASS"
else
  step "6/6 Skipped: no user (CREATE_ADMIN=no), security is off"
  API_TOKEN=""; AUTH=(); LOGIN="none - security is off"
fi

C_AUTH=$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$URL/api/json")
C_ANON=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/json")

cat << MSG

==================================================================
 Jenkins is running - WITHOUT setup wizard
 URL (this terminal) : $URL
 URL (browser)       : Killercoda menu -> Traffic / Ports -> $PORT
 Login               : $LOGIN
 API token           : ${API_TOKEN:-none}
 Check /api/json     : with token -> $C_AUTH, anonymous -> $C_ANON
 Log                 : $JENKINS_DIR/jenkins.log
==================================================================
Load the variables into your terminal:  source ~/jenkins.env
MSG
SCRIPT
bash -n ~/jenkins_no_wizard.sh && CREATE_ADMIN=$CREATE_ADMIN bash ~/jenkins_no_wizard.sh && source ~/jenkins.env
#=== END B ===


#=== BEGIN C ===
# C - status (safe to paste any time, also in a new Killercoda tab)
source ~/jenkins.env; echo "JENKINS_URL=$JENKINS_URL  API_TOKEN=${API_TOKEN:-none}"
curl -s -o /dev/null -w "HTTP %{http_code} on $JENKINS_URL/login\n" "$JENKINS_URL/login"
pgrep -af 'jenkins\.war' || echo "Jenkins is not running"
tail -n 5 ~/jenkins/jenkins.log
#=== END C ===


#=== BEGIN D ===
# D - restart Jenkins and KEEP the data in ~/jenkins_home (port 8080)
pkill -f 'jenkins\.war'; sleep 5
JENKINS_HOME=$HOME/jenkins_home nohup java -Djava.awt.headless=true \
  -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &
echo $! > ~/jenkins/jenkins.pid
for i in $(seq 1 90); do grep -qF "Jenkins is fully up and running" ~/jenkins/jenkins.log && break; sleep 2; done; tail -n 3 ~/jenkins/jenkins.log
#=== END D ===


#=== BEGIN E ===
# E - stop Jenkins (data stays in ~/jenkins_home; start again with D)
pkill -f 'jenkins\.war' && echo "Jenkins stopped" || echo "Jenkins was not running"
#=== END E ===
