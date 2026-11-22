# Install Jenkins on Killercoda WITHOUT the setup wizard (simple version)

**Where:** the Killercoda **Ubuntu** terminal in the browser (you are logged in as `root`).
**How:** paste **one block at a time**. Wait for the prompt (`root@ubuntu:~$`) to come back before you paste the next block.
Steps 1 and 2 ask questions, and you answer them with **Y**.

| Item | Value |
| --- | --- |
| URL (Killercoda terminal) | `http://localhost:8080` |
| URL (your browser) | Killercoda menu → **Traffic / Ports** → port **8080** |
| Login after Step 3 | none, security is off |
| Login after Step 4 (optional) | `admin` / `admin123`, plus an API token in `$API_TOKEN` |
| Jenkins data | `~/jenkins_home` |
| Jenkins program and log | `~/jenkins/jenkins.war`, `~/jenkins/jenkins.log` |

> **Why one block at a time:** when a command asks a question, the next line you pasted gets typed in as the answer.
> That's why each command that asks a question is alone in its block.

---

## Step 1: Update and upgrade Ubuntu (you type Y)

```bash
sudo apt-get update && sudo apt-get upgrade
```

When it asks `Do you want to continue? [Y/n]`, type **Y** and press **Enter**.
If a full-screen dialog appears, see [Questions apt may ask](#questions-apt-may-ask).
Wait until the prompt comes back.

---

## Step 2: Install Java 21 and tools (you type Y)

```bash
sudo apt-get install openjdk-21-jre-headless fontconfig wget curl
```

Type **Y** and press **Enter**. Wait until the prompt comes back.

---

## Step 3: Download and start Jenkins without the wizard

No questions in this block. Paste all of it at once.

```bash
# Check Java
java -version

# Folders: ~/jenkins (war + log), ~/jenkins_home (Jenkins data)
mkdir -p ~/jenkins ~/jenkins_home
export JENKINS_HOME=~/jenkins_home

# Download Jenkins LTS (~95 MB)
wget -q --show-progress -O ~/jenkins/jenkins.war https://get.jenkins.io/war-stable/latest/jenkins.war

# Start Jenkins in the background, WITHOUT the wizard, CSRF off (lab only)
nohup java -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &

# Wait until Jenkins is up (max 3 min), then check
for i in $(seq 1 60); do grep -q "Jenkins is fully up and running" ~/jenkins/jenkins.log && break; sleep 3; done
tail -n 3 ~/jenkins/jenkins.log
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080/api/json
```

**Expected at the end:**

```text
... Jenkins is fully up and running
HTTP 200
```

Jenkins is now running with no login. Open it in the browser through **Traffic / Ports** → **8080**.

### What the flags mean

| Flag | Meaning |
| --- | --- |
| `-Djenkins.install.runSetupWizard=false` | Skip the setup wizard: no unlock password and no plugin screen |
| `-Dhudson.security.csrf...DISABLE_CSRF_PROTECTION=true` | No CSRF crumb needed for `curl -X POST` (lab only) |
| `--httpPort=8080` | Jenkins listens on port 8080 |
| `nohup ... &` | Runs in the background and keeps running after the terminal closes |
| `> ~/jenkins/jenkins.log 2>&1` | All Jenkins output goes to the log file |

---

## Step 4 (optional): Create `admin` / `admin123` and an API token

Paste this only if the task needs a login. After it runs, anonymous access is blocked (HTTP 403).

```bash
API_TOKEN=$(curl -s -X POST http://localhost:8080/scriptText --data-urlencode "script=
import jenkins.model.*
import hudson.security.*
import jenkins.security.ApiTokenProperty
def j = Jenkins.get()
def realm = new HudsonPrivateSecurityRealm(false)
def u = realm.createAccount('admin', 'admin123')
u.save()
j.setSecurityRealm(realm)
def s = new FullControlOnceLoggedInAuthorizationStrategy()
s.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(s)
def t = u.getProperty(ApiTokenProperty.class).tokenStore.generateNewToken('MasterKey')
u.save()
j.save()
print t.plainValue")
export API_TOKEN; echo "API_TOKEN=$API_TOKEN"
curl -s -u "admin:$API_TOKEN" http://localhost:8080/whoAmI/api/json; echo
```

**Expected:** a long token made of letters and digits, then JSON with `"name":"admin"` and `"authenticated":true`.

From now on, use `-u "admin:$API_TOKEN"` in every `curl` command.
`$API_TOKEN` lives only in this terminal tab. Save it so a new tab can load it again:

```bash
echo "export API_TOKEN=\"$API_TOKEN\"" > ~/jenkins.env    # save once
source ~/jenkins.env                                      # in every new tab
```

---

## Questions apt may ask

| What you see | What to do |
| --- | --- |
| `Do you want to continue? [Y/n]` | Type **Y**, press **Enter** |
| Full-screen dialog "Which services should be restarted?" | Press **Enter** (OK), which keeps the default selection |
| "A new version of configuration file ... is available" | Press **Enter**. The default keeps the version currently installed |
| "Pending kernel upgrade" / "Newer kernel available" | Press **Enter** (OK). Jenkins doesn't need a reboot |

In a full-screen dialog, **Tab** moves between buttons, and **Enter** presses the selected one.

---

## Ubuntu version

Check it with:

```bash
grep PRETTY_NAME /etc/os-release
```

| Ubuntu | Java package for Step 2 |
| --- | --- |
| 24.04 (Killercoda's Ubuntu playground) | `openjdk-21-jre-headless` (no change) |
| 22.04 | `openjdk-21-jre-headless` (no change) |
| 20.04 | `openjdk-17-jre-headless` (Java 21 isn't available there) |

---

## Everyday commands

```bash
# Is Jenkins running?
pgrep -af jenkins.war
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080/login

# Log (Ctrl+C to stop following)
tail -f ~/jenkins/jenkins.log

# Stop Jenkins (data stays in ~/jenkins_home)
pkill -f jenkins.war
```

Start Jenkins again **and keep jobs and users**:

```bash
pkill -f jenkins.war; sleep 5
JENKINS_HOME=~/jenkins_home nohup java -Djenkins.install.runSetupWizard=false \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &
```

`JENKINS_HOME=~/jenkins_home` is required. Without it, Jenkins uses an empty `~/.jenkins`, and your jobs and users seem to be gone.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Step 2 ended with `Abort.` | Something other than Y was typed, often a pasted line | Run Step 2 again, alone |
| `Address already in use` in `~/jenkins/jenkins.log` | Jenkins (or the Docker `my-jenkins`) already uses 8080 | `pkill -f jenkins.war` or `docker rm -f my-jenkins`, then Step 3 again |
| `Could not get lock /var/lib/dpkg/lock-frontend` | Ubuntu's automatic updates are running | Wait 1–2 minutes, then run the step again |
| `Unable to locate package openjdk-21-jre-headless` | Ubuntu 20.04, or Step 1 was skipped | Run Step 1, or use `openjdk-17-jre-headless` |
| `java: command not found` in Step 3 | Step 2 didn't finish | Run Step 2 again and type Y |
| `HTTP 503` | Jenkins is still starting | Wait 30 seconds and check again |
| `HTTP 403` after Step 4 | Anonymous access is blocked now | Add `-u "admin:$API_TOKEN"` |
| `HTTP 401` with `-u admin:$API_TOKEN` | `$API_TOKEN` is empty (new tab) | `source ~/jenkins.env` |
| Browser shows `502 Bad Gateway` | Jenkins isn't listening on 8080 yet | Wait for `HTTP 200` in the terminal |
| Killercoda session expired | A new session is an empty VM | Run Steps 1–3 (and 4) again |
