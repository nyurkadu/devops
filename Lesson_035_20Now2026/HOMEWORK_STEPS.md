# Lesson 035 homework — hellogo under Argo CD

Step-by-step runbook for [HOMEWORK.md](HOMEWORK.md):

- **[Install Helm](#install-helm)**: a separate section; Helm is needed for the Argo CD install and for Part 2.
- **[Part 1](#part-1--base-assignment-steps-14)**: steps 1–4 of the base assignment, including a fresh
  Argo CD install. Steps 5–7 of the homework build on it.
- **[Part 2](#part-2--helm-chart-from-the-public-repo-values-from-a-private-repo)**: Argo CD deploys
  a Helm chart from your public repo, with the values taken from a new **private** repo.

In *Install Helm* and Part 2, every step ends with a **Test** (prints PASS or FAIL for each check)
and a **Troubleshooting** table.

## Conventions used below

| Item | Value |
|---|---|
| Shell | PowerShell 7 (all commands below are PowerShell, not bash) |
| Working directory | `C:\Users\avila\devops\CloudLessons\Lesson_035_20Now2026` (unless stated otherwise) |
| Your Git repo | `https://github.com/nyurkadu/devops.git` (public, branch `master`) |
| Manifests in the repo | `Lesson_035_20Now2026/gitops/hellogo-app/` |
| Argo CD UI | http://localhost:8889 (port 8080 is often busy on this machine) |
| hellogo app | http://localhost:8081 |
| Private values repo (Part 2) | `https://github.com/nyurkadu/hellogo-values.git`, cloned to `C:\Users\avila\devops\hellogo-values` |
| hellogo-helm app (Part 2) | http://localhost:8082 |

> **Path note.** The assignment says `gitops/hellogo-app`, assuming the repo root. Your repo keeps each
> lesson in its own folder, so the Argo CD **Path** is `Lesson_035_20Now2026/gitops/hellogo-app`.
> To match the assignment literally instead, create `gitops/` at the repo root
> (`C:\Users\avila\devops\CloudLessons\gitops`) and use `gitops/hellogo-app` as the Path.

Reference files come from the course repo:
[BorisovCloud/devops2079 → gitops](https://github.com/BorisovCloud/devops2079/tree/main/gitops).

## Test helper (paste once per terminal)

The **Test** blocks print `PASS` or `FAIL` for each check. They use this small function. Paste it
into every new PowerShell terminal before running a test block:

```powershell
function Test-Step([string]$Name, [scriptblock]$Check) {
    try   { $ok = [bool](& $Check) } catch { $ok = $false }
    if ($ok) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else     { Write-Host "FAIL  $Name" -ForegroundColor Red }
}
```

A step is done when **all** of its checks print `PASS`. On any `FAIL`, use that step's
Troubleshooting table, fix the cause, and run the whole Test block again.

---

## Install Helm

Helm installs Argo CD (step 0.3) and checks the chart locally before you push it (Part 2). Argo CD
does **not** use your local Helm: it renders charts with its own built-in copy. The local one is
only for installing Argo CD and for testing.

### H.1 Install the Helm CLI

```powershell
winget install --id Helm.Helm --exact --accept-source-agreements --accept-package-agreements
```

**Close the terminal and open a new one.** winget adds Helm to PATH only for new terminals.

If Helm is already installed, winget says so and changes nothing. To update it, run
`winget upgrade --id Helm.Helm --exact`.

### H.2 Connect the Argo CD chart repository

```powershell
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### Helm test

```powershell
Test-Step 'helm is on PATH'                     { Get-Command helm -ErrorAction Stop }
Test-Step 'helm is v3 or v4'                    { (helm version --short) -match '^v[34]\.' }
Test-Step 'argo chart repo is added'            { (helm repo list | Out-String) -match 'argoproj\.github\.io/argo-helm' }
Test-Step 'argo-cd chart is visible'            { (helm search repo argo/argo-cd | Out-String) -match 'argo/argo-cd\s' }
```

### Helm troubleshooting

| Symptom | Fix |
|---|---|
| `helm : The term 'helm' is not recognized` | Open a **new** terminal. Still missing: `winget list --id Helm.Helm` shows whether it is installed; if not, re-run H.1. |
| `winget : The term 'winget' is not recognized` | Install **App Installer** from Microsoft Store. Or download the Windows zip from [Helm releases](https://github.com/helm/helm/releases) and put `helm.exe` into `C:\Users\avila\devops\Terraform` (already on PATH). |
| Version check fails | An old Helm is earlier on PATH: `Get-Command helm -All` lists every copy. Remove the old one. |
| `repo is corrupt or missing` warning (e.g. `podinfo`) | A stale repo from an earlier lesson: `helm repo remove podinfo`, or ignore it. |
| `argo-cd chart is visible` fails | `helm repo update`. Then check internet access: `curl.exe -sI https://argoproj.github.io/argo-helm/index.yaml` should return `HTTP/1.1 200`. |
| `Kubernetes cluster unreachable` (later, in 0.3 or Part 2) | minikube is stopped: start Docker Desktop, then `minikube start`. |

---

# Part 1 — Base assignment, steps 1–4

## Step 0 — Start the cluster and install Argo CD

### 0.1 Start Docker Desktop and minikube

Start **Docker Desktop** and wait until it reports *Engine running*. Then:

```powershell
docker info --format '{{.ServerVersion}}'   # prints a version, not an error
minikube start
kubectl get nodes                           # minikube   Ready
```

### 0.2 Create the Argo CD values file

Create `gitops/values-argocd.yaml`:

```powershell
New-Item -ItemType Directory -Force gitops | Out-Null
```

```yaml
# gitops/values-argocd.yaml
configs:
  params:
    server.insecure: true    # UI over plain HTTP, so no certificate warnings behind port-forward
dex:
  enabled: false             # no SSO, we log in as admin
notifications:
  enabled: false             # not needed for this homework
```

This file sits outside `gitops/hellogo-app`, so the Argo CD application never applies it.

### 0.3 Install Argo CD with Helm

Requires Helm: see [Install Helm](#install-helm).

```powershell
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo/argo-cd --versions | Select-Object -First 5   # confirm 10.18.0 is listed

helm upgrade --install argo-cd argo/argo-cd `
  -n argo-cd --create-namespace `
  -f gitops/values-argocd.yaml `
  --version 10.18.0 `
  --wait --timeout 10m
```

If `10.18.0` is not in the search output, drop the `--version 10.18.0` line to get the latest chart.
A warning about the old `podinfo` repo during `helm repo update` is harmless.

**Check:**

```powershell
kubectl -n argo-cd get pods
```

All pods are `Running` with `READY 1/1`: `application-controller`, `applicationset-controller`,
`redis`, `repo-server`, `server`.

### 0.4 Get the admin password

`base64 -d` does not exist in PowerShell, so decode it like this:

```powershell
$b64 = kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
```

Copy the password that is printed.

### 0.5 Open the Argo CD UI

In a **separate terminal** (keep it open the whole time):

```powershell
kubectl -n argo-cd port-forward service/argo-cd-argocd-server 8889:443
```

> **The port-forward drops** after a pod or minikube restart (or Windows sleep). The UI then shows
> *"Unable to load data: Request has been terminated"*. Restart the command and reload the page.
> To have it restart by itself, run this instead (Ctrl+C to stop):
>
> ```powershell
> while ($true) { kubectl -n argo-cd port-forward service/argo-cd-argocd-server 8889:443; Write-Host 'port-forward stopped, restarting...'; Start-Sleep 2 }
> ```

Open **http://localhost:8889**. Use `http`, not `https`: `server.insecure: true` makes the server
answer plain HTTP even on service port 443. Log in as `admin` with the password from 0.4.

**Check:** you are logged in and the *Applications* page is empty.

---

## Step 1 — Put the manifests into your repository

### 1.0 Build the hellogo image into minikube

The app source [hellogo/main.go](hellogo/main.go) listens on port **8086**. Build it directly into
minikube's container runtime, so the cluster can run it without pulling from a registry:

```powershell
minikube image build -t hellogo:8086 hellogo
minikube image ls | Select-String hellogo     # docker.io/library/hellogo:8086
```

Port 8086 inside the pod does not clash with Jenkins on your machine's port 8086: every pod has
its own network.

### 1.1 Create the three files

```powershell
New-Item -ItemType Directory -Force gitops/hellogo-app | Out-Null
```

`gitops/hellogo-app/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-deployment
  labels:
    app: hello
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: hellogo:8086
          imagePullPolicy: IfNotPresent   # built locally into minikube, listens on 8086
          ports:
            - containerPort: 8086
          env:
            - name: GREETING
              valueFrom:
                secretKeyRef:
                  key: username
                  name: hello-secret
          resources:
            requests:
              memory: "6Mi"
              cpu: "250m"
            limits:
              memory: "32Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /
              port: 8086
            periodSeconds: 1
          livenessProbe:
            httpGet:
              path: /
              port: 8086
            periodSeconds: 1
```

> **Image.** The app listens on **8086**, so it can't use the course image
> `ghcr.io/borisovcloud/devops2079/hellogo:latest`, which has `:8080` compiled in. It uses
> `hellogo:8086`, built from [hellogo/](hellogo/) straight into minikube in step 1.0. Nothing is
> pushed to a registry; `imagePullPolicy: IfNotPresent` makes the node use the local copy.
> After a `minikube delete`, rebuild it with step 1.0.

`gitops/hellogo-app/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-service
  labels:
    app: hello
spec:
  type: ClusterIP
  selector:
    app: hello
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8086
```

`gitops/hellogo-app/secret.yaml` (put **your** name in `username`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hello-secret
type: Opaque
stringData:
  username: Avi
```

> This is a training value, not a real secret. Real secrets never go into git in plain text
> (remember SOPS from the Helm block).

### 1.2 Optional: validate locally

```powershell
kubectl apply --dry-run=client -f gitops/hellogo-app
```

You should see three lines ending in `created (dry run)`. Nothing is changed in the cluster.

### 1.3 Commit and push

Stage **only** the `gitops` folder. Other lesson folders in the repo are untracked and must not be
swept into this commit.

```powershell
git add gitops/values-argocd.yaml gitops/hellogo-app
git status --short          # only the 4 gitops files under "A "
git commit -m "Lesson 035: hellogo manifests for Argo CD"
git push origin master
```

The push also sends the earlier local commit `Add Lesson 035 and ignore node_modules`. That is
expected. If the push is rejected, run `git pull --rebase origin master` and push again.

The *"LF will be replaced by CRLF"* warnings are harmless; Kubernetes accepts YAML with either line ending.

**Check:** the files are visible on GitHub:
https://github.com/nyurkadu/devops/tree/master/Lesson_035_20Now2026/gitops/hellogo-app

---

## Step 2 — Create the application in Argo CD (UI)

In the Argo CD UI click **+ NEW APP** and fill in:

| Section | Field | Value |
|---|---|---|
| GENERAL | Application Name | `hellogo` |
| | Project Name | `default` |
| | Sync Policy | `Automatic` → tick **Prune Resources** and **Self Heal** |
| | Sync Options | tick **Auto-Create Namespace** |
| SOURCE | Repository URL | `https://github.com/nyurkadu/devops.git` |
| | Revision | `HEAD` |
| | Path | `Lesson_035_20Now2026/gitops/hellogo-app` |
| DESTINATION | Cluster URL | `https://kubernetes.default.svc` |
| | Namespace | `hellogo` |

Click **CREATE**.

The *Path* dropdown lists every directory in the repo. Type the path rather than scrolling.

**Check (UI):** the `hellogo` tile shows **Synced** and **Healthy**. Click it to see the tree:
Deployment → ReplicaSet → 3 pods, plus Service and Secret.

**Check (CLI, read-only):**

```powershell
kubectl -n argo-cd get application hellogo        # SYNC STATUS Synced, HEALTH STATUS Healthy
kubectl -n hellogo get deploy,rs,pods,svc,secret  # 3/3 pods Running
```

📸 **Screenshot 1 for submission:** the application tree (Synced, Healthy).

**If something is wrong:**

| Symptom | Cause / fix |
|---|---|
| `ComparisonError` / `app path does not exist` | Path typo, or step 1 not pushed. Check the GitHub link from step 1. |
| Pods in `ErrImagePull` / `ImagePullBackOff` | `hellogo:8086` is not in minikube (e.g. after `minikube delete`). Re-run step 1.0; the pods recover by themselves. |
| Pods `Running` but `0/1` Ready, restarting | Port mismatch: the image listens on a different port than `containerPort` / probes. All must be 8086 with the `hellogo:8086` image. |
| Tile stuck in `Progressing` | `kubectl -n hellogo describe pod -l app=hello` and read the Events. |
| `namespace "hellogo" not found` | **Auto-Create Namespace** not ticked: *APP DETAILS* → *EDIT* → tick it. |

---

## Step 3 — Open the application in the browser

In **another separate terminal**:

```powershell
kubectl -n hellogo port-forward service/hello-service 8081:80
```

Open **http://localhost:8081**, or from PowerShell run:

```powershell
curl.exe http://localhost:8081
```

**Check:** the page shows the greeting with your name (`Avi`).

📸 **Screenshot 2 for submission:** the page with your greeting.

---

## Step 4 — Change the application through git, and only through git

From here on, **do not run `kubectl` commands that change anything** (no `apply`, `edit`, `scale`,
`delete`). Read-only commands (`get`, `describe`) are fine. The single allowed exception is the
`rollout restart` in 4.4.

### 4.1 Edit both files

- `gitops/hellogo-app/deployment.yaml`: `replicas: 3` → `replicas: 2`
- `gitops/hellogo-app/secret.yaml`: `username: Avi` → e.g. `username: Avi via GitOps`

### 4.2 One commit, push, note the time

```powershell
git add gitops/hellogo-app/deployment.yaml gitops/hellogo-app/secret.yaml
git commit -m "hellogo: 2 replicas, new greeting name"
git push origin master
git rev-parse --short HEAD     # remember this SHA
$pushed = Get-Date; "Pushed at $pushed"
```

### 4.3 Wait and watch without touching the cluster

Watch the pods (read-only), in the same terminal:

```powershell
kubectl -n hellogo get pods -w
```

When one pod goes `Terminating` and only two remain, press **Ctrl+C** and measure the wait:

```powershell
"Waited: $(((Get-Date) - $pushed).ToString('mm\:ss'))"
```

**Check (UI):** open the `hellogo` app. The **LAST SYNC** / *Sync status* panel shows the new
commit SHA from 4.2, and the tree has **2** pods.

**Why up to 3 minutes:** Argo CD has no push notification from GitHub (it runs on localhost, so
GitHub cannot send it a webhook). It **polls** the repo every ~3 minutes (`timeout.reconciliation`,
default 180 s). **REFRESH** in the UI forces Argo CD to fetch from git and compare *right now*, so
the sync starts immediately. Try it: make the next change and click **REFRESH** right after the push.

### 4.4 Make the new name appear

The greeting on the page has **not** changed yet. The app reads `GREETING` from the Secret only
when the pod starts, and changing a Secret does not restart pods. Restart them:

```powershell
kubectl -n hellogo rollout restart deployment/hello-deployment
kubectl -n hellogo rollout status  deployment/hello-deployment
```

This does not change the manifest (it only adds a `restartedAt` annotation to the pod template),
so Argo CD stays **Synced** and does not undo it.

The port-forward from step 3 was connected to a pod that has now been replaced, so it shows
`lost connection to pod`. Press **Ctrl+C** in that terminal and start it again:

```powershell
kubectl -n hellogo port-forward service/hello-service 8081:80
```

**Check:** http://localhost:8081 shows the new name, and the UI shows 2 pods on the new commit.

---

## Notes for submission (steps 1–4)

- **Repo link:** https://github.com/nyurkadu/devops (manifests in `Lesson_035_20Now2026/gitops/hellogo-app`)
- **Screenshot 1:** app tree, Synced and Healthy (step 2)
- **Screenshot 2:** greeting page (step 3)
- **Answer for step 4:** how long you waited (the `Waited:` value), and why: Argo CD polls git
  every ~3 min, with no webhook. What REFRESH does: forces an immediate fetch and compare against git.

## Pausing between sessions

```powershell
# Ctrl+C both port-forward terminals, then:
minikube stop
```

Next time: start Docker Desktop, run `minikube start`, then the two port-forwards from 0.5 and 3.
Argo CD and the app come back by themselves. Continue with step 5 in [HOMEWORK.md](HOMEWORK.md).

---

# Part 2 — Helm chart from the public repo, values from a private repo

The goal: one Argo CD application, `hellogo-helm`, that combines two repositories:

```text
 public  github.com/nyurkadu/devops          ── Helm chart (templates + default values) ──┐
                                                                                          ├─► Argo CD app "hellogo-helm" ─► namespace hellogo-helm
 private github.com/nyurkadu/hellogo-values  ── values.yaml (read with a token) ──────────┘
```

| What | Where | Visible to |
|---|---|---|
| Chart: templates and public defaults (`replicaCount: 1`, `greeting: public default`) | public repo, `Lesson_035_20Now2026/gitops/hellogo-chart/` | everyone |
| Argo CD application file | public repo, `Lesson_035_20Now2026/gitops/argocd/hellogo-helm.yaml` | everyone |
| Real values (`replicaCount: 2`, your greeting) | **private** repo, `hellogo/values.yaml` | you, and Argo CD via a token |
| Read-only GitHub token | only inside Argo CD (a Kubernetes Secret in `argo-cd`) | never in git |

The private values file overrides the chart's defaults. That makes it easy to tell which values
were used: **1 pod and "public default"** means the private repo was not read; **2 pods and your
greeting** means it was.

Run all commands in one terminal, starting in
`C:\Users\avila\devops\CloudLessons\Lesson_035_20Now2026`, with the [test helper](#test-helper-paste-once-per-terminal)
pasted in.

## P1 — Check the prerequisites

Nothing new to do here. This confirms that Helm, Argo CD, the CLI login and the image are in place.

### P1 test

```powershell
Test-Step 'helm is v3 or v4'                 { (helm version --short) -match '^v[34]\.' }
Test-Step 'minikube cluster is reachable'    { kubectl get nodes *> $null; $LASTEXITCODE -eq 0 }
Test-Step 'Argo CD server is running'        { [int](kubectl -n argo-cd get deploy argo-cd-argocd-server -o jsonpath='{.status.readyReplicas}') -ge 1 }
Test-Step 'argocd CLI is logged in'          { argocd app list *> $null; $LASTEXITCODE -eq 0 }
Test-Step 'gh CLI is logged in'              { gh auth status *> $null; $LASTEXITCODE -eq 0 }
Test-Step 'image hellogo:8086 is in minikube' { (minikube image ls | Out-String) -match 'hellogo:8086' }
```

### P1 troubleshooting

| Failed check | Fix |
|---|---|
| helm | [Install Helm](#install-helm). |
| cluster | Start Docker Desktop, then `minikube start`. |
| Argo CD server | Step 0.3 of Part 1; `kubectl -n argo-cd get pods` shows which pod is not ready. |
| argocd CLI | The port-forward from 0.5 must run, then `argocd login localhost:8889 --username admin --password '<password>' --plaintext --grpc-web`. |
| gh CLI | `gh auth login` → GitHub.com → HTTPS → log in with a browser. |
| image | `minikube image build -t hellogo:8086 hellogo` (step 1.0). |

## P2 — Create the Helm chart in the public repo

### P2.1 Create the files

```powershell
New-Item -ItemType Directory -Force gitops/hellogo-chart/templates | Out-Null
```

`gitops/hellogo-chart/Chart.yaml`:

```yaml
apiVersion: v2
name: hellogo
description: hellogo greeting app (Lesson 035)
type: application
version: 0.1.0
appVersion: "8086"
```

`gitops/hellogo-chart/values.yaml`. These are the **public defaults**; the private repo overrides them:

```yaml
# Public defaults. The private repo overrides what it needs.
replicaCount: 1
greeting: "public default"

image:
  repository: hellogo
  tag: "8086"
  pullPolicy: IfNotPresent   # image is built locally into minikube

containerPort: 8086          # the port compiled into hellogo/main.go

service:
  port: 80
```

`gitops/hellogo-chart/templates/secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hello-secret
  labels:
    app: hello
type: Opaque
stringData:
  username: {{ .Values.greeting | quote }}
```

`gitops/hellogo-chart/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-deployment
  labels:
    app: hello
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
      annotations:
        # new greeting -> new checksum -> pods restart by themselves
        checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    spec:
      containers:
        - name: hello
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.containerPort }}
          env:
            - name: GREETING
              valueFrom:
                secretKeyRef:
                  name: hello-secret
                  key: username
          resources:
            requests:
              memory: "6Mi"
              cpu: "250m"
            limits:
              memory: "32Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /
              port: {{ .Values.containerPort }}
            periodSeconds: 1
          livenessProbe:
            httpGet:
              path: /
              port: {{ .Values.containerPort }}
            periodSeconds: 1
```

> **The `checksum/secret` annotation** solves the Part 1 problem where a new greeting needed a
> manual `rollout restart`. When the greeting changes, the rendered Secret changes, so its checksum
> changes. That changes the pod template, and Kubernetes rolls the pods by itself.

`gitops/hellogo-chart/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-service
  labels:
    app: hello
spec:
  type: ClusterIP
  selector:
    app: hello
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.containerPort }}
```

### P2.2 Check locally, then push

```powershell
helm lint gitops/hellogo-chart
helm template hellogo-helm gitops/hellogo-chart      # read the rendered YAML

git add gitops/hellogo-chart
git commit -m "Lesson 035: hellogo Helm chart"
git push origin master
```

### P2 test

```powershell
Test-Step 'chart passes helm lint'                  { helm lint gitops/hellogo-chart *> $null; $LASTEXITCODE -eq 0 }
Test-Step 'chart renders Secret, Service, Deployment' { (helm template t gitops/hellogo-chart | Select-String '^kind: (Secret|Service|Deployment)$').Count -eq 3 }
Test-Step 'public default is 1 replica'             { (helm template t gitops/hellogo-chart | Out-String) -match 'replicas: 1' }
Test-Step 'cluster accepts the rendered YAML'       { helm template t gitops/hellogo-chart | kubectl apply --dry-run=server -n default -f - *> $null; $LASTEXITCODE -eq 0 }
Test-Step 'chart is pushed to GitHub'               { (curl.exe -s -o NUL -w '%{http_code}' https://api.github.com/repos/nyurkadu/devops/contents/Lesson_035_20Now2026/gitops/hellogo-chart/Chart.yaml) -eq '200' }
```

### P2 troubleshooting

| Symptom | Fix |
|---|---|
| `helm lint`: `Chart.yaml file is missing` | Wrong folder: the path must be `gitops/hellogo-chart/Chart.yaml` (capital **C**). |
| `parse error` / `unexpected "}"` | A typo inside `{{ ... }}` in a template. The error names the file and line. Compare with the blocks above. |
| `nil pointer evaluating interface {}.port` | `values.yaml` is missing `service:` → `port:`, or the indentation is wrong. YAML needs spaces, never tabs. |
| Renders fewer than 3 objects | A template file is missing from `templates/`, or it is not named `*.yaml`. |
| Server dry-run fails | Run it without `*> $null` to see the error. Usually a wrong indentation level in `deployment.yaml`. |
| GitHub check returns 404 | The commit is not pushed: `git status -sb` shows `ahead`. Run `git push origin master`. |

## P3 — Create the private values repository

Create it **outside** `CloudLessons`: one git repo inside another becomes an embedded repo and
causes confusing `git status` output.

```powershell
Set-Location C:\Users\avila\devops
gh repo create hellogo-values --private --description "Private Helm values for hellogo (Lesson 035)" --clone
Set-Location C:\Users\avila\devops\hellogo-values
New-Item -ItemType Directory -Force hellogo | Out-Null
```

Depending on the `gh` version, you may see *"You appear to have cloned an empty repository"*, or
no message at all. Both are fine. To confirm the folder is connected to the new repo, run
`git remote -v`: it shows `origin https://github.com/nyurkadu/hellogo-values.git`.

Create `C:\Users\avila\devops\hellogo-values\hellogo\values.yaml`:

```yaml
# Private values for hellogo. Overrides the chart's values.yaml.
replicaCount: 2
greeting: "Avi from a private repo"
```

```powershell
git add hellogo/values.yaml
git commit -m "hellogo: private values"
git push -u origin HEAD
```

### P3 test

```powershell
Test-Step 'repo exists and is PRIVATE'           { (gh repo view nyurkadu/hellogo-values --json visibility -q .visibility) -eq 'PRIVATE' }
Test-Step 'anonymous access is refused (404)'    { (curl.exe -s -o NUL -w '%{http_code}' https://api.github.com/repos/nyurkadu/hellogo-values) -eq '404' }
Test-Step 'values file is pushed'                { (gh api repos/nyurkadu/hellogo-values/contents/hellogo/values.yaml --jq .name) -eq 'values.yaml' }
Test-Step 'pushed values file is not empty'      { [int](gh api repos/nyurkadu/hellogo-values/contents/hellogo/values.yaml --jq .size) -gt 0 }
Test-Step 'no unsaved/uncommitted changes'       { -not (git -C C:\Users\avila\devops\hellogo-values status --porcelain) }
Test-Step 'clone is not nested in CloudLessons'  { (git -C C:\Users\avila\devops\hellogo-values rev-parse --show-toplevel) -eq 'C:/Users/avila/devops/hellogo-values' }
```

### P3 troubleshooting

| Symptom | Fix |
|---|---|
| `Name already exists on this account` | The repo exists already. Clone it instead: `gh repo clone nyurkadu/hellogo-values C:\Users\avila\devops\hellogo-values`. |
| Visibility is `PUBLIC` | `gh repo edit nyurkadu/hellogo-values --visibility private --accept-visibility-change-consequences`. |
| Anonymous access returns `200` | The repo is public: see the line above. |
| `src refspec HEAD does not match any` on push | Nothing is committed yet: run `git add` and `git commit` first. |
| `values file is pushed` fails | Wrong path: it must be `hellogo/values.yaml` at the repo root. `gh repo view nyurkadu/hellogo-values --web` opens it in the browser. |
| `pushed values file is not empty` or `no uncommitted changes` fails | The file was committed **before it was saved** in the editor. Save it (Ctrl+S), then `git commit -am "hellogo: private values content"` and `git push`. Later symptom: the app shows 1 pod and "public default". |
| Clone ended up inside `CloudLessons` | Move the folder to `C:\Users\avila\devops\hellogo-values`. Its own `.git` folder moves with it, so nothing is lost. |

## P4 — Create a read-only token for Argo CD

Argo CD needs its own credential to read the private repo. Use a **fine-grained personal access
token** that can only **read** this one repository.

On GitHub: profile picture → **Settings** → **Developer settings** → **Personal access tokens** →
**Fine-grained tokens** → **Generate new token**:

| Field | Value |
|---|---|
| Token name | `argocd-hellogo-values` |
| Expiration | 30 days |
| Resource owner | `nyurkadu` |
| Repository access | **Only select repositories** → `nyurkadu/hellogo-values` |
| Permissions → Repository permissions | **Contents: Read-only** (Metadata: Read-only is added automatically) |

Click **Generate token**, then click the **copy icon** next to it (it starts with `github_pat_`).
GitHub shows it **only once**. Load it into a variable in this terminal. Never paste it into
files or chats.

1. Paste this line into the terminal and press Enter. It **waits** at the prompt:
   ```powershell
   Read-Host 'Copy the token on GitHub (copy icon), then press Enter here' | Out-Null; $pat = (Get-Clipboard -Raw).Trim(); "token length: $($pat.Length)"
   ```
2. Go to GitHub and click the **copy icon** next to the token.
3. Come back and press **Enter**. It must print `token length: 93`.

> **Why this order:** copying this command from the guide also uses the clipboard, so it would
> replace the token there. The prompt lets you copy the token *after* the command is pasted.
> Don't use `Read-Host -MaskInput` to paste the token itself: in the VS Code terminal it can
> silently drop characters. Reading the clipboard gets the whole token and keeps it out of the
> PowerShell history.

### P4 test

```powershell
Test-Step 'token is set in this terminal'            { $pat -like 'github_pat_*' }
Test-Step 'token is complete (93 characters)'        { $pat.Length -eq 93 }
Test-Step 'token can read the private values file'   { (curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $pat" https://api.github.com/repos/nyurkadu/hellogo-values/contents/hellogo/values.yaml) -eq '200' }
Test-Step 'token is not committed in CloudLessons'   { git -C C:\Users\avila\devops\CloudLessons grep -q -I -F -e $pat HEAD; $LASTEXITCODE -eq 1 }
Test-Step 'token is not committed in hellogo-values' { git -C C:\Users\avila\devops\hellogo-values grep -q -I -F -e $pat HEAD; $LASTEXITCODE -eq 1 }
```

### P4 troubleshooting

| Symptom | Fix |
|---|---|
| `token is set` fails | New terminal, or the clipboard held something else, usually the command you just copied from the guide. Re-run the `Read-Host … Get-Clipboard` line and copy the token **while it waits**. |
| HTTP `400` | The variable holds text with spaces or line breaks, not a token. Same fix as above. |
| `token is complete` fails | Only part of the token was copied (e.g. pasted through `Read-Host`). Use the `Get-Clipboard` line. If the token is no longer shown on GitHub, open it and click **Regenerate token**. |
| HTTP `401` | The token is wrong or expired, or was copied with a space. Generate a new one. |
| HTTP `404` | The token was not given access to `hellogo-values` (fine-grained tokens see only the selected repos), or the file path is wrong. Edit the token → **Repository access**. |
| HTTP `403` | **Contents** permission missing (edit the token), or the API rate limit was hit (wait a few minutes). |
| `token is not committed` fails | The token is in a committed file. Revoke it on GitHub **immediately**, generate a new one, and remove it from the file. Rewriting history is not enough once it has been pushed. |

## P5 — Connect the private repo to Argo CD

**Option A, UI:** ⚙ **Settings** → **Repositories** → **+ CONNECT REPO** → **VIA HTTP/HTTPS**:

| Field | Value |
|---|---|
| Type | `git` |
| Name | `hellogo-values` |
| Project | leave empty (the repo is then available to every project) |
| Repository URL | `https://github.com/nyurkadu/hellogo-values.git` |
| Username | `nyurkadu` |
| Password | the token from P4 |

Click **CONNECT**.

**Option B, CLI** (same result, uses `$pat` from P4):

```powershell
argocd repo add https://github.com/nyurkadu/hellogo-values.git --name hellogo-values --username nyurkadu --password $pat
```

Argo CD stores the URL, username and token as a Kubernetes Secret in the `argo-cd` namespace.
Nothing goes into git.

### P5 test

```powershell
$valuesRepo = 'https://github.com/nyurkadu/hellogo-values.git'
Test-Step 'Argo CD knows the private repo'       { (argocd repo list -o url) -contains $valuesRepo }
Test-Step 'connection status is Successful'      { (argocd repo get $valuesRepo --refresh hard -o json | ConvertFrom-Json).connectionState.status -eq 'Successful' }
Test-Step 'credentials are a Secret in argo-cd'  { [bool](kubectl -n argo-cd get secret -l argocd.argoproj.io/secret-type=repository -o name) }
```

### P5 troubleshooting

| Symptom | Fix |
|---|---|
| Status `Failed`: `authentication required` / `invalid username or password` | Wrong token, or the token cannot read this repo. Re-run the P4 test, then re-add: `argocd repo add ... --upsert`. |
| Status `Failed`: `repository not found` | URL typo. It must be exactly `https://github.com/nyurkadu/hellogo-values.git`. |
| `Argo CD knows the private repo` fails but the UI shows it | The URL in Argo CD differs from `$valuesRepo` (e.g. no `.git`). It must match **exactly** the `repoURL` used in P6. Delete it (`argocd repo rm <url>`) and add it again. |
| `argocd: Unauthenticated` / `connection refused` | The 0.5 port-forward stopped, or the CLI session expired. Restart the port-forward, then `argocd login` again. |
| No repository Secret | The repo was never saved. Repeat option A or B. |

## P6 — Create the Argo CD application (the pipeline)

The application has **two sources**: the chart from the public repo and the values from the private
repo. Create it in the UI (**option A**) **or** from a file (**option B**), not both. If you do both,
the second fails because the app already exists.

### P6.1 Write the application file (public repo)

Write this file for both options. It documents the app in git (the same idea as homework step 8),
and both options use it: A as a paste shortcut, B to apply. Create
`gitops/argocd/hellogo-helm.yaml` in the **public** repo:

```powershell
Set-Location C:\Users\avila\devops\CloudLessons\Lesson_035_20Now2026
New-Item -ItemType Directory -Force gitops/argocd | Out-Null
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hellogo-helm
  namespace: argo-cd               # Applications live next to Argo CD
spec:
  project: default
  sources:
    # 1) the chart, from the PUBLIC repo
    - repoURL: https://github.com/nyurkadu/devops.git
      targetRevision: HEAD
      path: Lesson_035_20Now2026/gitops/hellogo-chart
      helm:
        valueFiles:
          - $values/hellogo/values.yaml   # "$values" = root of the source with ref: values
    # 2) the values, from the PRIVATE repo (no path: it only provides files)
    - repoURL: https://github.com/nyurkadu/hellogo-values.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: hellogo-helm
  syncPolicy:
    automated:
      enabled: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The file contains no secrets, so it belongs in git. `gitops/argocd/` is outside every app's `path`,
so Argo CD never applies it by itself. Commit and push it:

```powershell
git add gitops/argocd/hellogo-helm.yaml
git commit -m "Lesson 035: Argo CD app hellogo-helm (chart public, values private)"
git push origin master
```

### P6.2 Create the application

#### Option A — in the UI (+ NEW APP)

Open http://localhost:8889 → **Applications** → **+ NEW APP**. Fill the panel from top to bottom.

**1. GENERAL**

| Field | Value |
|---|---|
| Application Name | `hellogo-helm` |
| Project Name | `default` |
| Sync Policy | `Automatic`. Three checkboxes appear below it. |
| ↳ Enable Auto-Sync | keep it **ticked** (the default). Unticked, the app never syncs by itself, as in Part 1. |
| ↳ Prune Resources | tick |
| ↳ Self Heal | tick |
| Set Deletion Finalizer | leave unticked |
| Sync Options | tick **Auto-Create Namespace** |

**2. SOURCE**: the chart, from the public repo. This becomes **SOURCE 1** in step 3.

| Field | Value |
|---|---|
| Repository URL | `https://github.com/nyurkadu/devops.git` |
| Revision | `HEAD` |
| Path | `Lesson_035_20Now2026/gitops/hellogo-chart` |

Once the path is set, Argo CD detects the chart and shows a **Helm** block under the source.
Leave it as it is: the chart's own `values.yaml` is always used, and the private file is added in step 5.

**3. Click Add Source** (below the source). The section splits into **SOURCE 1** and **SOURCE 2**.
Fill **SOURCE 2**, the values from the private repo:

| Field | Value |
|---|---|
| Repository URL | `https://github.com/nyurkadu/hellogo-values.git` (offered in the dropdown once P5 is done) |
| Revision | `HEAD` |
| Path | leave **empty**: this source only provides the values file |

**4. DESTINATION**

| Field | Value |
|---|---|
| Cluster URL | `https://kubernetes.default.svc` |
| Namespace | `hellogo-helm` |

**5. Finish in YAML.** The form has no field for naming a source (`ref`), so this part is done in
the YAML editor. Click **Edit as YAML** (top right of the GENERAL box). Find `sources:` and make it
look exactly like this. There are two additions: `helm.valueFiles` in the first source and
`ref: values` in the second. If the second source has `path: ''`, delete that line.

```yaml
  sources:
    - repoURL: https://github.com/nyurkadu/devops.git
      targetRevision: HEAD
      path: Lesson_035_20Now2026/gitops/hellogo-chart
      helm:
        valueFiles:
          - $values/hellogo/values.yaml
    - repoURL: https://github.com/nyurkadu/hellogo-values.git
      targetRevision: HEAD
      ref: values
```

> **Shortcut for step 5:** select everything in the editor (**Ctrl+A**) and paste the whole file
> from P6.1 instead. It gives the same result, without hunting for the right lines.

**6. Save** the YAML (button at the top right of the editor). The form returns with your values.

**7. Click CREATE** at the top of the panel.

#### Option B — from the file

```powershell
kubectl apply -f gitops/argocd/hellogo-helm.yaml
```

### P6.3 Wait for the sync and open the app

```powershell
kubectl -n argo-cd wait application/hellogo-helm --for=jsonpath='{.status.sync.status}'=Synced --timeout=180s
kubectl -n hellogo-helm rollout status deployment/hello-deployment --timeout=180s
```

In a **separate terminal**:

```powershell
kubectl -n hellogo-helm port-forward service/hello-service 8082:80
```

### P6 test

```powershell
Test-Step 'auto-sync is enabled'                   { $a = kubectl -n argo-cd get application hellogo-helm -o json | ConvertFrom-Json; $a.spec.syncPolicy.automated -and $a.spec.syncPolicy.automated.enabled -ne $false }
Test-Step 'source 2 is the values ref'             { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.spec.sources[1].ref}') -eq 'values' }
Test-Step 'chart reads the private values file'    { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.spec.sources[0].helm.valueFiles[0]}') -eq '$values/hellogo/values.yaml' }
Test-Step 'app is Synced'                          { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.status.sync.status}') -eq 'Synced' }
Test-Step 'app is Healthy'                         { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.status.health.status}') -eq 'Healthy' }
Test-Step 'both sources resolved (chart + values)' { @(kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.status.sync.revisions}' | ConvertFrom-Json).Count -eq 2 }
Test-Step 'replicas come from the private repo (2)' { (kubectl -n hellogo-helm get deploy hello-deployment -o jsonpath='{.status.readyReplicas}') -eq '2' }
Test-Step 'greeting comes from the private repo'   { (curl.exe -s http://localhost:8082 | Out-String) -match 'from a private repo' }
```

In the UI, the `hellogo-helm` tile shows **Synced** and **Healthy**, and **APP DETAILS** lists both
sources.

### P6 troubleshooting

| Symptom | Fix |
|---|---|
| `ComparisonError` … `hellogo-values` … `authentication required` / `repository not found` | P5 is not done, or the URL there differs from `repoURL` here. Run the P5 test. |
| `$values/hellogo/values.yaml: no such file or directory` | The file is not at `hellogo/values.yaml` in the private repo, or not pushed. Run the P3 test. |
| `app path does not exist` / `Chart.yaml file is missing` | The chart is not pushed, or `path` has a typo. Run the P2 test. |
| Helm error in the app (`parse error`, `nil pointer`) | Reproduce it locally with the same values: `helm template t gitops/hellogo-chart -f C:\Users\avila\devops\hellogo-values\hellogo\values.yaml`. |
| 1 pod and "public default" | The private values were not used. Either the pushed `values.yaml` is empty (run the P3 test), or `valueFiles` does not start with `$values/`, or the second source lacks `ref: values`. |
| `OutOfSync` and nothing happens / `auto-sync is enabled` fails | Auto-sync is off. UI: open the app → **APP DETAILS** → **SYNC POLICY** → **ENABLE AUTO-SYNC**. File: check `automated:` → `enabled: true`, then `kubectl apply -f` again. |
| `source 2 is the values ref` / `chart reads the private values file` fails | Option A step 5 was skipped or incomplete. Open the app → **APP DETAILS** → **Manifest** tab → **Edit**, and fix `sources:` as shown in step 5. |
| (A) Repository URL dropdown does not offer `hellogo-values` | P5 is not done or its connection failed. Run the P5 test. You can also type the URL by hand. |
| (A) **Edit as YAML** shows `source:` (one source), not `sources:` | **Add Source** was not clicked. Replace the whole `source:` block with the `sources:` block from step 5, or use the Ctrl+A shortcut. |
| (A) Form fields are empty after **Save** in YAML, or `Invalid YAML` | Indentation error in the editor. Use the Ctrl+A shortcut and paste the P6.1 file. |
| **CREATE** / `kubectl apply` fails: `already exists` / `existing application spec is different` | The app was already created (both options were used). Keep the existing one, or **DELETE** it in the UI and create it again. |
| App does not appear in the UI | (B) It was applied to the wrong namespace: `metadata.namespace` must be `argo-cd`. |
| Pods in `ErrImagePull` / `ImagePullBackOff` | `minikube image build -t hellogo:8086 hellogo` (step 1.0). |
| Greeting check fails, other checks pass | The 8082 port-forward is not running. Start it and test again. |

## P7 — End-to-end test: change the values in the private repo

This proves the pipeline works: a commit to the **private** repo alone changes the cluster.

Edit `C:\Users\avila\devops\hellogo-values\hellogo\values.yaml`:

```yaml
replicaCount: 3
greeting: "Avi, values v2 from a private repo"
```

```powershell
Set-Location C:\Users\avila\devops\hellogo-values
git commit -am "hellogo: 3 replicas, greeting v2"
git push
argocd app get hellogo-helm --refresh *> $null      # like the REFRESH button: don't wait 3 minutes
kubectl -n hellogo-helm rollout status deployment/hello-deployment --timeout=180s
```

The pods restart by themselves because of the `checksum/secret` annotation, so there's no
`rollout restart` this time. The restart drops the 8082 port-forward: press **Ctrl+C** in that
terminal and start it again.

### P7 test

```powershell
Test-Step 'Argo CD synced the new values commit' { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.status.sync.revisions[1]}') -eq (git -C C:\Users\avila\devops\hellogo-values rev-parse HEAD) }
Test-Step 'replicas are now 3'                   { (kubectl -n hellogo-helm get deploy hello-deployment -o jsonpath='{.status.readyReplicas}') -eq '3' }
Test-Step 'new greeting without rollout restart' { (curl.exe -s http://localhost:8082 | Out-String) -match 'values v2' }
Test-Step 'app is still Synced and Healthy'      { (kubectl -n argo-cd get application hellogo-helm -o jsonpath='{.status.sync.status}/{.status.health.status}') -eq 'Synced/Healthy' }
```

### P7 troubleshooting

| Symptom | Fix |
|---|---|
| New commit not picked up | Check that the push reached GitHub: `git -C C:\Users\avila\devops\hellogo-values status -sb` must not say `ahead`. Then `argocd app get hellogo-helm --refresh`. |
| Replicas changed, greeting did not | The pod template has no `checksum/secret` annotation: check `templates/deployment.yaml` (P2), then push the chart. |
| `new greeting` check: connection refused | The 8082 port-forward is attached to a deleted pod. Restart it. |
| Sync `Failed` after the change | YAML error in the new `values.yaml` (indentation, missing quote). Check it locally with the `helm template ... -f` command from P6. |

## P8 — Clean up and security

When you've finished with Part 2:

```powershell
argocd app delete hellogo-helm --yes                   # or DELETE in the UI; removes the app's objects
kubectl delete namespace hellogo-helm --ignore-not-found
argocd repo rm https://github.com/nyurkadu/hellogo-values.git
```

Then revoke the token on GitHub: **Settings** → **Developer settings** → **Fine-grained tokens** →
`argocd-hellogo-values` → **Delete**. A token that is no longer used shouldn't stay valid.

### P8 test

```powershell
Test-Step 'app is gone'             { -not (kubectl -n argo-cd get application hellogo-helm -o name 2>$null) }
Test-Step 'namespace is gone'       { -not (kubectl get namespace hellogo-helm -o name 2>$null) }
Test-Step 'repo is disconnected'    { -not ((argocd repo list -o url) -contains 'https://github.com/nyurkadu/hellogo-values.git') }
Test-Step 'token no longer works'   { (curl.exe -s -o NUL -w '%{http_code}' -H "Authorization: Bearer $pat" https://api.github.com/repos/nyurkadu/hellogo-values) -eq '401' }
```

### P8 troubleshooting

| Symptom | Fix |
|---|---|
| Namespace stuck in `Terminating` | Wait a minute; Argo CD is still deleting the objects. Check with `kubectl -n hellogo-helm get all`. |
| `token no longer works` fails | The token is not deleted on GitHub yet, or `$pat` is from a different token. Delete it in the GitHub UI. |
