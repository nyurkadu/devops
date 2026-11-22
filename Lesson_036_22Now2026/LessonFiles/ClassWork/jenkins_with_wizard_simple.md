# Install Jenkins on Killercoda WITH the setup wizard (simple version)

**Where:** the Killercoda **Ubuntu** terminal in the browser (you are logged in as `root`).
**How:** paste **one block at a time**. Wait for the prompt (`root@ubuntu:~$`) to come back before you paste the next block.
Steps 1 and 2 ask questions, and you answer them with **Y**. Step 4 happens in the browser.

| Item | Value |
| --- | --- |
| URL (Killercoda terminal) | `http://localhost:8080` |
| URL (your browser) | Killercoda menu → **Traffic / Ports** → port **8080** |
| Unlock password | `cat ~/jenkins_home/secrets/initialAdminPassword` |
| Login after the wizard | the user you create in the wizard (use `admin` / `admin123`) |
| API token | you create it in the UI (Step 5) |
| Jenkins data | `~/jenkins_home` |
| Jenkins program and log | `~/jenkins/jenkins.war`, `~/jenkins/jenkins.log` |

> **Why one block at a time:** when a command asks a question, the next line you pasted gets typed in as the answer.
> That's why each command that asks a question is alone in its block.

> **Ran the no-wizard version in this session already?** Then the wizard won't appear, because `~/jenkins_home` already exists.
> Start clean first: `pkill -f jenkins.war; rm -rf ~/jenkins_home` (this deletes all jobs and users).

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

## Step 3: Download and start Jenkins WITH the wizard

No questions in this block. Paste all of it at once.

```bash
# Check Java
java -version

# Folders: ~/jenkins (war + log), ~/jenkins_home (Jenkins data)
mkdir -p ~/jenkins ~/jenkins_home
export JENKINS_HOME=~/jenkins_home

# Download Jenkins LTS (~95 MB)
wget -q --show-progress -O ~/jenkins/jenkins.war https://get.jenkins.io/war-stable/latest/jenkins.war

# Start Jenkins in the background, WITH the wizard, CSRF off (lab only)
nohup java \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &

# Wait until Jenkins is up (max 3 min), then check
for i in $(seq 1 60); do grep -q "Jenkins is fully up and running" ~/jenkins/jenkins.log && break; sleep 3; done
tail -n 3 ~/jenkins/jenkins.log
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080/login

# The unlock password for the wizard
echo "Unlock password: $(cat ~/jenkins_home/secrets/initialAdminPassword)"
```

**Expected at the end:**

```text
... Jenkins is fully up and running
HTTP 200
Unlock password: 3f8c0e...   (32 letters and digits)
```

Copy the unlock password. You need it in Step 4.

> `/login` returns 200, but `/api/json` returns **403** until the wizard is finished. That's expected,
> because with the wizard Jenkins is locked from the start.

### What the flags mean

| Flag | Meaning |
| --- | --- |
| (no `runSetupWizard=false`) | The setup wizard runs. This is the difference from the no-wizard version |
| `-Dhudson.security.csrf...DISABLE_CSRF_PROTECTION=true` | No CSRF crumb needed for `curl -X POST` (lab only) |
| `--httpPort=8080` | Jenkins listens on port 8080 |
| `nohup ... &` | Runs in the background and keeps running after the terminal closes |
| `> ~/jenkins/jenkins.log 2>&1` | All Jenkins output goes to the log file |

---

## Step 4: Finish the wizard in the browser

1. Killercoda menu (top right) → **Traffic / Ports** → enter **8080** → **Access**.
2. **Unlock Jenkins**: paste the unlock password from Step 3 → **Continue**.
3. **Customize Jenkins**: **Install suggested plugins**. Wait until all of them turn green (2–4 minutes).
4. **Create First Admin User**:
   - Username: `admin`
   - Password: `admin123` (twice)
   - Full name: anything, e.g. `Admin`
   - E-mail: anything, e.g. `admin@example.com`

   → **Save and Continue**. Don't click "Skip and continue as admin": then the password stays the long unlock password.
5. **Instance Configuration**: keep the URL → **Save and Finish** → **Start using Jenkins**.

Use the name `admin`, because the lesson commands use `-u "admin:${API_TOKEN}"`.

Lost the unlock password? Run this in the terminal:

```bash
cat ~/jenkins_home/secrets/initialAdminPassword
```

---

## Step 5 (optional): Create an API token and use it from the terminal

**In the browser:**

1. Click **admin** (top right) → **Security** → **API Token** → **Add new Token**.
2. Name it `MasterKey` → **Generate** → copy the value. Jenkins shows it only once.

**In the terminal.** Paste this line **alone**, then paste the token when it asks and press **Enter**:

```bash
read -rp "Paste the API token and press Enter: " API_TOKEN
```

Then save it and test it:

```bash
export API_TOKEN
echo "export API_TOKEN=\"$API_TOKEN\"" > ~/jenkins.env
curl -s -u "admin:$API_TOKEN" http://localhost:8080/whoAmI/api/json; echo
```

**Expected:** JSON with `"name":"admin"` and `"authenticated":true`.

From now on, use `-u "admin:$API_TOKEN"` in every `curl` command. In a new terminal tab, run `source ~/jenkins.env` first.

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

Start Jenkins again **and keep jobs, users and plugins**. Once you've finished the wizard, it doesn't come back:

```bash
pkill -f jenkins.war; sleep 5
JENKINS_HOME=~/jenkins_home nohup java \
  -Dhudson.security.csrf.GlobalCrumbIssuerConfiguration.DISABLE_CSRF_PROTECTION=true \
  -jar ~/jenkins/jenkins.war --httpPort=8080 > ~/jenkins/jenkins.log 2>&1 &
```

`JENKINS_HOME=~/jenkins_home` is required. Without it, Jenkins uses an empty `~/.jenkins` and starts a new wizard.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Step 2 ended with `Abort.` | Something other than Y was typed, often a pasted line | Run Step 2 again, alone |
| `cat: .../initialAdminPassword: No such file or directory` | The wizard is already finished, or `~/jenkins_home` came from the no-wizard version | Log in with your user. For a new wizard: `pkill -f jenkins.war; rm -rf ~/jenkins_home`, then Step 3 |
| No wizard in the browser, Jenkins opens directly | `~/jenkins_home` came from the no-wizard version | Same as above |
| Wizard: plugins fail to install (red) | Download error from the plugin site | Click **Retry**. If they still fail, **Continue** and install them later in Manage Jenkins → Plugins |
| `Address already in use` in `~/jenkins/jenkins.log` | Jenkins (or the Docker `my-jenkins`) already uses 8080 | `pkill -f jenkins.war` or `docker rm -f my-jenkins`, then Step 3 again |
| `Could not get lock /var/lib/dpkg/lock-frontend` | Ubuntu's automatic updates are running | Wait 1–2 minutes, then run the step again |
| `Unable to locate package openjdk-21-jre-headless` | Ubuntu 20.04, or Step 1 was skipped | Run Step 1, or use `openjdk-17-jre-headless` |
| `java: command not found` in Step 3 | Step 2 didn't finish | Run Step 2 again and type Y |
| `HTTP 503` | Jenkins is still starting | Wait 30 seconds and check again |
| `HTTP 403` on `/api/json` | Wizard not finished, or no `-u` | Finish Step 4, then add `-u "admin:$API_TOKEN"` |
| `HTTP 401` with `-u admin:$API_TOKEN` | `$API_TOKEN` is empty (new tab), or the token belongs to another user | `source ~/jenkins.env`, and use the user that created the token |
| Browser shows `502 Bad Gateway` | Jenkins isn't listening on 8080 yet | Wait for `HTTP 200` in the terminal |
| Killercoda session expired | A new session is an empty VM | Run Steps 1–4 again |
