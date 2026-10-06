# Executed Commands Log

Every command run to build/execute the Ansible setup in this folder, in order.

## 1. Build the Ansible controller image

```bash
docker build -t ansible-controller -f Dockerfile.ansible .
```

## 2. Create node1 / node2 containers (create_nodes.yml)

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini create_nodes.yml
```

## 3. Bootstrap python3 + sudo on the nodes

(`nginx:alpine` ships without these; Ansible needs `python3` on the target, and `become: true` needs `sudo`.)

```bash
docker exec node1 sh -c "apk add --no-cache python3 sudo"
docker exec node2 sh -c "apk add --no-cache python3 sudo"
```

## 4. Run user_managment.yml

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini user_managment.yml
```

Result: `alice` (group `devops`, role `admin`) and `bob` (group `developers`, role `editor`) created on both `node1` and `node2`.

## 5. Re-run user_managment.yml after switching roles to `roles.role1` / `roles.role2` templating

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini user_managment.yml
```

Output:

```
[WARNING]: Found variable using reserved name 'roles'.
Origin: /ansible/user_managment.yml:7:5

5
6   vars:
7     roles:
      ^ column 5


PLAY [User Management with Complex Loops] **************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Host 'node1' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
[WARNING]: Host 'node2' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]
ok: [node2]

TASK [Ensure target user groups exist] *****************************************
ok: [node2] => (item={'name': 'alice', 'group': 'devops', 'role': 'admin'})
ok: [node1] => (item={'name': 'alice', 'group': 'devops', 'role': 'admin'})
ok: [node1] => (item={'name': 'bob', 'group': 'developers', 'role': 'editor'})
ok: [node2] => (item={'name': 'bob', 'group': 'developers', 'role': 'editor'})

TASK [Create developer accounts] ***********************************************
ok: [node2] => (item={'name': 'alice', 'group': 'devops', 'role': 'admin'})
ok: [node1] => (item={'name': 'alice', 'group': 'devops', 'role': 'admin'})
ok: [node2] => (item={'name': 'bob', 'group': 'developers', 'role': 'editor'})
ok: [node1] => (item={'name': 'bob', 'group': 'developers', 'role': 'editor'})

PLAY RECAP *********************************************************************
node1                      : ok=3    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
node2                      : ok=3    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Everything reports `ok` (not `changed`) since alice/bob already existed on both nodes from the prior run — the `role` value now resolves correctly to `admin`/`editor` via `{{ roles.role1 }}` / `{{ roles.role2 }}` templating.
