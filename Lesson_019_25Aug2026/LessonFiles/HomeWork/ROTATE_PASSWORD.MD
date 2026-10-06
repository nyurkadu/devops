# Если `DB_USER = new_user`, то `DB_PASSWORD` меняется

**Идея (самый простой вариант):** пароли лежат в зашифрованном Vault в виде
словаря «пользователь → пароль». Шаблон берёт пароль не напрямую, а по ключу
текущего пользователя. Значит достаточно поменять одну строку `vault_db_user` —
и пароль в отрендеренном конфиге меняется сам, без правки шаблона и playbook.

```text
group_vars/webservers/vars.yml          group_vars/webservers/vault.yml (шифр)
┌──────────────────────────────┐        ┌────────────────────────────────────┐
│ vault_db_user: "app_user"    │        │ db_passwords:                      │
│         ▲                    │        │   app_user: "App_P@ssw0rd_2026"    │
│         │ переключатель      │        │   new_user: "N3w_P@ssw0rd_2027"    │
│                              │        └────────────────────────────────────┘
│ vault_db_pass:               │                        ▲
│   "{{ db_passwords[vault_db_user] }}" ────────────────┘
└──────────────────────────────┘
                 │
                 ▼
        templates/db_config.php.j2  →  /var/www/app/db_config.php на node3, node4
```

Меняем `app_user` → `new_user`, и `db_passwords[vault_db_user]` начинает
указывать на другой пароль. Всё.

---

## Шаг 0. Войти в контроллер

Из PowerShell на хосте:

```powershell
docker exec -it ansible-control bash
```

**Что делает:** открывает интерактивную оболочку внутри контейнера-контроллера.
Дальше все команды выполняются **внутри него, в bash** — здесь работают
heredoc'и (`cat > файл << 'EOF'`), которых нет в PowerShell.

Все следующие шаги выполняются в этой оболочке.

---

## Шаг 1. Рабочий каталог

```bash
mkdir -p /root/rotate && cd /root/rotate
mkdir -p group_vars/webservers templates
```

**Что делает:** создаёт каталог задания и две вложенные папки.

* `group_vars/webservers/` — Ansible читает **все** файлы из этого каталога автоматически, если play нацелен на группу `webservers`. Имя каталога обязано совпадать с именем группы в инвентаре.
* `templates/` — стандартное место для Jinja-шаблонов, модуль `template` ищет `src` относительно каталога playbook.

---

## Шаг 2. Инвентарь

```bash
cat > inventory.ini << 'EOF'
[webservers]
node3
node4

[webservers:vars]
ansible_connection=ssh
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
EOF
```

**Что делает:** описывает две управляемые ноды.

* `[webservers]` — имя группы; от него зависит путь `group_vars/webservers/`.
* `ansible_connection=ssh` — подключение по SSH (ключ контроллера уже разложен на ноды).
* `ansible_user=root` — под кем заходить.
* `ansible_python_interpreter` — явный путь, чтобы Ansible не гадал и не сыпал предупреждениями.

Проверка, что ноды отвечают:

```bash
ansible -i inventory.ini webservers -m ping
```

Ожидается `pong` от `node3` и `node4`. Если нет — проблема в подготовке нод,
дальше идти бессмысленно (см. `NODE3_NODE4_SETUP.md`).

---

## Шаг 3. Пароль хранилища Vault

```bash
printf '%s' 'RotatePass2026' > .vault_pass
chmod 600 .vault_pass
```

**Что делает:**

* `printf '%s'` — записывает пароль **без завершающего перевода строки**. `echo` добавил бы `\n`, и паролем хранилища стала бы строка с невидимым символом на конце — потом такой пароль невозможно ввести руками.
* `chmod 600` — читать может только владелец. Ansible ругается на файл с более широкими правами.

Проверка (должно быть ровно 14 байт):

```bash
wc -c < .vault_pass
```

---

## Шаг 4. Открытые переменные — здесь переключатель

```bash
cat > group_vars/webservers/vars.yml << 'EOF'
# Имя БД - не секрет
vault_db_name: "production_db"

# ПЕРЕКЛЮЧАТЕЛЬ: именно эту строку мы будем менять
vault_db_user: "app_user"

# ПРАВИЛО ВЫБОРА ПАРОЛЯ:
# пароль берётся из зашифрованного словаря по ключу текущего пользователя.
# Меняется vault_db_user -> автоматически меняется и пароль.
vault_db_pass: "{{ db_passwords[vault_db_user] }}"
EOF
```

**Что делает:** разделяет несекретное и секретное.

* `vault_db_user` — обычное имя пользователя, не секрет. Лежит открыто, поэтому его легко менять и видно в `git diff`.
* `vault_db_pass` — **не значение, а формула**. Jinja вычисляет её лениво, в момент рендеринга шаблона: берёт словарь `db_passwords` (он придёт из зашифрованного файла на следующем шаге) и достаёт из него элемент с ключом `vault_db_user`.
* Самого пароля в этом файле нет — только правило, как его найти. Поэтому файл можно спокойно коммитить.

Именно эта строка и есть весь механизм задания:

```yaml
vault_db_pass: "{{ db_passwords[vault_db_user] }}"
```

---

## Шаг 5. Зашифрованные пароли

Сначала пишем файл открытым текстом:

```bash
cat > group_vars/webservers/vault.yml << 'EOF'
db_passwords:
  app_user: "App_P@ssw0rd_2026"
  new_user: "N3w_P@ssw0rd_2027"
EOF
```

Затем шифруем его на месте:

```bash
ansible-vault encrypt group_vars/webservers/vault.yml --vault-password-file .vault_pass
```

**Что делает:**

* `db_passwords` — словарь: ключ = имя пользователя, значение = его пароль. Добавить третьего пользователя = добавить строку сюда, playbook и шаблон править не нужно.
* `ansible-vault encrypt` шифрует **существующий** файл алгоритмом AES256 ключом из `.vault_pass` и заменяет его содержимое шифротекстом. Открытая версия на диске не остаётся.
* Используем `encrypt`, а не `create`, потому что `create` открывает редактор `vi` — в скрипте это неудобно.

Проверка, что файл действительно зашифрован:

```bash
head -1 group_vars/webservers/vault.yml     # $ANSIBLE_VAULT;1.1;AES256
```

Посмотреть содержимое, не расшифровывая файл на диске:

```bash
ansible-vault view group_vars/webservers/vault.yml --vault-password-file .vault_pass
```

---

## Шаг 6. Шаблон конфига

```bash
cat > templates/db_config.php.j2 << 'EOF'
<?php
// Generated automatically by Ansible - DO NOT EDIT MANUALLY
define('DB_NAME', '{{ vault_db_name }}');
define('DB_USER', '{{ vault_db_user }}');
define('DB_PASSWORD', '{{ vault_db_pass }}');
define('DB_HOST', 'localhost');
?>
EOF
```

**Что делает:** обычный Jinja-шаблон. Важно, что здесь **нет никакой логики
выбора пароля** — шаблон просто подставляет `vault_db_pass`, а вся условность
осталась в `vars.yml`. Поэтому при смене пользователя шаблон менять не нужно.

Обратите внимание на `>` вместо `>>` в `cat`: `>` перезаписывает файл, `>>`
дописывает в конец. Если случайно использовать `>>` дважды, в файле окажутся
два PHP-блока подряд.

---

## Шаг 7. Playbook

```bash
cat > deploy.yml << 'EOF'
---
- name: Deploy DB config (password follows the user)
  hosts: webservers
  become: true

  tasks:
    - name: Ensure config directory exists
      ansible.builtin.file:
        path: /var/www/app
        state: directory
        mode: '0755'

    - name: Deploy database config
      ansible.builtin.template:
        src: templates/db_config.php.j2
        dest: /var/www/app/db_config.php
        mode: '0600'
      no_log: true
EOF
```

**Что делает каждая часть:**

| Строка | Назначение |
|---|---|
| `hosts: webservers` | play выполняется на обеих нодах; отсюда же подхватывается `group_vars/webservers/` |
| `become: true` | повышение прав для записи в `/var/www/app` (на нодах установлен `sudo`) |
| `file: state=directory` | создать каталог, если его нет; при повторном запуске вернёт `ok`, а не `changed` |
| `template:` | отрендерить Jinja-шаблон и положить результат на ноду |
| `mode: '0600'` | конфиг с паролем читает только root |
| `no_log: true` | **обязательно**: без него Ansible при изменении файла может вывести его содержимое (особенно с `--diff`) — пароль утечёт в лог |

Модуль `template` идемпотентен: он сравнивает отрендеренный результат с файлом
на ноде и перезаписывает только при отличии. Отсюда `changed=0` при повторном
запуске без изменений.

---

## Шаг 8. Первый запуск — пользователь `app_user`

```bash
ansible-playbook -i inventory.ini deploy.yml --vault-password-file .vault_pass
```

**Что делает:** `--vault-password-file` передаёт ключ хранилища, иначе Ansible
запросит его интерактивно и упадёт в неинтерактивной среде.

Ожидаемый результат:

```text
PLAY RECAP
node3 : ok=3  changed=2
node4 : ok=3  changed=2
```

Смотрим, что получилось:

```bash
ssh root@node3 cat /var/www/app/db_config.php
```

```php
<?php
// Generated automatically by Ansible - DO NOT EDIT MANUALLY
define('DB_NAME', 'production_db');
define('DB_USER', 'app_user');
define('DB_PASSWORD', 'App_P@ssw0rd_2026');
define('DB_HOST', 'localhost');
?>
```

Запомните этот пароль — с ним будем сравнивать.

---

## Шаг 9. Смена пользователя — здесь меняется пароль

```bash
sed -i 's/^vault_db_user: .*/vault_db_user: "new_user"/' group_vars/webservers/vars.yml
```

**Что делает:** заменяет одну строку в открытом файле переменных.

* `-i` — правка файла на месте, без создания копии.
* `^vault_db_user: .*` — якорь `^` привязывает шаблон к началу строки, чтобы не задеть похожий текст в комментариях.

Проверяем, что заменилось именно то, что нужно:

```bash
grep vault_db group_vars/webservers/vars.yml
```

Запускаем тот же playbook — **без единой правки** в шаблоне и playbook:

```bash
ansible-playbook -i inventory.ini deploy.yml --vault-password-file .vault_pass
```

```text
PLAY RECAP
node3 : ok=3  changed=1
node4 : ok=3  changed=1
```

`changed=1` — каталог уже был (`ok`), а конфиг перезаписан. Смотрим результат:

```bash
ssh root@node3 cat /var/www/app/db_config.php
```

```php
define('DB_USER', 'new_user');
define('DB_PASSWORD', 'N3w_P@ssw0rd_2027');
```

**Пароль изменился сам.** Мы поменяли только имя пользователя — выражение
`db_passwords[vault_db_user]` стало указывать на другой элемент словаря.

---

## Шаг 10. Проверка идемпотентности

```bash
ansible-playbook -i inventory.ini deploy.yml --vault-password-file .vault_pass
```

```text
node3 : ok=3  changed=0
node4 : ok=3  changed=0
```

**Что доказывает:** `changed=0` означает, что модуль `template` отрендерил тот
же самый текст, что уже лежит на ноде, и ничего не тронул. Playbook можно
запускать сколько угодно раз — состояние не «дёргается».

---

## Шаг 11. Мини-тесты

Каждый тест — команда и то, что она должна вывести. Если вывод отличается,
смотрите раздел «Типичные ошибки» в конце.

### Тест 1. На ноде именно `new_user`

```bash
ssh root@node3 grep DB_USER /var/www/app/db_config.php
```

Ожидаемый результат:

```php
define('DB_USER', 'new_user');
```

Доказывает, что переключатель из `vars.yml` доехал до отрендеренного конфига.

### Тест 2. Пароль соответствует `new_user`, а не `app_user`

```bash
ssh root@node3 grep DB_PASSWORD /var/www/app/db_config.php
```

Ожидаемый результат:

```php
define('DB_PASSWORD', 'N3w_P@ssw0rd_2027');
```

Главный тест задания: пароль сменился сам, вслед за пользователем.
Если здесь `App_P@ssw0rd_2026` — playbook не перезапускали после правки `vars.yml`.

### Тест 3. Обе ноды получили одно и то же

```bash
ssh root@node4 grep DB_PASSWORD /var/www/app/db_config.php
```

Ожидаемый результат (тот же, что на `node3`):

```php
define('DB_PASSWORD', 'N3w_P@ssw0rd_2027');
```

Доказывает, что play отработал на всей группе `webservers`, а не на одной ноде.

### Тест 4. Права на конфиге — только root

```bash
ssh root@node3 ls -l /var/www/app/db_config.php
```

Ожидаемый результат:

```text
-rw------- 1 root root 213 Aug 25 12:23 /var/www/app/db_config.php
```

Важны первые десять символов — `-rw-------`, то есть `0600`: чтение только
владельцу. Дата и размер, разумеется, будут свои.

### Тест 5. Пароли на диске контроллера по-прежнему зашифрованы

```bash
head -1 group_vars/webservers/vault.yml
```

Ожидаемый результат:

```text
$ANSIBLE_VAULT;1.1;AES256
```

Если вместо заголовка видно `db_passwords:` — файл лежит открытым текстом.
Скорее всего, забыт `ansible-vault encrypt` после правки (см. раздел про
редактирование `vault.yml`).

### Тест 6. Пароль не светится в выводе даже с `-vvv`

```bash
ansible-playbook -i inventory.ini deploy.yml --vault-password-file .vault_pass -vvv \
  | grep -c 'N3w_P@ssw0rd_2027'
```

Ожидаемый результат:

```text
0
```

Ноль совпадений — `no_log: true` на задаче `template` отработал.
Любое другое число означает утечку секрета в лог.

> `grep -c` при нуле совпадений возвращает **код выхода 1**. В скрипте с
> `set -e` это оборвёт выполнение на успешном тесте — оборачивайте в
> `|| true` либо сравнивайте результат явно.

### Тест 7. Обратная смена тоже работает

```bash
sed -i 's/^vault_db_user: .*/vault_db_user: "app_user"/' group_vars/webservers/vars.yml
ansible-playbook -i inventory.ini deploy.yml --vault-password-file .vault_pass
ssh root@node3 grep DB_PASSWORD /var/www/app/db_config.php
```

Ожидаемый результат:

```text
PLAY RECAP
node3 : ok=3  changed=1
node4 : ok=3  changed=1
```

```php
define('DB_PASSWORD', 'App_P@ssw0rd_2026');
```

Доказывает, что связь «пользователь → пароль» работает в обе стороны, а не
только на переходе вперёд.

### Сводка

| # | Что проверяем | Ожидание |
|---|---|---|
| 1 | пользователь на ноде | `new_user` |
| 2 | пароль соответствует пользователю | `N3w_P@ssw0rd_2027` |
| 3 | обе ноды синхронны | одинаковый пароль |
| 4 | доступ к секретному файлу | `-rw------- root root` |
| 5 | секреты на диске | `$ANSIBLE_VAULT` |
| 6 | утечка в логи | `0` совпадений |
| 7 | обратная смена | `App_P@ssw0rd_2026` |

---

## Что где лежит (итог)

```text
/root/rotate/
├── .vault_pass                        ключ хранилища (никогда не коммитить)
├── inventory.ini                      node3, node4
├── deploy.yml                         playbook
├── group_vars/webservers/
│   ├── vars.yml                       ПЕРЕКЛЮЧАТЕЛЬ + правило выбора пароля
│   └── vault.yml                      зашифрованный словарь паролей
└── templates/
    └── db_config.php.j2               шаблон конфига
```

Чтобы поменять пользователя — правится только `vars.yml` (одна строка).
Шаблон и playbook не трогаются никогда.

### Как править зашифрованный `vault.yml`

Очевидный способ — `ansible-vault edit` — **в этом контейнере не работает**:

```bash
ansible-vault edit group_vars/webservers/vault.yml --vault-password-file .vault_pass
# ERROR! Unable to execute the command "vi /root/.ansible/tmp/.../tmp.yml":
# [Errno 2] No such file or directory: 'vi'
```

`ansible-vault edit` расшифровывает файл во временный, открывает его в редакторе
из переменной `$EDITOR` (а если она пуста — в `vi`) и после выхода шифрует
обратно. В образе `ansible-control` редакторов нет вообще — есть только `sed`.

**Способ 1 (ничего не устанавливать): decrypt → переписать → encrypt**

```bash
cd /root/rotate

# 1. Расшифровать файл на месте
ansible-vault decrypt group_vars/webservers/vault.yml --vault-password-file .vault_pass

# 2. Переписать целиком (или поправить через sed)
cat > group_vars/webservers/vault.yml << 'EOF'
db_passwords:
  app_user: "App_P@ssw0rd_2026"
  new_user: "N3w_P@ssw0rd_2027"
  third_user: "Th1rd_P@ssw0rd_2028"
EOF

# 3. Зашифровать обратно тем же ключом
ansible-vault encrypt group_vars/webservers/vault.yml --vault-password-file .vault_pass

# 4. Убедиться, что всё на месте
ansible-vault view group_vars/webservers/vault.yml --vault-password-file .vault_pass
```

**Что важно:** между шагами 1 и 3 файл лежит на диске **открытым текстом**.
Не прерывайте последовательность и не коммитьте в этот момент. Если нужно
поменять одно значение, а не весь файл, шаг 2 может быть точечным:

```bash
sed -i 's/^  new_user: .*/  new_user: "Another_P@ss_2029"/' group_vars/webservers/vault.yml
```

**Способ 2: поставить редактор**

```bash
apt-get update -qq && apt-get install -y -qq nano
EDITOR=nano ansible-vault edit group_vars/webservers/vault.yml --vault-password-file .vault_pass
```

Здесь `EDITOR=nano` задаётся прямо перед командой — переменная действует только
на этот запуск. Такой путь удобнее для ручной работы: файл ни на секунду не
оказывается расшифрованным на диске, `ansible-vault` держит его во временном
файле и шифрует сразу после выхода из редактора.

> Пакеты, установленные через `apt-get`, живут в слое контейнера и переживают
> `docker restart`, но исчезнут при пересоздании контейнера.

---


---

## Приложение. Содержимое всех файлов

Итоговое состояние каталога `/root/rotate` внутри контейнера `ansible-control`.
Ниже приведён каждый файл целиком — над содержимым указано его имя.

```text
/root/rotate/
├── .vault_pass
├── inventory.ini
├── deploy.yml
├── group_vars/webservers/vars.yml
├── group_vars/webservers/vault.yml
└── templates/db_config.php.j2
```

---

### `.vault_pass`

```text
RotatePass2026
```

Ровно 14 байт, **без завершающего перевода строки** — файл создан через
`printf '%s'`, а не `echo`. Права `0600`.

> В учебном стенде пароль хранилища приведён открыто. В реальном проекте этот
> файл не коммитится никогда: его добавляют в `.gitignore`, а в CI подставляют
> из секретов пайплайна.

---

### `inventory.ini`

```ini
[webservers]
node3
node4

[webservers:vars]
ansible_connection=ssh
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
```

---

### `group_vars/webservers/vars.yml`

Открытый файл. Здесь переключатель и правило выбора пароля.

```yaml
# Имя БД - не секрет
vault_db_name: "production_db"

# ПЕРЕКЛЮЧАТЕЛЬ: именно эту строку мы будем менять
vault_db_user: "app_user"

# ПРАВИЛО ВЫБОРА ПАРОЛЯ:
# пароль берётся из зашифрованного словаря по ключу текущего пользователя.
# Меняется vault_db_user -> автоматически меняется и пароль.
vault_db_pass: "{{ db_passwords[vault_db_user] }}"
```

---

### `group_vars/webservers/vault.yml`

Содержимое **до шифрования** — именно это вы вводите на шаге 5:

```yaml
db_passwords:
  app_user: "App_P@ssw0rd_2026"
  new_user: "N3w_P@ssw0rd_2027"
```

На диске после `ansible-vault encrypt` файл выглядит так (11 строк,
шифротекст сокращён):

```text
$ANSIBLE_VAULT;1.1;AES256
64366333353065336165656361373930646133313939303534633135373839623062363262393032
3437383063303235306233613066663366353930366561610a643866396334636433303930386333
30373462363138366137383539396536303234626434323331313532663661353539633931356664
...
```

Посмотреть расшифрованное, не трогая файл:

```bash
ansible-vault view group_vars/webservers/vault.yml --vault-password-file .vault_pass
```

---

### `templates/db_config.php.j2`

```jinja
<?php
// Generated automatically by Ansible - DO NOT EDIT MANUALLY
define('DB_NAME', '{{ vault_db_name }}');
define('DB_USER', '{{ vault_db_user }}');
define('DB_PASSWORD', '{{ vault_db_pass }}');
define('DB_HOST', 'localhost');
?>
```

---

### `deploy.yml`

```yaml
---
- name: Deploy DB config (password follows the user)
  hosts: webservers
  become: true

  tasks:
    - name: Ensure config directory exists
      ansible.builtin.file:
        path: /var/www/app
        state: directory
        mode: '0755'

    - name: Deploy database config
      ansible.builtin.template:
        src: templates/db_config.php.j2
        dest: /var/www/app/db_config.php
        mode: '0600'
      no_log: true
```

---

### Результат на ноде: `/var/www/app/db_config.php`

Это не исходник, а то, что получается после `ansible-playbook`.
При `vault_db_user: "app_user"`:

```php
<?php
// Generated automatically by Ansible - DO NOT EDIT MANUALLY
define('DB_NAME', 'production_db');
define('DB_USER', 'app_user');
define('DB_PASSWORD', 'App_P@ssw0rd_2026');
define('DB_HOST', 'localhost');
?>
```

После смены на `vault_db_user: "new_user"` и повторного запуска:

```php
<?php
// Generated automatically by Ansible - DO NOT EDIT MANUALLY
define('DB_NAME', 'production_db');
define('DB_USER', 'new_user');
define('DB_PASSWORD', 'N3w_P@ssw0rd_2027');
define('DB_HOST', 'localhost');
?>
```

Изменились две строки — `DB_USER` и `DB_PASSWORD`. При этом ни шаблон,
ни playbook, ни `vault.yml` не правились: тронута одна строка в `vars.yml`.
