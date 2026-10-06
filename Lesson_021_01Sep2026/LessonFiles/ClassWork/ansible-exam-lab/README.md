# Multi-Tier Secure Infrastructure — Project Structure

Ansible project built across five phases. Every file below maps to a phase requirement.

Run with a single command:

```bash
ansible-playbook -i inventory.ini --vault-password-file .vault_pass site_deploy.yml
```

---

Built and tested on Windows 11 with Docker Desktop, in an Ubuntu 22.04 container running ansible-core 2.17.

---

## Project tree

```text
ansible-exam-lab/
├── inventory.ini                        Phase 1
├── .vault_pass                          Phase 1
├── .gitignore                           Phase 1
├── maintenance_check.yml                Phase 3
├── deploy_db_credentials.yml            Phase 4
├── site_deploy.yml                      Phase 5
├── group_vars/
│   └── production/
│       └── vault.yml                    Phase 4  (encrypted)
├── templates/
│   └── db_app.conf.j2                   Phase 4
└── roles/
    └── webapp/                          Phase 2
        ├── defaults/main.yml
        ├── handlers/main.yml
        ├── tasks/main.yml
        └── templates/index.html.j2
```
