# Test Results

```bash
ls -la .vault_pass | grep -- "-rw-------"
```

Output:

```text
-rw------- 1 root root 19 Sep  1 07:27 .vault_pass
exit=0
```

```bash
ansible-vault view group_vars/production/vault.yml --vault-password-file .vault_pass
```

```text
---
vault_db_user: "db_admin"
vault_db_pass: "********"
exit=0
```

```bash
head -1 group_vars/production/vault.yml
```

```text
$ANSIBLE_VAULT;1.1;AES256
```

```bash
ansible-playbook -i inventory.ini maintenance_check.yml --vault-password-file .vault_pass
```

Output:

```text

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node1 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]

TASK [Update package cache (Debian)] *******************************************
ok: [node1]

TASK [Install system diagnostic utilities] *************************************
ok: [node1] => (item=curl)
ok: [node1] => (item=htop)
ok: [node1] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node1]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node1]

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node2 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node2]

TASK [Update package cache (Debian)] *******************************************
ok: [node2]

TASK [Install system diagnostic utilities] *************************************
ok: [node2] => (item=curl)
ok: [node2] => (item=htop)
ok: [node2] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node2]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node2]

PLAY RECAP *********************************************************************
node1                      : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   
node2                      : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0   

exit=0
```





```bash
ansible-playbook -i inventory.ini site_deploy.yml --vault-password-file .vault_pass
```

Output:

```text

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node1 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]

TASK [Update package cache (Debian)] *******************************************
ok: [node1]

TASK [Install system diagnostic utilities] *************************************
ok: [node1] => (item=curl)
ok: [node1] => (item=htop)
ok: [node1] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node1]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node1]

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node2 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node2]

TASK [Update package cache (Debian)] *******************************************
ok: [node2]

TASK [Install system diagnostic utilities] *************************************
ok: [node2] => (item=curl)
ok: [node2] => (item=htop)
ok: [node2] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node2]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node2]

PLAY [Deploy encrypted database credentials] ***********************************

TASK [Gathering Facts] *********************************************************
ok: [node1]
ok: [node2]

TASK [Deploy database configuration file] **************************************
ok: [node2]
ok: [node1]

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node1]

TASK [Announce removal from load balancer] *************************************
ok: [node1] => {
    "msg": "Removing node1 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node1]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node1]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node1]

TASK [webapp : Install web server package] *************************************
ok: [node1]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node1]

TASK [Verify web service health] ***********************************************
ok: [node1]

TASK [Announce return to load balancer] ****************************************
ok: [node1] => {
    "msg": "Re-adding node1 back to load balancer..."
}

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node2]

TASK [Announce removal from load balancer] *************************************
ok: [node2] => {
    "msg": "Removing node2 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node2]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node2]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node2]

TASK [webapp : Install web server package] *************************************
ok: [node2]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node2]

TASK [Verify web service health] ***********************************************
ok: [node2]

TASK [Announce return to load balancer] ****************************************
ok: [node2] => {
    "msg": "Re-adding node2 back to load balancer..."
}

PLAY RECAP *********************************************************************
node1                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   
node2                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   

exit=0
```

```bash
ansible-playbook -i inventory.ini site_deploy.yml --vault-password-file .vault_pass
```

Output:

```text

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node1 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]

TASK [Update package cache (Debian)] *******************************************
ok: [node1]

TASK [Install system diagnostic utilities] *************************************
ok: [node1] => (item=curl)
ok: [node1] => (item=htop)
ok: [node1] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node1]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node1]

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node2 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node2]

TASK [Update package cache (Debian)] *******************************************
ok: [node2]

TASK [Install system diagnostic utilities] *************************************
ok: [node2] => (item=curl)
ok: [node2] => (item=htop)
ok: [node2] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node2]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node2]

PLAY [Deploy encrypted database credentials] ***********************************

TASK [Gathering Facts] *********************************************************
ok: [node1]
ok: [node2]

TASK [Deploy database configuration file] **************************************
ok: [node1]
ok: [node2]

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node1]

TASK [Announce removal from load balancer] *************************************
ok: [node1] => {
    "msg": "Removing node1 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node1]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node1]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node1]

TASK [webapp : Install web server package] *************************************
ok: [node1]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node1]

TASK [Verify web service health] ***********************************************
ok: [node1]

TASK [Announce return to load balancer] ****************************************
ok: [node1] => {
    "msg": "Re-adding node1 back to load balancer..."
}

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node2]

TASK [Announce removal from load balancer] *************************************
ok: [node2] => {
    "msg": "Removing node2 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node2]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node2]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node2]

TASK [webapp : Install web server package] *************************************
ok: [node2]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node2]

TASK [Verify web service health] ***********************************************
ok: [node2]

TASK [Announce return to load balancer] ****************************************
ok: [node2] => {
    "msg": "Re-adding node2 back to load balancer..."
}

PLAY RECAP *********************************************************************
node1                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   
node2                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   

exit=0
```

```bash
ansible-playbook -i inventory.ini site_deploy.yml --vault-password-file .vault_pass
```

Output:

```text

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node1 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]

TASK [Update package cache (Debian)] *******************************************
ok: [node1]

TASK [Install system diagnostic utilities] *************************************
ok: [node1] => (item=curl)
ok: [node1] => (item=htop)
ok: [node1] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node1]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node1]

PLAY [Pre-flight system maintenance checks] ************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Platform linux on host node2 is using the discovered Python
interpreter at /usr/bin/python3.10, but future installation of another Python
interpreter could change the meaning of that path. See
https://docs.ansible.com/ansible-
core/2.17/reference_appendices/interpreter_discovery.html for more information.
ok: [node2]

TASK [Update package cache (Debian)] *******************************************
ok: [node2]

TASK [Install system diagnostic utilities] *************************************
ok: [node2] => (item=curl)
ok: [node2] => (item=htop)
ok: [node2] => (item=unzip)

TASK [Check available disk space on root filesystem] ***************************
ok: [node2]

TASK [Append execution timestamp to maintenance log] ***************************
changed: [node2]

PLAY [Deploy encrypted database credentials] ***********************************

TASK [Gathering Facts] *********************************************************
ok: [node1]
ok: [node2]

TASK [Deploy database configuration file] **************************************
ok: [node2]
ok: [node1]

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node1]

TASK [Announce removal from load balancer] *************************************
ok: [node1] => {
    "msg": "Removing node1 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node1]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node1]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node1]

TASK [webapp : Install web server package] *************************************
ok: [node1]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node1]

TASK [Verify web service health] ***********************************************
ok: [node1]

TASK [Announce return to load balancer] ****************************************
ok: [node1] => {
    "msg": "Re-adding node1 back to load balancer..."
}

PLAY [Zero-downtime rolling deployment] ****************************************

TASK [Gathering Facts] *********************************************************
ok: [node2]

TASK [Announce removal from load balancer] *************************************
ok: [node2] => {
    "msg": "Removing node2 from service load balancer..."
}

TASK [webapp : Set OS-specific web server package name] ************************
ok: [node2]

TASK [webapp : Update package cache (Debian)] **********************************
ok: [node2]

TASK [webapp : Update package cache (RedHat)] **********************************
skipping: [node2]

TASK [webapp : Install web server package] *************************************
ok: [node2]

TASK [webapp : Deploy index.html from template] ********************************
ok: [node2]

TASK [Verify web service health] ***********************************************
ok: [node2]

TASK [Announce return to load balancer] ****************************************
ok: [node2] => {
    "msg": "Re-adding node2 back to load balancer..."
}

PLAY RECAP *********************************************************************
node1                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   
node2                      : ok=15   changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0   

exit=0
```
