# Lesson 035 homework — steps 1–4: hellogo under Argo CD

Step-by-step runbook for the base assignment in [HOMEWORK.md](HOMEWORK.md), steps 1–4, including a
fresh Argo CD install. Steps 5–7 build on what you set up here.

## Conventions used below

| Item | Value |
|---|---|
| Shell | PowerShell 7 (all commands below are PowerShell, not bash) |
| Working directory | `C:\Users\avila\devops\CloudLessons\Lesson_035_20Now2026` (unless stated otherwise) |
| Your Git repo | `https://github.com/nyurkadu/devops.git` (public, branch `master`) |
| Manifests in the repo | `Lesson_035_20Now2026/gitops/hellogo-app/` |
| Argo CD UI | http://localhost:8889 (port 8080 is often busy on this machine) |
| hellogo app | http://localhost:8081 |

> **Path note.** The assignment says `gitops/hellogo-app`, assuming the repo root. Your repo keeps each
> lesson in its own folder, so the Argo CD **Path** is `Lesson_035_20Now2026/gitops/hellogo-app`.
> To match the assignment literally instead, create `gitops/` at the repo root
> (`C:\Users\avila\devops\CloudLessons\gitops`) and use `gitops/hellogo-app` as the Path.

Reference files come from the course repo:
[BorisovCloud/devops2079 → gitops](https://github.com/BorisovCloud/devops2079/tree/main/gitops).

---

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
