# Lab Exam — Multi-Tier Secure Infrastructure Setup

Step-by-step instructions for Docker Desktop on Windows. **One container, no SSH keys, no systemd, no docker-compose.**

Work happens **inside** the container (real Linux file permissions, LF line endings), then you copy the finished project out to Windows in Step 7 for submission.

---

## Design decision you should know about

`node1` and `node2` are both defined as **local connections to the same container**. This is what keeps the exam simple: no SSH, no key distribution, no second machine.

It still satisfies every passing criterion — `serial: 1` genuinely rolls through two hosts one at a time, and everything runs idempotently.

If your instructor requires two physically separate machines, **only `inventory.ini` changes** — every playbook, role, and template below stays exactly the same.

---

## Step 0 — Start the container (PowerShell)

Docker Desktop running, then:

```powershell
docker run -d --name exam geerlingguy/docker-ubuntu2204-ansible:latest sleep infinity
docker exec -it exam bash
```

**Everything from here runs inside the container.** Copy-paste each block as-is.

---

## Phase 1 — Environment & Inventory Setup

```bash
mkdir -p ~/ansible-exam-lab && cd ~/ansible-exam-lab
```

### 1.1 Inventory

```bash
cat > inventory.ini << 'EOF'
[webservers]
node1
node2

[database]
node1

[production:children]
webservers
database

[production:vars]
ansible_connection=local
EOF
```

### 1.2 Vault password file — no trailing newline, mode 600

`printf` is used instead of `echo` precisely because `echo` would add the trailing newline the spec forbids.

```bash
printf 'ExamVaultSecret2026' > .vault_pass
chmod 600 .vault_pass
```

Verify both requirements at once:

```bash
ls -l .vault_pass          # expect -rw-------
wc -c < .vault_pass        # expect exactly 19 (no trailing newline)
```

### 1.3 `.gitignore`

```bash
cat > .gitignore << 'EOF'
.vault_pass
EOF
```

### 1.4 Check the inventory parses correctly

```bash
ansible-inventory -i inventory.ini --graph
```

Expect `@production` containing `@webservers` (node1, node2) and `@database` (node1).

---

## Phase 2 — Role Creation & Templating

### 2.1 Scaffold

```bash
ansible-galaxy role init roles/webapp
```

### 2.2 Defaults — `roles/webapp/defaults/main.yml`

```bash
cat > roles/webapp/defaults/main.yml << 'EOF'
---
app_port: 80
app_title: "Enterprise Portal"

EOF
```

### 2.3 Template — `roles/webapp/templates/index.html.j2`

```bash
cat > roles/webapp/templates/index.html.j2 << 'EOF'
<h1>{{ app_title }}</h1>
<p>Hostname: {{ ansible_hostname }}</p>
<p>IP Address: {{ ansible_default_ipv4.address | default('N/A') }}</p>

<h2>Active Web Servers</h2>
<ul>
{% for host in groups['webservers'] %}
  <li>{{ host }}</li>
{% endfor %}
</ul>
EOF
```

### 2.4 Handler — `roles/webapp/handlers/main.yml`

```bash
cat > roles/webapp/handlers/main.yml << 'EOF'
---
- name: restart webserver
  service:
    name: "{{ my_webserver }}"
    state: started
    enabled: true
EOF
```

### 2.5 Tasks — `roles/webapp/tasks/main.yml`

```bash
cat > roles/webapp/tasks/main.yml << 'EOF'
---
- name: Set OS-specific web server package name
  set_fact:
    my_webserver: "{{ 'apache2' if ansible_facts['os_family'] == 'Debian' else 'httpd' }}"

- name: Update package cache (Debian)
  apt:
    update_cache: yes
  when: ansible_facts['os_family'] == 'Debian'

- name: Update package cache (RedHat)
  dnf:
    update_cache: yes
  when: ansible_facts['os_family'] == 'RedHat'

- name: Install web server package
  package:
    name: "{{ my_webserver }}"
    state: present

- name: Deploy index.html from template
  template:
    src: index.html.j2
    dest: /var/www/html/index.html
    mode: '0644'
  notify: restart webserver
EOF
```

---

## Phase 3 — Resilient Logic & Error Handling

```bash
cat > maintenance_check.yml << 'EOF'
---
- name: Pre-flight system maintenance checks
  hosts: production
  become: true
  serial: 1

  tasks:
    - name: Update package cache (Debian)
      apt:
        update_cache: yes
        cache_valid_time: 3600
      when: ansible_facts['os_family'] == 'Debian'

    - name: Install system diagnostic utilities
      package:
        name: "{{ item }}"
        state: present
      loop:
        - curl
        - htop
        - unzip

    - block:
        - name: Check available disk space on root filesystem
          shell: df --output=pcent / | tail -1 | tr -dc '0-9'
          register: disk_usage
          changed_when: false
          failed_when: disk_usage.stdout | int > 80

      rescue:
        - name: Warn about disk threshold
          debug:
            msg: "Disk usage threshold exceeded! Triggering automated log cleanup..."

      always:
        - name: Append execution timestamp to maintenance log
          lineinfile:
            path: /tmp/maintenance.log
            line: "Maintenance check executed at {{ ansible_date_time.iso8601 }}"
            create: true
EOF
```

Things to understand here, because a grader may ask:

- **`changed_when: false`** on the `df` task — reading disk usage changes nothing, so without this Ansible would report a false `changed`.
- **`failed_when`** deliberately raises the error that `rescue` catches. If your Docker disk is over 80% full, the rescue branch fires. **That is correct behaviour, not a failure** — the play still ends green because `rescue` handles it.
- **`create: true`** on the `lineinfile` task is mandatory, not optional. `/tmp/maintenance.log` does not exist on a fresh container, and without this flag the task aborts with `Destination /tmp/maintenance.log does not exist!`.
- **`serial: 1`** and the **cache update task** are not in the exam spec — they are required by this single-container lab. See the two notes below.

### Why `serial: 1` is on this play

`node1` and `node2` are the same container, so by default Ansible runs the install task on both **in parallel** — and they collide on the same `dpkg` lock:

```
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 736 (apt-get)
```

`serial: 1` processes one host at a time and removes the collision. On two genuinely separate machines you would not need it here.

### Why the cache update task is first

The base image ships with an empty apt cache, and this playbook runs **before** the `webapp` role under the master command. Without it the very first task fails with `No package matching 'curl' is available`. `cache_valid_time: 3600` keeps it from re-running on every execution, which protects idempotency.

---

## Phase 4 — Security & Vault Controls

### 4.1 Create the vault file, then encrypt it

```bash
mkdir -p group_vars/production

cat > group_vars/production/vault.yml << 'EOF'
---
vault_db_user: "db_admin"
vault_db_pass: "P@ssw0rd_Exam_2026!"
EOF

ansible-vault encrypt --vault-password-file .vault_pass group_vars/production/vault.yml
```

`--vault-password-file` reads the password from your Phase 1 file, so no prompt appears. Confirm it is actually encrypted:

```bash
head -1 group_vars/production/vault.yml    # expect $ANSIBLE_VAULT;1.1;AES256
```

### 4.2 Config template — `templates/db_app.conf.j2`

```bash
mkdir -p templates

cat > templates/db_app.conf.j2 << 'EOF'
[database]
user={{ vault_db_user }}
password={{ vault_db_pass }}
EOF
```

### 4.3 Playbook — `deploy_db_credentials.yml`

```bash
cat > deploy_db_credentials.yml << 'EOF'
---
- name: Deploy encrypted database credentials
  hosts: production
  become: true

  tasks:
    - name: Deploy database configuration file
      template:
        src: templates/db_app.conf.j2
        dest: /etc/db_app.conf
        owner: root
        group: root
        mode: '0600'
      no_log: true
EOF
```

`no_log: true` is the graded item — it stops the rendered password appearing in the task output.

---

## Phase 5 — Zero-Downtime Rolling Deployment

The two `import_playbook` lines are what make this the **single master execution command** the passing criteria demand.

```bash
cat > site_deploy.yml << 'EOF'
---
- import_playbook: maintenance_check.yml

- import_playbook: deploy_db_credentials.yml

- name: Zero-downtime rolling deployment
  hosts: webservers
  become: true
  serial: 1

  pre_tasks:
    - name: Announce removal from load balancer
      debug:
        msg: "Removing {{ inventory_hostname }} from service load balancer..."

  roles:
    - webapp

  post_tasks:
    - name: Verify web service health
      uri:
        url: "http://localhost:{{ app_port | default(80) }}"
        status_code: 200

    - name: Announce return to load balancer
      debug:
        msg: "Re-adding {{ inventory_hostname }} back to load balancer..."
EOF
```

---

## Step 6 — Run and verify

### 6.1 The single master command

```bash
cd ~/ansible-exam-lab
ansible-playbook -i inventory.ini --vault-password-file .vault_pass site_deploy.yml
```

First run takes a minute (Apache + diagnostics install). Watch for:

- `node1` completing the entire play **before** `node2` starts — that is `serial: 1` working
- The credentials task showing `(censored due to no_log)` instead of the password

### 6.2 Prove idempotency — run it again

```bash
ansible-playbook -i inventory.ini --vault-password-file .vault_pass site_deploy.yml
```

Second run should be almost entirely `ok`, with **one expected `changed`**: the maintenance log append. That task writes a fresh ISO-8601 timestamp every run, so it changes by design — the spec asks for an append. Everything else must be `ok`.

### 6.3 Check each graded item

```bash
ls -l .vault_pass                          # -rw------- (mode 600)
wc -c < .vault_pass                        # 19, no trailing newline
cat .gitignore                             # .vault_pass
head -1 group_vars/production/vault.yml    # $ANSIBLE_VAULT;1.1;AES256
ls -l /etc/db_app.conf                     # -rw------- root root
cat /etc/db_app.conf                       # credentials rendered correctly
curl http://localhost                      # rendered index.html
cat /tmp/maintenance.log                   # timestamped entries
```

Confirm no secrets leaked into the run output:

```bash
ansible-playbook -i inventory.ini --vault-password-file .vault_pass site_deploy.yml | grep -i "P@ssw0rd"
```

**No output = you pass that criterion.**

---

## Step 7 — Copy the project to Windows

Leave the container (`exit`), then in PowerShell from the folder where you want it:

```powershell
docker cp exam:/root/ansible-exam-lab .
```

You now have the full project on Windows for submission, with LF line endings intact.

> `.vault_pass` loses its `600` permission on NTFS — that is a Windows filesystem limitation, not a mistake in your work. The graded permission exists inside the container where you set it.

---

## Step 8 — Clean up

```powershell
docker rm -f exam
```

---

## Requirements checklist

| Phase | Requirement | Where it is satisfied |
| --- | --- | --- |
| 1 | `[webservers]`, `[database]`, `[production:children]` | `inventory.ini` |
| 1 | `.vault_pass`, no trailing newline, mode 600 | `printf` + `chmod 600` |
| 1 | `.gitignore` excludes vault password | `.gitignore` |
| 2 | Role `webapp` scaffolded | `ansible-galaxy role init` |
| 2 | `app_port`, `app_title` defaults | `defaults/main.yml` |
| 2 | Title / hostname / IP / webservers loop | `index.html.j2` |
| 2 | OS-family cache update + correct package | `tasks/main.yml` |
| 2 | Handler ensures service running + enabled | `handlers/main.yml` |
| 3 | `loop` installs curl, htop, unzip | `maintenance_check.yml` |
| 3 | `block` / `rescue` / `always` with `failed_when` | `maintenance_check.yml` |
| 3 | `changed_when: false` on read-only task | `df` task |
| 4 | Encrypted `group_vars/production/vault.yml` | `ansible-vault encrypt` |
| 4 | `/etc/db_app.conf` at mode 0600 | `deploy_db_credentials.yml` |
| 4 | `no_log: true` prevents secret leakage | credentials task |
| 5 | `hosts: webservers` + `serial: 1` | `site_deploy.yml` |
| 5 | `pre_tasks` / `roles` / `post_tasks` | `site_deploy.yml` |
| 5 | `uri` health check expecting 200 | `post_tasks` |
| — | Single master execution command | `ansible-playbook -i inventory.ini --vault-password-file .vault_pass site_deploy.yml` |

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `container ... is not running` | Do not boot systemd. Start with `sleep infinity` exactly as in Step 0. |
| Health check fails after restarting the container | Apache does not auto-start without systemd. Run `service apache2 start`, or re-run the playbook after touching `index.html.j2` so the handler fires. |
| `Attempting to decrypt but no vault secrets found` | You omitted `--vault-password-file .vault_pass` from the command. Every `ansible-playbook` and `ansible-vault` run needs it. |
| `Could not match supplied host pattern` | You omitted `-i inventory.ini`. Without it Ansible falls back to its default inventory, which has no `node1`/`node2`. |
| Warning about discovered Python interpreter | Harmless. Silence it by adding `ansible_python_interpreter=/usr/bin/python3` under `[production:vars]` in `inventory.ini`. |
| Rescue block always fires | Your Docker disk is genuinely over 80% full. Expected behaviour — the play still succeeds. Lower the threshold to test the non-rescue path. |
| YAML error mentioning `\r` | You created a file on Windows with CRLF endings. Create files inside the container as shown. |
| `htop` not found | `apt-get update` first, then re-run. |
