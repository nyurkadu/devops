# install_apache.yml — Execution Log

Installs `apache2` on both nodes and creates `/var/www/html` (the docroot `web_deploy.yml` expects), fixing the failure documented in [web_deploy.md](web_deploy.md).

## Command

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini install_apache.yml
```

## Output

```
PLAY [Install Apache web server] ***********************************************

TASK [Gathering Facts] *********************************************************
ok: [node1]
ok: [node2]

TASK [Install apache2 package] *************************************************
changed: [node1]
changed: [node2]

TASK [Ensure /var/www/html exists (docroot expected by web_deploy.yml)] ********
changed: [node2]
changed: [node1]

PLAY RECAP *********************************************************************
node1                      : ok=3    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node2                      : ok=3    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

## Verification

```bash
docker exec node1 sh -c "apk info -e apache2 && ls -ld /var/www/html"
docker exec node2 sh -c "apk info -e apache2 && ls -ld /var/www/html"
```

Both nodes: `apache2` installed, `/var/www/html` exists (`owner apache:apache`).

## Re-run of web_deploy.yml (confirms fix)

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini web_deploy.yml
```

```
PLAY [Fault-Tolerant Web Deployment with Rollback] *****************************

TASK [Gathering Facts] *********************************************************
ok: [node1]
ok: [node2]

TASK [Create temporary staging directory] **************************************
changed: [node2]
changed: [node1]

TASK [Staging deployment artifact] *********************************************
changed: [node2]
changed: [node1]

TASK [Deploy artifact to application directory] ********************************
changed: [node2]
changed: [node1]

TASK [Confirm successful deployment] *******************************************
ok: [node1] => {
    "msg": "Deployment succeeded without issues!"
}
ok: [node2] => {
    "msg": "Deployment succeeded without issues!"
}

TASK [CLEANUP - Remove temporary staging directory] ****************************
changed: [node1]
changed: [node2]

TASK [Log execution timestamp] *************************************************
ok: [node1] => {
    "msg": "Deployment workflow finished execution at 2026-08-18T09:46:48Z"
}
ok: [node2] => {
    "msg": "Deployment workflow finished execution at 2026-08-18T09:46:48Z"
}

PLAY RECAP *********************************************************************
node1                      : ok=7    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node2                      : ok=7    changed=4    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Deployment now takes the success path on both hosts (`failed=0`, `rescued=0`) — the primary `copy` task lands in `/var/www/html/index.html` since the directory now exists.
