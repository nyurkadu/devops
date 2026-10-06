# Ansible: Loops, Conditions, Ternary, Error Handling

Теоретическая часть к уроку 017 (18.08.2026).

---

## Оглавление

1. [Loops / Iterations](#1-loops--iterations)
2. [Условия (when)](#2-условия-when)
3. [Ternary operator](#3-ternary-operator)
4. [Error Handling](#4-error-handling--обработка-ошибок)
5. [Сводная таблица](#5-сводная-таблица)
6. [Сценарии бизнес-логики](#6-сценарии-обработки-ошибок-на-уровне-бизнес-логики)

---

## 1. Loops / Iterations

Цикл позволяет выполнить **одну задачу много раз** с разными данными.
Ansible на каждой итерации подставляет текущий элемент в переменную `item`.

### 1.1 `loop` + список (list)

Самый простой и самый частый случай.

```yaml
- name: Install packages
  ansible.builtin.package:
    name: "{{ item }}"
    state: present
  loop:
    - nginx
    - git
    - curl
```

Ansible выполнит модуль `package` три раза: `item = nginx`, потом `git`, потом `curl`.

> `loop` — современный синтаксис (Ansible 2.5+). Старый `with_items` работает,
> но в новом коде использовать не рекомендуется.

### 1.2 Цикл по переменной

Список удобно держать в `vars`, а не хардкодить в задаче:

```yaml
- hosts: all
  vars:
    packages:
      - nginx
      - git
      - curl
  tasks:
    - name: Install packages
      ansible.builtin.package:
        name: "{{ item }}"
        state: present
      loop: "{{ packages }}"
```

### 1.3 Список словарей (list of dictionaries)

Когда на каждой итерации нужно **несколько полей** — элементы списка делают словарями,
а обращаются через `item.<ключ>`.

```yaml
- name: Create users
  ansible.builtin.user:
    name:   "{{ item.name }}"
    groups: "{{ item.groups }}"
    shell:  "{{ item.shell }}"
    state:  present
  loop:
    - { name: 'alice', groups: 'sudo',   shell: '/bin/bash' }
    - { name: 'bob',   groups: 'docker', shell: '/bin/sh'   }
```

То же самое в более читаемой (блочной) записи YAML:

```yaml
  loop:
    - name: alice
      groups: sudo
      shell: /bin/bash
    - name: bob
      groups: docker
      shell: /bin/sh
```

### 1.4 Цикл по словарю: `dict2items`

По словарю напрямую итерироваться нельзя — его сначала превращают в список пар
`{key, value}` фильтром `dict2items`.

```yaml
- hosts: all
  vars:
    limits:
      nofile: 65536
      nproc:  4096
  tasks:
    - name: Show limits
      ansible.builtin.debug:
        msg: "{{ item.key }} = {{ item.value }}"
      loop: "{{ limits | dict2items }}"
```

Вывод:

```
nofile = 65536
nproc = 4096
```

Обратный фильтр — `items2dict` (список пар → словарь).

### 1.5 Вложенные словари

```yaml
vars:
  users:
    alice:
      uid: 1001
      shell: /bin/bash
    bob:
      uid: 1002
      shell: /bin/sh

tasks:
  - name: Create users from dict
    ansible.builtin.user:
      name:  "{{ item.key }}"
      uid:   "{{ item.value.uid }}"
      shell: "{{ item.value.shell }}"
    loop: "{{ users | dict2items }}"
```

### 1.6 Complex loops — комбинации списков

**`product`** — декартово произведение (все комбинации):

```yaml
- name: Every user in every group
  ansible.builtin.debug:
    msg: "{{ item.0 }} -> {{ item.1 }}"
  loop: "{{ ['alice', 'bob'] | product(['sudo', 'docker']) | list }}"
# alice->sudo, alice->docker, bob->sudo, bob->docker
```

**`zip`** — попарное соединение двух списков:

```yaml
- ansible.builtin.debug:
    msg: "{{ item.0 }}:{{ item.1 }}"
  loop: "{{ ['web', 'db'] | zip([80, 5432]) | list }}"
# web:80, db:5432
```

**`subelements`** — родитель + его вложенный список:

```yaml
vars:
  users:
    - name: alice
      keys: [key1, key2]
    - name: bob
      keys: [key3]

tasks:
  - name: Add SSH keys
    ansible.builtin.debug:
      msg: "{{ item.0.name }} has {{ item.1 }}"
    loop: "{{ users | subelements('keys') }}"
# alice has key1 / alice has key2 / bob has key3
```

**`flatten`** — «расплющить» вложенные списки в один уровень:

```yaml
loop: "{{ [[1, 2], [3, [4]]] | flatten }}"   # 1, 2, 3, 4
```

### 1.7 `loop_control` — управление циклом

```yaml
- name: Create users
  ansible.builtin.user:
    name: "{{ user.name }}"
  loop: "{{ users }}"
  loop_control:
    loop_var: user             # переименовать item -> user (нужно во вложенных include)
    label: "{{ user.name }}"   # что печатать в выводе (короче, без секретов)
    index_var: idx             # номер итерации, начиная с 0
    pause: 2                   # пауза между итерациями, секунд
```

`label` особенно полезен, когда в `item` большой словарь или пароль — в лог
попадёт только метка.

### 1.8 Цикл + `register`

Результат цикла сохраняется как `<var>.results` — список результатов каждой итерации.

```yaml
- name: Ping hosts
  ansible.builtin.command: "ping -c1 {{ item }}"
  loop: ['8.8.8.8', '1.1.1.1']
  register: ping_out
  ignore_errors: true

- name: Show failed pings
  ansible.builtin.debug:
    msg: "{{ item.item }} failed"
  loop: "{{ ping_out.results }}"
  when: item.failed
```

Внутри `results` каждый элемент содержит `item` (исходное значение), `rc`,
`stdout`, `failed`, `changed` и т. д.

### 1.9 `until` — цикл-повтор (retry)

Не «для каждого элемента», а «повторять, пока не выполнится условие»:

```yaml
- name: Wait for service to be up
  ansible.builtin.uri:
    url: http://localhost:8080/health
  register: result
  until: result.status == 200
  retries: 10
  delay: 5          # секунд между попытками
```

---

## 2. Условия (`when`)

`when` определяет, **выполнять ли задачу** на конкретном хосте/итерации.
Значение — Jinja2-выражение **без** `{{ }}`.

### 2.1 Операторы сравнения

```yaml
- name: Run only on Ubuntu
  ansible.builtin.debug: msg="Ubuntu here"
  when: ansible_facts['distribution'] == "Ubuntu"

- name: Run on anything except CentOS
  ansible.builtin.debug: msg="not CentOS"
  when: ansible_facts['distribution'] != "CentOS"

- name: Only for new kernels
  ansible.builtin.debug: msg="modern"
  when: ansible_facts['kernel'] is version('5.0', '>=')
```

Доступны: `==`, `!=`, `>`, `<`, `>=`, `<=`.

> Важно: `"7" == 7` → **false**. Для чисел из фактов приводите тип:
> `ansible_facts['distribution_major_version'] | int >= 8`.

### 2.2 `in` / `not in`

```yaml
# элемент в списке
- name: For Debian family
  ansible.builtin.debug: msg="deb-based"
  when: ansible_facts['distribution'] in ['Ubuntu', 'Debian']

# исключение
- name: Skip test servers
  ansible.builtin.debug: msg="prod work"
  when: inventory_hostname not in groups['test']

# подстрока в строке
- name: Hostname contains 'web'
  ansible.builtin.debug: msg="web node"
  when: "'web' in inventory_hostname"
```

### 2.3 Логика: `and`, `or`, `not`, список условий

```yaml
- name: Ubuntu 22.04 only
  ansible.builtin.debug: msg="jammy"
  when:
    - ansible_facts['distribution'] == "Ubuntu"
    - ansible_facts['distribution_version'] == "22.04"
```

Список под `when` = неявное **AND** (все условия должны быть истинны).
Для `OR` пишите одной строкой:

```yaml
  when: ansible_facts['distribution'] == "Ubuntu" or ansible_facts['distribution'] == "Debian"
```

Скобки для смешанной логики:

```yaml
  when: (ansible_facts['os_family'] == "RedHat" and ansible_facts['distribution_major_version'] | int >= 8)
        or ansible_facts['distribution'] == "Fedora"
```

### 2.4 Тесты: `defined`, `undefined`, `is`

```yaml
- name: Only if variable exists
  ansible.builtin.debug: msg="{{ app_port }}"
  when: app_port is defined

- name: Only if variable is missing
  ansible.builtin.set_fact:
    app_port: 8080
  when: app_port is undefined

- name: Only if variable is not empty
  ansible.builtin.debug: msg="ok"
  when: app_port is defined and app_port | length > 0
```

Полезные тесты: `defined`, `undefined`, `none`, `truthy`, `falsy`,
`version(...)`, `match(...)`, `search(...)`, `changed`, `failed`, `succeeded`, `skipped`.

### 2.5 `when` + `register`

```yaml
- name: Check if nginx installed
  ansible.builtin.command: which nginx
  register: nginx_check
  ignore_errors: true
  changed_when: false

- name: Install nginx if missing
  ansible.builtin.package:
    name: nginx
    state: present
  when: nginx_check.rc != 0
```

Через тесты состояния читается лучше:

```yaml
  when: nginx_check is failed
  # или: when: nginx_check is succeeded / is changed / is skipped
```

### 2.6 `when` + `loop`

`when` проверяется **на каждой итерации**, а не один раз на всю задачу:

```yaml
- name: Install only enabled packages
  ansible.builtin.debug:
    msg: "install {{ item.name }}"
  loop:
    - { name: nginx,  enabled: true  }
    - { name: apache, enabled: false }
  when: item.enabled
```

### 2.7 Проверки по `ansible_facts` / ОС

Основные факты для ветвления по ОС:

| Факт | Пример значения |
|---|---|
| `ansible_facts['os_family']` | `Debian`, `RedHat`, `Suse`, `Windows` |
| `ansible_facts['distribution']` | `Ubuntu`, `CentOS`, `Rocky`, `Debian` |
| `ansible_facts['distribution_version']` | `22.04`, `9.3` |
| `ansible_facts['distribution_major_version']` | `22`, `9` |
| `ansible_facts['kernel']` | `5.15.0-91-generic` |
| `ansible_facts['architecture']` | `x86_64`, `aarch64` |
| `ansible_facts['pkg_mgr']` | `apt`, `dnf`, `yum` |
| `ansible_facts['service_mgr']` | `systemd` |
| `ansible_facts['memtotal_mb']` | `7950` |
| `ansible_facts['processor_vcpus']` | `4` |

Классический пример — разные имена пакетов в разных семействах ОС:

```yaml
- name: Install Apache (Debian family)
  ansible.builtin.apt:
    name: apache2
    state: present
  when: ansible_facts['os_family'] == "Debian"

- name: Install Apache (RedHat family)
  ansible.builtin.dnf:
    name: httpd
    state: present
  when: ansible_facts['os_family'] == "RedHat"
```

Проверка ресурсов:

```yaml
- name: Fail on small hosts
  ansible.builtin.fail:
    msg: "Need at least 2GB RAM, host has {{ ansible_facts['memtotal_mb'] }}MB"
  when: ansible_facts['memtotal_mb'] < 2048
```

Посмотреть все факты хоста:

```bash
ansible <host> -m ansible.builtin.setup
ansible <host> -m ansible.builtin.setup -a "filter=ansible_distribution*"
```

> Если факты не нужны — отключайте сбор (`gather_facts: false`), это заметно
> ускоряет плейбук. Но тогда `ansible_facts` будут пустыми.

---

## 3. Ternary operator

`ternary` — тернарный оператор Jinja2: короткая замена `if/else` **внутри значения**.

```
условие | ternary(значение_если_true, значение_если_false)
```

Это фильтр, поэтому он живёт внутри `{{ }}`, в отличие от `when`.

### 3.1 Базовый пример

```yaml
- name: Start or stop service
  ansible.builtin.service:
    name: nginx
    state: "{{ (env == 'prod') | ternary('started', 'stopped') }}"
```

Эквивалент на `when` потребовал бы двух задач — `ternary` умещает выбор в одну.

### 3.2 Выбор имени пакета по ОС

```yaml
- name: Install web server
  ansible.builtin.package:
    name: "{{ (ansible_facts['os_family'] == 'Debian') | ternary('apache2', 'httpd') }}"
    state: present
```

### 3.3 Третий аргумент — для `None` / undefined

`ternary` принимает **третье** значение, которое возвращается, если условие — `None`
(а не просто false):

```yaml
{{ my_var | ternary('yes', 'no', 'unknown') }}
# true  -> yes
# false -> no
# None  -> unknown
```

Чтобы безопасно обработать несуществующую переменную, комбинируйте с `default`:

```yaml
{{ (feature_enabled | default(false)) | ternary('on', 'off') }}
```

### 3.4 Значения любого типа

Возвращать можно не только строки — числа, списки, словари:

```yaml
- name: Set workers count
  ansible.builtin.set_fact:
    workers: "{{ (env == 'prod') | ternary(16, 2) }}"

- name: Choose package set
  ansible.builtin.package:
    name: "{{ (env == 'prod') | ternary(prod_packages, dev_packages) }}"
```

### 3.5 Вложенный ternary

Технически возможно, но читаемость падает:

```yaml
{{ (env == 'prod') | ternary('16', (env == 'stage') | ternary('8', '2')) }}
```

Для трёх и более веток лучше словарь-мапа:

```yaml
vars:
  workers_map:
    prod: 16
    stage: 8
    dev: 2
tasks:
  - ansible.builtin.set_fact:
      workers: "{{ workers_map[env] | default(2) }}"
```

---

## 4. Error Handling / обработка ошибок

По умолчанию Ansible при ошибке задачи **останавливает выполнение плейбука на этом хосте**
(остальные хосты продолжают работать). Инструменты ниже позволяют изменить это поведение.

### 4.1 `ignore_errors`

«Задача упала — не страшно, идём дальше».

```yaml
- name: Try to stop legacy service
  ansible.builtin.service:
    name: legacy-app
    state: stopped
  ignore_errors: true

- name: This runs even if the previous task failed
  ansible.builtin.debug:
    msg: "continue"
```

Особенности:

- Задача **всё равно помечается как FAILED** в выводе (красным), но плейбук идёт дальше.
- Результат можно поймать через `register` и проанализировать:

```yaml
- name: Check config
  ansible.builtin.command: nginx -t
  register: nginx_test
  ignore_errors: true

- name: Report broken config
  ansible.builtin.debug:
    msg: "Config is broken: {{ nginx_test.stderr }}"
  when: nginx_test is failed
```

- `ignore_errors` **не ловит недоступность хоста** (unreachable). Для этого — `ignore_unreachable: true`.
- Можно задать условно: `ignore_errors: "{{ env != 'prod' }}"`.

> Антипаттерн: вешать `ignore_errors: true` на всё подряд, чтобы «плейбук был зелёным».
> Ошибку нужно либо осознанно игнорировать, либо переопределить через `failed_when`.

### 4.2 `failed_when`

«Я сам решаю, что считать ошибкой».

Ansible по умолчанию считает провалом ненулевой `rc`. `failed_when` заменяет
это правило вашим условием.

**Пример 1: команда падает, но для нас это норма**

```yaml
- name: Check if user exists
  ansible.builtin.command: id deploy
  register: user_check
  failed_when: false        # никогда не считать ошибкой
  changed_when: false
```

**Пример 2: команда возвращает rc=0, но по факту это ошибка**

```yaml
- name: Deploy application
  ansible.builtin.command: /opt/deploy.sh
  register: deploy_out
  failed_when: "'ERROR' in deploy_out.stdout"
```

**Пример 3: несколько допустимых кодов возврата**

```yaml
- name: Run migration
  ansible.builtin.command: /opt/migrate.sh
  register: migrate
  failed_when: migrate.rc not in [0, 2]   # 2 = "нечего мигрировать"
```

**Пример 4: список условий = OR**

Внимание, здесь логика **противоположна** `when`: список под `failed_when` — это **OR**
(упало, если сработало хотя бы одно условие).

```yaml
- ansible.builtin.command: /opt/check.sh
  register: r
  failed_when:
    - r.rc != 0
    - "'WARNING' in r.stdout"
```

> Чтобы не путаться, сложные условия пишите одной строкой явно:
> `failed_when: r.rc != 0 or 'WARNING' in r.stdout`

**Явное падение: `fail` и `assert`**

```yaml
- name: Fail with a custom message
  ansible.builtin.fail:
    msg: "Disk usage {{ disk_pct }}% exceeds 90%"
  when: disk_pct | int > 90

- name: Assert preconditions
  ansible.builtin.assert:
    that:
      - app_version is defined
      - ansible_facts['memtotal_mb'] >= 2048
    fail_msg: "Preconditions not met"
    success_msg: "All good"
```

### 4.3 `changed_when`

«Я сам решаю, что считать изменением».

Влияет на статус `changed` (жёлтый) и, что важнее, — на **запуск handlers**.

**Пример 1: read-only команда никогда ничего не меняет**

```yaml
- name: Get service status
  ansible.builtin.command: systemctl is-active nginx
  register: status
  changed_when: false      # чистый вывод, идемпотентность
  failed_when: false
```

Это самый частый случай: модуль `command`/`shell` **всегда** рапортует `changed`,
потому что не знает семантики команды. `changed_when: false` убирает ложный шум.

**Пример 2: changed только при реальном изменении**

```yaml
- name: Create database
  ansible.builtin.command: /opt/create_db.sh
  register: db_out
  changed_when: "'Database created' in db_out.stdout"
  # если скрипт напечатал 'Already exists' -> ok, а не changed
```

**Пример 3: по коду возврата**

```yaml
- name: Apply config
  ansible.builtin.command: /opt/apply.sh
  register: apply_out
  changed_when: apply_out.rc == 1     # 1 = "были изменения"
  failed_when: apply_out.rc > 1
```

**Пример 4: связка с handler**

```yaml
tasks:
  - name: Render config
    ansible.builtin.command: /opt/render_config.sh
    register: render
    changed_when: "'updated' in render.stdout"
    notify: Restart nginx

handlers:
  - name: Restart nginx
    ansible.builtin.service:
      name: nginx
      state: restarted
```

Handler сработает **только** если `changed_when` дал `true` — nginx не будет
перезапускаться на каждом прогоне.

### 4.4 `block` / `rescue` / `always`

Групповая обработка ошибок, аналог `try / catch / finally`.

| Ansible | Языки программирования |
|---|---|
| `block`  | `try` — основные задачи |
| `rescue` | `catch` — что делать, если внутри `block` произошла ошибка |
| `always` | `finally` — выполняется всегда, независимо от результата |

```yaml
- name: Deploy with rollback
  block:
    - name: Backup current release
      ansible.builtin.command: /opt/backup.sh

    - name: Deploy new version
      ansible.builtin.command: "/opt/deploy.sh {{ app_version }}"

    - name: Smoke test
      ansible.builtin.uri:
        url: http://localhost:8080/health
        status_code: 200

  rescue:
    - name: Show what happened
      ansible.builtin.debug:
        msg: "Deploy failed on task: {{ ansible_failed_task.name }}"

    - name: Rollback
      ansible.builtin.command: /opt/rollback.sh

    - name: Notify team
      ansible.builtin.debug:
        msg: "Rolled back, error: {{ ansible_failed_result.msg | default('n/a') }}"

  always:
    - name: Cleanup temp files
      ansible.builtin.file:
        path: /tmp/deploy
        state: absent
```

Ключевые правила:

1. `rescue` выполняется, **только если** упала задача внутри `block`.
2. Если `rescue` отработал без ошибок, плейбук считается **успешным** и продолжается —
   ошибка «поглощена».
3. `always` выполняется в любом случае: и при успехе, и при провале, и даже если
   `rescue` тоже упал.
4. Внутри `rescue` доступны специальные переменные:
   - `ansible_failed_task` — словарь упавшей задачи (`.name`, `.action`)
   - `ansible_failed_result` — её результат (`.msg`, `.rc`, `.stdout`, `.stderr`)
5. `block` умеет наследовать директивы для всех вложенных задач:

```yaml
- block:
    - ansible.builtin.command: whoami
    - ansible.builtin.command: hostname
  become: true
  when: ansible_facts['os_family'] == "Debian"
  tags: [system]
```

`become`, `when`, `tags`, `vars`, `ignore_errors` применятся ко **всем** задачам блока.

6. Блоки можно вкладывать друг в друга.
7. Если нужно, чтобы после `rescue` плейбук всё равно упал — явно вызовите `fail`:

```yaml
  rescue:
    - ansible.builtin.command: /opt/rollback.sh
    - ansible.builtin.fail:
        msg: "Deploy failed, rollback done"
```

---

## 5. Сводная таблица

| Инструмент | Что делает | Когда применять |
|---|---|---|
| `loop` | повторяет задачу для каждого элемента | несколько пакетов / юзеров / файлов |
| `loop_control` | `loop_var`, `label`, `index_var`, `pause` | вложенные циклы, чистый вывод |
| `until` / `retries` / `delay` | повторяет до выполнения условия | ожидание сервиса, флапающая сеть |
| `when` | выполнять задачу или нет | ветвление по ОС, переменным, результату |
| `ternary` | выбор значения внутри выражения | одно значение, две ветки |
| `ignore_errors` | ошибка не останавливает плейбук | необязательный шаг, best-effort |
| `failed_when` | переопределяет, что есть ошибка | нестандартные rc, ошибки в stdout |
| `changed_when` | переопределяет, что есть изменение | `command`/`shell`, контроль handlers |
| `block`/`rescue`/`always` | try / catch / finally | транзакция: деплой + откат + cleanup |
| `fail` / `assert` | принудительная ошибка / проверка | валидация входных данных |
| `any_errors_fatal` | ошибка на одном хосте валит весь play | кластерные операции |
| `max_fail_percentage` | допустимый % упавших хостов | rolling update |

---

## 6. Сценарии обработки ошибок на уровне бизнес-логики

Логика принятия решения:

```
произошла ситуация
        ↓
решаем, критична она или нет
        ↓
Ansible реагирует нужным способом
```

| Ситуация | Критична? | Реакция | Инструмент |
|---|---|---|---|
| Не удалось отправить уведомление в Slack | нет | залогировать и идти дальше | `ignore_errors` |
| Скрипт вернул rc=2 «нечего делать» | нет | считать успехом | `failed_when: rc not in [0,2]` |
| `grep` не нашёл строку (rc=1) | нет | это просто «не найдено» | `failed_when: false` |
| Проверка статуса сервиса | нет | не помечать как changed | `changed_when: false` |
| Скрипт напечатал `ERROR`, но rc=0 | **да** | пометить как ошибку | `failed_when: "'ERROR' in stdout"` |
| Диск заполнен >90% | **да** | остановить плейбук с понятным текстом | `fail` + `when` |
| Не заданы обязательные переменные | **да** | упасть до начала работ | `assert` |
| Деплой сломался | **да** | откатиться и почистить | `block`/`rescue`/`always` |
| Сервис ещё не поднялся | нет | подождать и повторить | `until` + `retries` |

### Пример 1: некритичный шаг (уведомление)

```yaml
- name: Notify monitoring (best effort)
  ansible.builtin.uri:
    url: "https://monitoring.local/api/deploy"
    method: POST
    timeout: 5
  register: notify_result
  ignore_errors: true

- name: Log notification failure
  ansible.builtin.debug:
    msg: "Monitoring is down, continuing anyway"
  when: notify_result is failed
```

### Пример 2: кастомная ошибка по содержимому вывода

```yaml
- name: Run application health check
  ansible.builtin.command: /opt/app/healthcheck.sh
  register: health
  changed_when: false
  failed_when: >
    health.rc != 0 or
    'DEGRADED' in health.stdout or
    'ERROR' in health.stderr
```

### Пример 3: корректный `changed` + handler

```yaml
tasks:
  - name: Sync application config
    ansible.builtin.command: /opt/app/sync-config.sh
    register: sync
    changed_when: "'config updated' in sync.stdout"
    failed_when: sync.rc != 0
    notify: Reload application

handlers:
  - name: Reload application
    ansible.builtin.service:
      name: myapp
      state: reloaded
```

### Пример 4: транзакционный деплой

```yaml
- name: Transactional deploy
  block:
    - name: Stop application
      ansible.builtin.service: { name: myapp, state: stopped }

    - name: Backup
      ansible.builtin.command: /opt/backup.sh
      register: backup
      changed_when: backup.rc == 0

    - name: Deploy
      ansible.builtin.command: "/opt/deploy.sh {{ app_version }}"

    - name: Start application
      ansible.builtin.service: { name: myapp, state: started }

    - name: Health check
      ansible.builtin.uri:
        url: http://localhost:8080/health
        status_code: 200
      register: hc
      until: hc.status == 200
      retries: 6
      delay: 5

  rescue:
    - name: Rollback to previous version
      ansible.builtin.command: /opt/rollback.sh

    - name: Ensure app is running after rollback
      ansible.builtin.service: { name: myapp, state: started }

    - name: Fail the play explicitly
      ansible.builtin.fail:
        msg: "Deploy of {{ app_version }} failed at '{{ ansible_failed_task.name }}', rolled back"

  always:
    - name: Remove lock file
      ansible.builtin.file:
        path: /var/run/deploy.lock
        state: absent
```

---

## Полезные ссылки

- [Loops](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_loops.html)
- [Conditionals](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_conditionals.html)
- [Error handling](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_error_handling.html)
- [Blocks](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_blocks.html)
- [Filters (ternary, dict2items, ...)](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_filters.html)
