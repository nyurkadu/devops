# Install Jenkins on Killercoda: with or without the setup wizard

Two independent scripts for a **Killercoda Ubuntu 24.04** VM. Use the one the task asks for.

> **Paste-ready version:** [jenkins_killercoda_paste.sh](jenkins_killercoda_paste.sh) has the same scripts as blocks A–E.
> Each block is one paste: it creates the script and runs it. Copy one block at a time, never the whole file.

| | Script A: WITH wizard | Script B: WITHOUT wizard |
| --- | --- | --- |
| File | `~/jenkins_with_wizard.sh` | `~/jenkins_no_wizard.sh` |
| Login | You create it in the wizard (use `admin` / `admin123`) | `admin` / `admin123`, created by the script |
| API token | You create it in the UI after the wizard | Created by the script (name `MasterKey`) |
| Plugins | "Install suggested plugins" in the wizard | None (Freestyle + shell jobs need none) |
| URL in the terminal | `http://localhost:8080` | `http://localhost:8080` |

Both scripts do the same base steps:

1. `apt-get update` and `apt-get upgrade` (non-interactive, so no prompts).
2. Install Java 21, `fontconfig`, `wget`, `curl`.
3. Stop any running `jenkins.war` and **delete `~/jenkins_home`**, so you always get a fresh Jenkins.
4. Download the Jenkins LTS WAR to `~/jenkins/jenkins.war` and start it in the background on port 8080.
5. Wait until the log says `Jenkins is fully up and running`.
6. Write `~/jenkins.env` with `JENKINS_URL` (and `API_TOKEN` in Script B).

Both scripts disable CSRF protection (lab only), so `curl -X POST` calls need no crumb.

> Jenkins runs directly on the VM (as in Lesson 033), not in Docker. That avoids Docker Hub pull limits on Killercoda.
> The `docker run ... my-jenkins` commands from Lessons 032/034 also use port 8080, so don't run both at the same time.

---

## Where each part runs

| Part | Runs in |
| --- | --- |
| Scripts A and B, and every `bash` block in this file | **Killercoda terminal** in the browser (Ubuntu, bash) |
| Copying a script to the clipboard, calling Jenkins from your PC | **VS Code terminal** on Windows (PowerShell) |

PowerShell can't run these scripts, and `localhost` on your PC is **not** the Killercoda VM.

### Copy a script to the clipboard (PowerShell, VS Code terminal)

Long blocks are easy to mis-select, so let PowerShell copy the exact block:

```powershell
cd C:\Users\avila\devops\CloudLessons\Lesson_036_22Now2026\LessonFiles\ClassWork
$md = Get-Content -Raw .\jenkins_killercoda_install.md
$b  = [regex]::Matches($md, '(?s)cat > ~/jenkins_\w+\.sh << ''SCRIPT''.*?\nSCRIPT(?=\r?\n)')
"blocks found: $($b.Count)"                            # must be 2
$b[0].Value.Replace("`r", "") | Set-Clipboard          # Script A: WITH wizard
# $b[1].Value.Replace("`r", "") | Set-Clipboard        # Script B: WITHOUT wizard
```

Then click into the Killercoda terminal, paste with **Ctrl+V** (or right-click → **Paste**), and press **Enter**.
Then run the A.2 or B.2 command.

### Or download the scripts in Killercoda (bash, short paste)

This only works after `jenkins_killercoda_paste.sh` is pushed to `master` of the public repo `nyurkadu/devops`.
Paste into the **Killercoda terminal**:

```bash
URL=https://raw.githubusercontent.com/nyurkadu/devops/master/Lesson_036_22Now2026/LessonFiles/ClassWork/jenkins_killercoda_paste.sh
curl -fsSL "$URL" -o ~/jenkins_killercoda_paste.sh && echo "downloaded: $(grep -c '^#=== BEGIN' ~/jenkins_killercoda_paste.sh) blocks (must be 7)"
for s in jenkins_with_wizard jenkins_no_wizard; do
  awk -v s="cat > ~/$s.sh" '$0=="SCRIPT"{f=0} f; index($0,s)==1{f=1}' ~/jenkins_killercoda_paste.sh > ~/$s.sh
  bash -n ~/$s.sh && echo "~/$s.sh ready ($(wc -l < ~/$s.sh) lines)"
done
```

Expected: `downloaded: 7 blocks`, `jenkins_with_wizard.sh ready (77 lines)`, `jenkins_no_wizard.sh ready (109 lines)`.
Then run **one** of these:

```bash
bash ~/jenkins_with_wizard.sh                                          # Script A: WITH wizard
bash ~/jenkins_no_wizard.sh && source ~/jenkins.env                    # Script B: WITHOUT wizard, admin/admin123
CREATE_ADMIN=no bash ~/jenkins_no_wizard.sh && source ~/jenkins.env    # Script B: WITHOUT wizard, no login
```

`curl: (22) ... 404` means the file isn't on GitHub yet, or the push was less than ~5 minutes ago (GitHub caches raw files).

### Call Killercoda Jenkins from PowerShell (optional)

Use the URL from **Traffic / Ports** (see below), not `localhost`:

```powershell
$JenkinsUrl    = "https://<id>-8080.<region>.killercoda.com"   # copy from the browser address bar, no trailing /
$env:API_TOKEN = "<token printed by the script>"
curl.exe -s -u "admin:$env:API_TOKEN" "$JenkinsUrl/whoAmI/api/json"
```

Use `curl.exe`, not `curl`. If you get a Killercoda HTML page instead of JSON, run the commands in the Killercoda terminal instead.

---

## How to open Jenkins in your browser

Killercoda doesn't give you a public IP. In the terminal, Jenkins is `http://localhost:8080`.
For the browser:

1. Open the Killercoda menu (top right) → **Traffic / Ports**.
2. Enter port **8080** → **Access**.
3. A URL like `https://<id>-8080.<region>.killercoda.com/` opens Jenkins.

If you get `502 Bad Gateway`, Jenkins isn't listening yet. Wait for the script to finish.

---

## Script A: WITH the setup wizard

### A.1 Create the script

Paste the whole block into the Killercoda terminal:

```bash
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
```

### A.2 Check the paste and run it

```bash
bash -n ~/jenkins_with_wizard.sh && bash ~/jenkins_with_wizard.sh
```

`bash -n` checks the syntax first. If it says `unexpected end of file`, the paste got cut off. Paste A.1 again.

At the end the script prints the **unlock password**. If you need it again later:

```bash
cat ~/jenkins_home/secrets/initialAdminPassword
```

### Browser steps

1. **Unlock Jenkins**: paste the unlock password → **Continue**.
2. **Customize Jenkins**: **Install suggested plugins**. Wait until all of them turn green.
3. **Create First Admin User**: username `admin`, password `admin123`, any full name and e-mail → **Save and Continue**.
   Use `admin`, because the lesson snippets use `-u "admin:${API_TOKEN}"`.
4. **Instance Configuration**: keep the URL → **Save and Finish** → **Start using Jenkins**.

### A.3 Create the API token (after the wizard)

1. Click **admin** (top right) → **Security** → **API Token** → **Add new Token**.
2. Name it `MasterKey` → **Generate** → copy the value. Jenkins shows it only once.
3. In the terminal:

```bash
echo 'export API_TOKEN="PASTE-THE-TOKEN-HERE"' >> ~/jenkins.env
source ~/jenkins.env
curl -s -u "admin:${API_TOKEN}" "${JENKINS_URL}/whoAmI/api/json"; echo
```

Expected: JSON with `"authenticated":true` and `"name":"admin"`.

---

## Script B: WITHOUT the setup wizard

### B.1 Create the script

```bash
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
```

### B.2 Check the paste and run it

Default (user `admin` / `admin123` + API token):

```bash
bash -n ~/jenkins_no_wizard.sh && bash ~/jenkins_no_wizard.sh
source ~/jenkins.env
```

Expected check line: `with token -> 200, anonymous -> 403`.

Open Jenkins with no login at all (security off, as in Lessons 033/034):

```bash
CREATE_ADMIN=no bash ~/jenkins_no_wizard.sh
source ~/jenkins.env
```

Expected check line: `with token -> 200, anonymous -> 200`.

### B.3 Verify

```bash
curl -s -u "admin:${API_TOKEN}" "${JENKINS_URL}/whoAmI/api/json"; echo
```

> The script runs in its own shell, so `$API_TOKEN` is **not** set in your terminal until you run `source ~/jenkins.env`.

---

## After either script

```bash
# New Killercoda tab? Variables are gone. Load them again:
source ~/jenkins.env && echo "$JENKINS_URL  token=${API_TOKEN:-none}"

# Is Jenkins up?
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$JENKINS_URL/login"

# Log
tail -f ~/jenkins/jenkins.log          # Ctrl+C to stop following

# Stop Jenkins
pkill -f 'jenkins\.war'
```

Restart Jenkins **without** losing jobs and users (the scripts always wipe the data, so don't rerun them for this):

```bash
pkill -f 'jenkins\.war'; sleep 5
JENKINS_HOME=$HOME/jenkins_home nohup java -Djava.awt.headless=true \
  -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &
```

`JENKINS_HOME=...` is required. Without it, Jenkins starts with an empty `~/.jenkins` and asks for the wizard again.

A new Killercoda session starts with an empty VM. Just run the script again.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `bash -n`: `unexpected end of file` | The paste got cut off | Paste the `cat > ... << 'SCRIPT'` block again |
| `Could not get lock /var/lib/dpkg/lock-frontend` | Ubuntu's auto-update is still running | The script waits up to 5 minutes. If it still fails, run it again |
| `[ERROR] Port 8080 is still in use` | The Docker `my-jenkins` from the lesson, or another app | `docker rm -f my-jenkins`, or run with another port: `PORT=8081 bash ~/jenkins_no_wizard.sh` |
| `[ERROR] Jenkins did not start` + `UnsupportedClassVersionError` or `minimum required version` | Java too old for this Jenkins | The script installs Java 21. Check `ls /usr/lib/jvm` |
| `[ERROR] No API token returned` | `/scriptText` returned an HTML error page | Check `tail -n 50 ~/jenkins/jenkins.log`, then run the script again |
| `HTTP 401` with `-u admin:$API_TOKEN` | `$API_TOKEN` is empty (new tab) or belongs to another user | `source ~/jenkins.env`, and use `admin:` |
| `HTTP 403` without `-u` | Script B with `CREATE_ADMIN=yes` blocks anonymous access | Add `-u "admin:${API_TOKEN}"`, or rerun with `CREATE_ADMIN=no` |
| Browser: `502 Bad Gateway` | Jenkins not up yet, or wrong port in Traffic / Ports | Wait for the script to finish, use port 8080 |
| Browser: "Jenkins is getting ready to work" | Still starting | Wait 30 seconds and reload |
| Manage Jenkins: "reverse proxy setup is broken" | Killercoda's HTTPS proxy | Harmless in the lab, ignore it |
| Pipeline job type is missing (Script B) | No plugins are installed without the wizard | Manage Jenkins → Plugins → Available → install **Pipeline**. Freestyle + shell jobs work without plugins |

---

## Credentials summary

| Where | URL | User / password | Token |
| --- | --- | --- | --- |
| Killercoda, Script A (wizard) | `http://localhost:8080` | unlock: `~/jenkins_home/secrets/initialAdminPassword`, then `admin` / `admin123` (your choice in the wizard) | create in UI (A.3) |
| Killercoda, Script B (default) | `http://localhost:8080` | `admin` / `admin123` | in `~/jenkins.env` |
| Killercoda, Script B (`CREATE_ADMIN=no`) | `http://localhost:8080` | none | not needed |
| Local Windows lab (not Killercoda) | `http://localhost:8086` | `admin`, `avi` | `avi` has token `lesson7` |
