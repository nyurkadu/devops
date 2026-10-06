# Lesson 3 – Parameterized Jenkins Job: Remote Trigger + GitHub Polling

**Host:** Windows · **Terminal:** VS Code (PowerShell) · **Jenkins:** Docker container

This lab shows you how to:

1. Create a Jenkins user (`avi`) in a Dockerized Jenkins
2. Create a **parameterized Pipeline job** (`lesson3-parameterized-job`)
3. Generate an **API token** and test it
4. Trigger the job remotely with `curl.exe`, passing parameters in the URL
5. Run the job automatically when `README.md` changes in `https://github.com/nyurkadu/jenkins-webhook-demo`

| Item | Value |
|---|---|
| Jenkins URL (from your Windows PC) | `http://localhost:8086` |
| Jenkins URL (inside the container) | `http://localhost:8080` |
| Docker container name | `jenkins` |
| Jenkins user | `avi` |
| Job name | `lesson3-parameterized-job` |
| GitHub repo / branch | `https://github.com/nyurkadu/jenkins-webhook-demo` / `main` |

> **Port mapping:** the container listens on `8080`, and Docker publishes it on host port `8086`. Every command in this guide runs on your Windows PC, so it uses `localhost:8086`.

> **The user name matters.** Every `curl.exe -u` command uses `avi:`, which must be the user you log in to Jenkins with. A token belongs to one user. If you send it with a different user name, for example `admin:`, Jenkins returns **401 Unauthorized**, even if the token is correct.

---

## Step 0 – Windows / VS Code terminal notes (read first)

1. Open a terminal in VS Code: **Terminal → New Terminal**. Make sure the dropdown on the right says **powershell**.
2. Make sure Docker Desktop is running and the container is up:

   ```powershell
   docker ps --filter "name=jenkins" --format "{{.Names}}  {{.Status}}  {{.Ports}}"
   ```

   The output should include `Up` and `0.0.0.0:8086->8080/tcp`. If the container is stopped, run `docker start jenkins`.

3. **Always type `curl.exe`, not `curl`.** In Windows PowerShell 5.1, `curl` is an alias for `Invoke-WebRequest`, which doesn't understand `-u`, `-X` or `-i`.
4. PowerShell syntax differs from Linux:

   | Linux / bash | PowerShell |
   |---|---|
   | `export VAR=value` | `$env:VAR = "value"` (**the quotes are required**) |
   | `$VAR` | `$env:VAR` |
   | `\` line continuation | `` ` `` (backtick). This guide keeps commands on one line instead |
   | `grep` | `Select-String` |
   | `cat <<EOF ... EOF` | `@' ... '@` (here-string; the closing `'@` must be at the start of its line) |

5. Always put URLs in **double quotes**. Otherwise PowerShell treats the `&` between URL parameters as an operator.

---

## Step 1 – Create the Jenkins user

> **Skip this step** if you can already log in to `http://localhost:8086` with the user `avi`, for example because you created it in the setup wizard.

Jenkins runs every Groovy script in `/var/jenkins_home/init.groovy.d/` when it starts. The script below creates the user `avi` with a temporary password and requires everyone to log in.

> A Linux-style `docker exec ... bash -c '... cat << EOF ...'` one-liner breaks in PowerShell because of how it passes quotes to programs. Instead, create the file on Windows and copy it into the container with `docker cp`.

### 1.1 Create the Groovy file on Windows

```powershell
@'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.get()

def hudsonRealm = new HudsonPrivateSecurityRealm(false)
def user = hudsonRealm.createAccount("avi", "ChangeMe123")
user.save()
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

instance.save()
println "--> SUCCESS: User avi created successfully."
'@ | Set-Content -Path .\create-user.groovy -Encoding ascii
```

What the script does:
- `HudsonPrivateSecurityRealm(false)` turns on Jenkins' own user database and turns off self sign-up.
- `FullControlOnceLoggedInAuthorizationStrategy` gives logged-in users full control and blocks anonymous read access.

### 1.2 Copy the file into the container

```powershell
docker exec -u 0 jenkins mkdir -p /var/jenkins_home/init.groovy.d
```

```powershell
docker cp .\create-user.groovy jenkins:/var/jenkins_home/init.groovy.d/create-user.groovy
```

```powershell
docker exec -u 0 jenkins chown -R 1000:1000 /var/jenkins_home/init.groovy.d
```

- `-u 0` runs the command as root inside the container.
- `chown 1000:1000` gives the files back to the `jenkins` user (UID 1000).

### 1.3 Restart Jenkins and check that the script ran

```powershell
docker restart jenkins
```

Wait about 30 seconds, then run:

```powershell
docker logs jenkins 2>&1 | Select-String "SUCCESS"
```

Expected output: `--> SUCCESS: User avi created successfully.`

### 1.4 Remove the init script (important)

Otherwise the script runs again on every restart and resets the password to `ChangeMe123`:

```powershell
docker exec -u 0 jenkins rm /var/jenkins_home/init.groovy.d/create-user.groovy
```

```powershell
Remove-Item .\create-user.groovy
```

Check that it's gone. The command below should print nothing:

```powershell
docker exec jenkins ls /var/jenkins_home/init.groovy.d
```

### 1.5 Log in and change the password

1. Open `http://localhost:8086` and log in as **avi / ChangeMe123**.
2. Click **avi** (top right) → **Security** → **Password**, set your own password, and click **Save**.

---

## Step 2 – Create the Pipeline job

1. On the Jenkins dashboard, click **+ New Item**.
2. **Enter an item name:** `lesson3-parameterized-job`
3. Select **Pipeline** and click **OK**.
4. Scroll down to the **Pipeline** section:
   - **Definition:** `Pipeline script`
   - **Script:** paste the script below.
5. Click **Save**.

This is the **final** script. It covers both parts of the lab: the parameters you pass remotely (Step 5) and the GitHub polling (Step 7).

```groovy
pipeline {
    agent any

    triggers {
        pollSCM('H/2 * * * *')   // check GitHub about every 2 minutes
    }

    parameters {
        string(name: 'TARGET_ENV', defaultValue: 'staging', description: 'Deployment target environment')
        string(name: 'RELEASE_TAG', defaultValue: 'v1.0.0', description: 'Container image release tag')
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: 'Force full integration testing')
    }

    stages {
        stage('Checkout') {
            steps {
                git url: 'https://github.com/nyurkadu/jenkins-webhook-demo.git', branch: 'main'
            }
        }

        stage('Inspect Parameters') {
            when {
                anyOf {
                    not { triggeredBy 'SCMTrigger' }   // manual / curl builds always run
                    changeset 'README.md'              // polling builds only if README.md changed
                }
            }
            steps {
                echo "Deploying Release Tag: ${params.RELEASE_TAG}"
                echo "Target Environment: ${params.TARGET_ENV}"
                echo "Execute Test Suite: ${params.RUN_TESTS}"
            }
        }

        stage('Simulate Deployment') {
            when {
                anyOf {
                    not { triggeredBy 'SCMTrigger' }
                    changeset 'README.md'
                }
            }
            steps {
                sh '''
                    echo "Deploying release ${RELEASE_TAG} to environment ${TARGET_ENV}..."
                    echo "README.md now contains:"
                    cat README.md
                    echo "Completed at $(date)"
                '''
            }
        }
    }
}
```

How the script works:

| Part | What it does |
|---|---|
| `parameters { }` | Defines the 3 parameters that `buildWithParameters` fills in |
| `triggers { pollSCM('H/2 * * * *') }` | Turns on **Poll SCM**. `H/2` means about every 2 minutes, with a spread so jobs don't all poll at the same second |
| `stage('Checkout')` | Clones the repo. It also tells Jenkins **which repo to poll**, because polling only watches repositories that a previous build checked out |
| `when { anyOf { ... } }` | Manual and curl builds always run. Builds started by polling run the stages only if `README.md` changed |
| `${params.X}` in `echo "..."` | Resolved by **Groovy** |
| `${RELEASE_TAG}` in `sh '''...'''` | Resolved by the **shell**, because Jenkins also exports every parameter as an environment variable |
| `sh`, not `bat` | The build runs **inside the Linux container**, even though your PC runs Windows |

---

## Step 3 – Run the job once from the UI (required)

The `parameters { }` and `triggers { }` blocks only take effect after the **first run**. Until then:
- `buildWithParameters` fails with **HTTP 400** (*not parameterized*).
- Polling does nothing, because no build has checked out the repo yet.

1. Open the job and click **Build Now**. This first run uses the default values.
2. Refresh the page. The button now reads **Build with Parameters**.
3. Open the build → **Console Output**. Check for these lines:

```
[Pipeline] { (Checkout)
Checking out Revision 5613637... (refs/remotes/origin/main)
...
Deploying Release Tag: v1.0.0
Target Environment: staging
Execute Test Suite: true
...
Deploying release v1.0.0 to environment staging...
Finished: SUCCESS
```

4. Go to **Configure → Triggers** (called **Build Triggers** in older versions). **Poll SCM** should now be checked, with `H/2 * * * *`.

> ⚠️ **Whenever you change the script, run one build afterwards.** Jenkins polls based on the last **completed** build. If that build ran an old script without the `Checkout` stage, polling does nothing.

---

## Step 4 – Create an API token and test it

Use an **API token** for remote calls, not your password. Calls made with a token also don't need a CSRF crumb.

### 4.1 Create the token in the UI (recommended)

1. Log in as **avi** and click **avi** (top right) → **Security**.
2. Under **API Token**, click **Add new Token**.
3. Name it `remote-trigger-token` and click **Generate**.
4. **Copy the token now.** Jenkins shows it only once.

### 4.2 Save the token in the terminal

Use quotes. Without them, PowerShell tries to run the token as a command.

```powershell
$env:JENKINS_TOKEN = "<paste-token-value-here>"
```

Check it:

```powershell
"[$env:JENKINS_TOKEN]"
```

It should print the 34-character token inside the brackets. If it prints `[]`, the variable is empty.

> `$env:JENKINS_TOKEN` only lasts for the current terminal session. If you open a new VS Code terminal, set it again.

### 4.3 Test the token

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/whoAmI/api/json"
```

Expected output:

```json
{"_class":"hudson.security.WhoAmI","anonymous":false,"authenticated":true,"authorities":["authenticated"],"name":"avi"}
```

If you see `"authenticated":true` and `"name":"avi"`, the token works. If you get `401` instead, see the troubleshooting table.

### 4.4 (Alternative) Create the token from the terminal

This works too, but when you log in with a password, Jenkins also requires a **CSRF crumb** and a session cookie.

Get a crumb and save the session cookie:

```powershell
$crumb = curl.exe -s -c cookies.txt -u "avi:<your-password>" "http://localhost:8086/crumbIssuer/api/json" | ConvertFrom-Json
```

Create the token:

```powershell
$resp = curl.exe -s -b cookies.txt -u "avi:<your-password>" -H "$($crumb.crumbRequestField): $($crumb.crumb)" -X POST "http://localhost:8086/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken?newTokenName=remote-trigger-token" | ConvertFrom-Json
```

Save the token and clean up:

```powershell
$env:JENKINS_TOKEN = $resp.data.tokenValue
```

```powershell
Remove-Item cookies.txt
```

> If `ConvertFrom-Json` reports `Unexpected character encountered while parsing value: <`, Jenkins returned an HTML error page. Run the same `curl.exe` command with `-i` and without `| ConvertFrom-Json` to see the status code. It's usually a 401, caused by the wrong user name or password.

---

## Step 5 – Trigger the job remotely with parameters

```powershell
curl.exe -X POST -i -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/buildWithParameters?RELEASE_TAG=v2.5.1&TARGET_ENV=production&RUN_TESTS=false"
```

Expected response:

```
HTTP/1.1 201 Created
Location: http://localhost:8086/queue/item/9/
```

`201 Created` means Jenkins accepted the build and put it in the queue. The `Location` header points to the queue item.

More examples:

With some parameters. The rest use their **default** values, here `RUN_TESTS=true`:

```powershell
curl.exe -X POST -i -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/buildWithParameters?TARGET_ENV=production&RELEASE_TAG=v3.0.0"
```

With no parameters, so all defaults are used:

```powershell
curl.exe -X POST -i -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/buildWithParameters"
```

### 5.1 (Alternative) Native PowerShell without curl.exe

```powershell
$pair = "avi:$env:JENKINS_TOKEN"
```

```powershell
$headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
```

```powershell
Invoke-WebRequest -Method Post -Headers $headers -UseBasicParsing -Uri "http://localhost:8086/job/lesson3-parameterized-job/buildWithParameters?TARGET_ENV=production&RELEASE_TAG=v3.0.0"
```

A `StatusCode` of `201` means the call succeeded.

---

## Step 6 – Verify the remote build

Wait about 20 seconds, then print the console output:

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/lastBuild/consoleText"
```

For the call in Step 5, you should see:

```
Started by user Avi Lavi
...
Deploying Release Tag: v2.5.1
Target Environment: production
Execute Test Suite: false
...
Deploying release v2.5.1 to environment production...
Finished: SUCCESS
```

To see the build number, result and cause in a short summary:

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/lastBuild/api/json" | ConvertFrom-Json | Select-Object number, result, @{n='cause';e={$_.actions.causes.shortDescription}}
```

In the UI, open the build → **Parameters** to see the values you sent.

---

## Step 7 – Run the pipeline automatically when README.md changes on GitHub

The script from Step 2 already polls GitHub. This step checks that it works.

> **Why polling and not a webhook?** Jenkins only runs on `localhost:8086`, and GitHub.com can't reach your PC. Instead, Jenkins **polls** GitHub about every 2 minutes and runs the build when it finds a new commit. Polling also works if you aren't an admin of the repo, which a webhook would require. See 7.4 if you want instant builds.

### 7.1 Check that polling is turned on

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/config.xml" | Select-String "SCMTrigger|H/2|jenkins-webhook-demo"
```

The output should include `<hudson.triggers.SCMTrigger>`, `<spec>H/2 * * * *</spec>` and the repo URL.

### 7.2 Check that the last completed build did the checkout

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/lastCompletedBuild/consoleText" | Select-String "Checkout|Checking out|Finished"
```

Expected output:

```
[Pipeline] { (Checkout)
Checking out Revision 5613637ec3ae529516f067d405e35d96b2b72108 (refs/remotes/origin/main)
Finished: SUCCESS
```

If `(Checkout)` is missing, run one build (Step 5 with no parameters), then check again.

### 7.3 Test it

1. On GitHub, open `README.md` → ✏️ **Edit**, change a line, and click **Commit changes** to `main`. Do this **after** the build from 7.2 has finished.
2. Wait 2–3 minutes.
3. Check that a build started on its own:

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/lastBuild/consoleText" | Select-String "Started by|README|Finished"
```

Expected output:

```
Started by an SCM change
README.md now contains:
Finished: SUCCESS
```

4. The polling log shows what Jenkins found:

```powershell
curl.exe -s -u "avi:$env:JENKINS_TOKEN" "http://localhost:8086/job/lesson3-parameterized-job/scmPollLog/" | Select-String "Started on|git|Changes|No changes"
```

The log should show `git ls-remote ...` lines and `Changes found`. In the UI, go to the job → **Git Polling Log**. In the new build, **Changes** lists your commit.

Notes:
- Builds started by polling use the **default** parameter values (`staging`, `v1.0.0`, `true`).
- A commit that doesn't touch `README.md`, for example one that only changes the `Jenkinsfile`, still starts a build, but the two deploy stages are **skipped**.

### 7.4 (Optional) Real webhook for instant builds

A webhook needs a **public HTTPS URL** that forwards to `localhost:8086`, plus admin rights on the GitHub repo. A tunnel is simpler than port forwarding, because your home IP changes over time.

1. Start a tunnel, for example `ngrok http 8086`. It gives you a URL such as `https://xxxx.ngrok-free.app`.
2. In the pipeline, add `githubPush()` inside `triggers { }`. This needs the GitHub plugin. Then save and run one build.
3. In the GitHub repo, go to **Settings → Webhooks → Add webhook**:
   - **Payload URL:** `https://xxxx.ngrok-free.app/github-webhook/` (keep the trailing `/`)
   - **Content type:** `application/json`
   - **Events:** *Just the push event*

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Invoke-WebRequest : A parameter cannot be found that matches parameter name 'X'` | You typed `curl`, which is an alias in PowerShell | Use `curl.exe` |
| `The term '11xxxx...' is not recognized as a name of a cmdlet` | The token wasn't in quotes | `$env:JENKINS_TOKEN = "11xxxx..."` |
| `The ampersand (&) character is not allowed` | The URL isn't in quotes | Put the URL in `"double quotes"` |
| Here-string error in Step 1.1 | The closing `'@` has spaces before it | Move `'@` to the start of its line |
| `HTTP 401 Unauthorized`, even though the token looks right | The **user name** doesn't match the token's owner, for example `admin:` instead of `avi:` | Use the user you log in with: `-u "avi:$env:JENKINS_TOKEN"`. Test with `whoAmI` (Step 4.3) |
| `HTTP 401` in a new terminal | `$env:JENKINS_TOKEN` is empty | Run `"[$env:JENKINS_TOKEN]"` to check it, then set it again |
| `ConvertFrom-Json: Unexpected character ... <` | Jenkins returned an HTML error page (401, 403 or 404) instead of JSON | Run the command with `-i` and without `ConvertFrom-Json` to see the status code |
| `HTTP 403 No valid crumb` | You made a POST request with the password | Use the API token, or send the crumb and cookie (Step 4.4) |
| `HTTP 400 – ... is not parameterized` | The job hasn't run yet | Click **Build Now** once (Step 3) |
| `HTTP 404 Not Found` | Wrong job name or port | Check `lesson3-parameterized-job` and port `:8086` |
| `Could not connect` on `localhost:8086` | The container is stopped | Run `docker ps`, then `docker start jenkins` |
| `Could not connect` on your **public IP** | No router port forward and firewall rule, or the router doesn't let a PC reach its own public IP (NAT loopback) | Use `localhost:8086` from your PC. For outside access, use a tunnel (7.4) |
| Polling log shows `Done. Took 0 ms` + `No changes`, and a README commit doesn't start a build | The last completed build ran a script without the `Checkout` stage, so Jenkins has no repo to poll | Run one build with the current script, check for `(Checkout)` (7.2), then commit to README again |
| Polling log shows `No changes` after a commit | Jenkins already built that commit, or the commit went to another branch or fork | Commit again to `main` in `nyurkadu/jenkins-webhook-demo`, after the last build |
| `Could not resolve host: github.com` in Checkout | The container has no internet access or DNS | Run `docker exec jenkins git ls-remote https://github.com/nyurkadu/jenkins-webhook-demo.git` to test |
| `sh: not found` / `bat` errors | You changed `sh` to `bat` | Keep `sh`. The build runs inside the Linux container |
| Login fails after a restart | The init script ran again and reset the password | Remove the script (Step 1.4) |

---

## Security checklist

- [ ] Change the temporary password right after your first login.
- [ ] Delete `init.groovy.d/create-user.groovy` from the container and from Windows.
- [ ] Never commit API tokens or passwords to Git, and don't paste them into chats. Use environment variables.
- [ ] Revoke tokens you don't need anymore: **avi → Security → API Token → Revoke**.
- [ ] If you ever expose port 8086 to the internet, allow only trusted source IPs, or use a tunnel with authentication.
