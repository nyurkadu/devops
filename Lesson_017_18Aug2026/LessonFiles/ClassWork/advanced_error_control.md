# advanced_error_control.yml — Execution Log

Run against the existing `inventory.ini` (`[webservers]` group: `node1`, `node2`, both via the `community.docker.docker` connection plugin), using the `ansible-controller` image built earlier.

## Command

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)":/ansible \
  ansible-controller -i inventory.ini advanced_error_control.yml
```

## Output

```
PLAY [Demonstrate Advanced Error Control] **************************************

TASK [Gathering Facts] *********************************************************
[WARNING]: Host 'node1' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
[WARNING]: Host 'node2' is using the discovered Python interpreter at '/usr/bin/python3.14', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
ok: [node1]
ok: [node2]

TASK [Ping an external host (Allowed to fail)] *********************************
[ERROR]: Task failed: Module failed: The command exited with a non-zero return code.
Origin: /ansible/advanced_error_control.yml:6:7

4
5     # 1. Ignore errors for non-critical health checks
6     - name: Ping an external host (Allowed to fail)
        ^ column 7

fatal: [node1]: FAILED! => {"changed": true, "cmd": ["ping", "-c", "2", "10.255.255.1"], "delta": "0:00:11.008479", "end": "2026-08-18 08:47:24.188670", "msg": "The command exited with a non-zero return code.", "rc": 1, "start": "2026-08-18 08:47:13.180191", "stderr": "", "stderr_lines": [], "stdout": "PING 10.255.255.1 (10.255.255.1): 56 data bytes\n\n--- 10.255.255.1 ping statistics ---\n2 packets transmitted, 0 packets received, 100% packet loss", "stdout_lines": ["PING 10.255.255.1 (10.255.255.1): 56 data bytes", "", "--- 10.255.255.1 ping statistics ---", "2 packets transmitted, 0 packets received, 100% packet loss"]}
...ignoring
fatal: [node2]: FAILED! => {"changed": true, "cmd": ["ping", "-c", "2", "10.255.255.1"], "delta": "0:00:11.011721", "end": "2026-08-18 08:47:24.187275", "msg": "The command exited with a non-zero return code.", "rc": 1, "start": "2026-08-18 08:47:13.175554", "stderr": "", "stderr_lines": [], "stdout": "PING 10.255.255.1 (10.255.255.1): 56 data bytes\n\n--- 10.255.255.1 ping statistics ---\n2 packets transmitted, 0 packets received, 100% packet loss", "stdout_lines": ["PING 10.255.255.1 (10.255.255.1): 56 data bytes", "", "--- 10.255.255.1 ping statistics ---", "2 packets transmitted, 0 packets received, 100% packet loss"]}
...ignoring

TASK [Check system uptime] *****************************************************
ok: [node1]
ok: [node2]

TASK [Check available disk space on root partition] ****************************
ok: [node1]
ok: [node2]

TASK [Display disk check result] ***********************************************
ok: [node1] => {
    "msg": "Root disk usage is currently at 3%"
}
ok: [node2] => {
    "msg": "Root disk usage is currently at 3%"
}

PLAY RECAP *********************************************************************
node1                      : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=1
node2                      : ok=5    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=1
```

## Notes

- **Task 1 (ping)**: fails as expected (`10.255.255.1` is unreachable, 100% packet loss) but `ignore_errors: true` lets the play continue — recorded as `ignored=1` in the recap rather than `failed`.
- **Task 2 (uptime)**: `changed_when: false` correctly keeps this read-only check out of the "changed" count.
- **Task 3 (disk check)**: `df -h / | awk 'NR==2 {print $5}' | sed 's/%//'` returned `3` on both nodes; `failed_when: disk_usage.stdout | int > 90` did not trigger since usage is well under the 90% threshold.
- **Task 4 (debug)**: confirms the parsed value — "Root disk usage is currently at 3%" on both `node1` and `node2`.
