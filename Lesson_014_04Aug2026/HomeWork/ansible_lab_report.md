# Ansible Lab: One Control Node and Two Managed Nodes (Dockerized)

**Environment:** [Killercoda](https://killercoda.com/) Ubuntu playground (fresh VM, `apt` only)
**Goal:** Set up an Ansible control node, provision two managed nodes as Docker containers, verify connectivity by writing/reading a file, then write and run a playbook that installs and configures Nginx.

---

## 1. Architecture

- **Control node**: the Killercoda Ubuntu VM itself, with Ansible installed directly on it.
- **Managed nodes**: two Docker containers (`node1`, `node2`) running a full Ubuntu 20.04 image with `systemd` as PID 1 (`geerlingguy/docker-ubuntu2004-ansible`). A real init system is required inside the containers because the final task uses the Ansible `service` module (`systemctl start/enable nginx`), which does not work in bare, init-less containers.
- **Connection method**: Ansible's `community.docker.docker` connection plugin, which talks to containers via `docker exec` instead of SSH. This removes the need for SSH servers, keys, and host key management entirely — appropriate for a local Docker-based lab.

```
[Control node: Ansible on Killercoda VM]
        │  (docker exec, no SSH)
        ├──> [node1: Ubuntu 20.04 + systemd, Docker container]
        └──> [node2: Ubuntu 20.04 + systemd, Docker container]
```

---

## 2. Installing Docker and Ansible on the Control Node

```bash
apt update && apt upgrade -y
apt install -y docker.io ansible python3-docker curl
systemctl enable --now docker
```

`python3-docker` is installed via `apt` (not `pip`) because Ubuntu 24.04+ blocks system-wide `pip install` (PEP 668, "externally-managed-environment"). Using the distro package avoids that error entirely.

Install the Ansible collection that provides the Docker connection plugin:

```bash
ansible-galaxy collection install community.docker
```

Verify Docker works:

```bash
docker run hello-world
```

---

## 3. Creating the Two Managed Nodes

```bash
docker run -d --name node1 --privileged --cgroupns=host \
  -p 8081:80 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  geerlingguy/docker-ubuntu2004-ansible:latest

docker run -d --name node2 --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  geerlingguy/docker-ubuntu2004-ansible:latest
```

Notes on the flags:
- `--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` — required for `systemd` to run correctly inside a container.
- `-p 8081:80` on `node1` publishes the container's port 80 to port 8081 on the VM host, so the Nginx page can be reached externally (see Section 8). `node2` is left unpublished since it's only accessed internally through Ansible/`docker exec`.

---

## 4. Inventory Configuration (`inventory.ini`)

```bash
mkdir -p ~/ansible-lab && cd ~/ansible-lab
cat > inventory.ini << 'EOF'
[nodes]
node1 ansible_connection=community.docker.docker
node2 ansible_connection=community.docker.docker

[nodes:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
```

- `ansible_connection=community.docker.docker` tells Ansible to reach each host via `docker exec` using the container name as the target — no IP address or SSH credentials needed.
- `ansible_python_interpreter` points at the Python 3 binary inside the container image.

Connectivity check:

```bash
ansible -i inventory.ini nodes -m ping
```

Expected output: both `node1` and `node2` return `"ping": "pong"`.

---

## 5. Ad-hoc Commands: Write and Read a File

**Write a text file on both managed nodes from the control node:**

```bash
ansible -i inventory.ini nodes -m copy \
  -a "content='Hello from Ansible control node' dest=/tmp/greeting.txt"
```

**Read the file back, two ways:**

a) Print its contents remotely (output shown on the control node):

```bash
ansible -i inventory.ini nodes -m command -a "cat /tmp/greeting.txt"
```

b) Actually pull the file down to the control node (demonstrates real data transfer, not just remote output):

```bash
ansible -i inventory.ini nodes -m fetch -a "src=/tmp/greeting.txt dest=./fetched/ flat=no"
cat ./fetched/node1/tmp/greeting.txt
cat ./fetched/node2/tmp/greeting.txt
```

This confirms the control node can both push and pull data through Ansible without any manual login to the managed nodes.

---

## 6. Playbook: Install and Configure Nginx

`nginx.yml`:

```yaml
---
- name: Install and configure Nginx
  hosts: nodes
  tasks:
    - name: Ensure Nginx is installed
      apt:
        name: nginx
        state: present
        update_cache: true

    - name: Create custom index.html page
      copy:
        content: |
          <html>
            <head><title>Ansible Lab</title></head>
            <body><h1>Hello from {{ inventory_hostname }}</h1></body>
          </html>
        dest: /var/www/html/index.html

    - name: Ensure Nginx service is started and enabled at boot
      service:
        name: nginx
        state: started
        enabled: true
```

Design notes:
- `become:` (privilege escalation) is **not** needed — the Docker connection plugin already executes as `root` inside the container by default.
- The `copy` module with inline `content:` avoids needing a separate template file — appropriate for a minimal lab.
- `service: state=started enabled=true` satisfies both "started now" and "enabled at boot" in a single task.

Run the playbook:

```bash
ansible-playbook -i inventory.ini nginx.yml
```

Result: playbook completes with `failed=0` for both hosts.

---

## 7. Verification

```bash
docker exec node1 systemctl is-active nginx
docker exec node1 cat /var/www/html/index.html
docker exec node2 systemctl is-active nginx
docker exec node2 cat /var/www/html/index.html
```

Both should report `active` and show the custom HTML page with the respective hostname.

(Note: the base image does not ship `curl`, so verification uses `cat`/`systemctl` directly rather than an HTTP request. `curl` can be installed with `docker exec node1 apt install -y curl` if an actual HTTP GET is preferred.)

---

## 8. Exposing the Service Externally

Killercoda exposes a VM port through a public URL (e.g. `https://<id>-8081.<region>.killercoda.com/`), but only if something is actually listening on that port **on the host**, not just inside the container. Docker containers are network-isolated by default, so the container's port 80 must be explicitly published with `-p 8081:80` (see Section 3).

After recreating `node1` with the `-p 8081:80` flag and re-running the playbook:

```bash
ansible-playbook -i inventory.ini nginx.yml --limit node1
curl -s localhost:8081
```

Once this returns the custom HTML locally, the Killercoda public URL serves the same page — resolving the initial `502 Bad Gateway` (which occurred because no process was listening on the host's port 8081 before publishing).

---

## 9. Summary

| Step | Tool/Module | Purpose |
|---|---|---|
| Provisioning | `docker run` | Create isolated managed nodes without SSH setup |
| Connectivity | `community.docker.docker` connection plugin | Agentless control via `docker exec` |
| Inventory | `inventory.ini` | Declare managed hosts and connection parameters |
| Ad-hoc test | `copy`, `command`, `fetch` modules | Demonstrate push/pull of data control → node → control |
| Automation | `nginx.yml` playbook | Idempotent install, configure, and service management |
| Exposure | Docker port publishing (`-p`) | Make the containerized service reachable outside the lab VM |
