# web_deploy.yml — Execution Log

Run against the existing `inventory.ini` (`[webservers]` group: `node1`, `node2`, both via the `community.docker.docker` connection plugin), using the `ansible-controller` image built earlier.

## Command

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini web_deploy.yml
```

## Output

```
PLAY [Fault-Tolerant Web Deployment with Rollback] *****************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Host 'node2' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
[WARNING]: Host 'node1' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
ok: [node2]
ok: [node1]

TASK [Create temporary staging directory] **************************************
changed: [node1]
changed: [node2]

TASK [Staging deployment artifact] *********************************************
changed: [node1]
changed: [node2]

TASK [Deploy artifact to application directory] ********************************
[ERROR]: Task failed: Module failed: Destination directory /var/www/html does not exist
Origin: /ansible/web_deploy.yml:23:11

21
22         # SIMULATE FAILURE: Intentionally copying to an invalid directory to trigger rescue
23         - name: Deploy artifact to application directory
             ^ column 11

fatal: [node2]: FAILED! => {"changed": false, "msg": "Destination directory /var/www/html does not exist"}
fatal: [node1]: FAILED! => {"changed": false, "msg": "Destination directory /var/www/html does not exist"}

TASK [CRITICAL ERROR - Triggering Automated Rollback] **************************
ok: [node1] => {
    "msg": "Deployment failed! Rolling back to emergency maintenance page..."
}
ok: [node2] => {
    "msg": "Deployment failed! Rolling back to emergency maintenance page..."
}

TASK [Deploy emergency maintenance landing page] *******************************
[ERROR]: Task failed: Module failed: Destination directory /var/www/html does not exist
Origin: /ansible/web_deploy.yml:38:11

36             msg: "Deployment failed! Rolling back to emergency maintenance page..."
37
38         - name: Deploy emergency maintenance landing page
             ^ column 11

fatal: [node2]: FAILED! => {"changed": false, "checksum": "762d70d982997f4d80e61dd8cf6ee28e44845310", "msg": "Destination directory /var/www/html does not exist"}
fatal: [node1]: FAILED! => {"changed": false, "checksum": "762d70d982997f4d80e61dd8cf6ee28e44845310", "msg": "Destination directory /var/www/html does not exist"}

TASK [CLEANUP - Remove temporary staging directory] ****************************
changed: [node2]
changed: [node1]

TASK [Log execution timestamp] *************************************************
[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.
[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, top-level facts will not be auto injected after the change. This feature will be removed from ansible-core version 2.24.
Origin: /ansible/web_deploy.yml:51:18

49         - name: Log execution timestamp
50           debug:
51             msg: "Deployment workflow finished execution at {{ ansible_date_time.iso8601 }}"
                    ^ column 18

Use `ansible_facts["fact_name"]` (no `ansible_` prefix) instead.

ok: [node1] => {
    "msg": "Deployment workflow finished execution at 2026-08-18T09:40:06Z"
}
ok: [node2] => {
    "msg": "Deployment workflow finished execution at 2026-08-18T09:40:06Z"
}

PLAY RECAP *********************************************************************
node1                      : ok=6    changed=3    unreachable=0    failed=1    skipped=0    rescued=1    ignored=0
node2                      : ok=6    changed=3    unreachable=0    failed=1    skipped=0    rescued=1    ignored=0
```

## Re-run after installing Apache (see install_apache.md)

Same command, run again after [install_apache.yml](install_apache.yml) created `/var/www/html`:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini web_deploy.yml
```

```
PLAY [Fault-Tolerant Web Deployment with Rollback] *****************************

TASK [Gathering Facts] *********************************************************
ok: [node2]
ok: [node1]

TASK [Create temporary staging directory] **************************************
changed: [node1]
changed: [node2]

TASK [Staging deployment artifact] *********************************************
changed: [node1]
changed: [node2]

TASK [Deploy artifact to application directory] ********************************
ok: [node2]
ok: [node1]

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
    "msg": "Deployment workflow finished execution at 2026-08-18T09:50:14Z"
}
ok: [node2] => {
    "msg": "Deployment workflow finished execution at 2026-08-18T09:50:14Z"
}

PLAY RECAP *********************************************************************
node1                      : ok=7    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node2                      : ok=7    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Success path confirmed again, and idempotency shows through: "Deploy artifact to application directory" now reports `ok` instead of `changed` on both hosts, since the destination content already matched from the prior run.

## Notes / observed issue

- `block`/`rescue`/`always` structure works as expected mechanically: the primary task fails, `rescue` fires, and `always` runs regardless (recap shows `rescued=1` on both hosts).
- **However**, the rescue fallback itself also failed on both nodes, for the identical reason as the primary task: `app_dir` (`/var/www/html`) does not exist on either container. The primary copy and the rescue copy both target `{{ app_dir }}/index.html`, so once that directory is missing, **both** paths fail the same way — the "emergency maintenance page" never actually gets written, and each host ends the play with `failed=1` even though `rescue` executed.
- Root cause: `node1`/`node2` are minimal `nginx:alpine` containers (see [create_nodes.yml](create_nodes.yml)) which never had `/var/www/html` created — unlike a stock Ubuntu/Apache box where that path pre-exists. This is an environment gap, not a connectivity/inventory problem.
- To make the rollback path actually succeed, either pre-create `{{ app_dir }}` on the nodes (e.g. `docker exec node1 mkdir -p /var/www/html`) or add a `file: path={{ app_dir }} state=directory` task ahead of the block. Not applied here since it wasn't asked for — flagging in case the intent was to see the maintenance page get deployed.
