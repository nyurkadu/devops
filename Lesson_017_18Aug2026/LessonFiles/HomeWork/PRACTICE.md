# Практика: обработка ошибок бизнес-логики в Ansible

Шесть сценариев по схеме:

```
произошла ситуация
        ↓
решаем, критична она или нет
        ↓
Ansible реагирует нужным способом
```

Теория к ним — в [theory.md](theory.md).
Все выводы ниже — **реальные**, снятые с этого стенда (node1 / node2, `nginx:alpine`, Ansible core 2.21).

---

## Содержание

| # | Файл | Ситуация | Инструмент |
|---|---|---|---|
| 0 | — | [Подготовка стенда](#0-подготовка-стенда) | — |
| 1 | [01_ignore_errors.yml](01_ignore_errors.yml) | мониторинг недоступен, legacy-сервиса нет | `ignore_errors` |
| 2 | [02_failed_when.yml](02_failed_when.yml) | бэкап «упал» с rc=0; лицензия «упала» с rc=2 | `failed_when` |
| 3 | [03_changed_when.yml](03_changed_when.yml) | ложный `changed`, лишние перезапуски сервиса | `changed_when` + handler |
| 4 | [04_thresholds.yml](04_thresholds.yml) | диск: warning vs critical | `failed_when` + `when` + `ternary` |
| 5 | [05_block_rescue_always.yml](05_block_rescue_always.yml) | деплой не прошёл smoke-тест | `block` / `rescue` / `always` |
| 6 | [06_assert_validation.yml](06_assert_validation.yml) | забыли параметры запуска | `assert` / `fail` |
| — | [all_scenarios.yml](all_scenarios.yml) | все сценарии подряд (1–5) | — |
| — | — | [Шпаргалка по флагам](#шпаргалка-по-флагам) | — |
| — | — | [Сброс состояния](#сброс-состояния-стенда) | — |

---

## 0. Подготовка стенда

### 0.1 Собрать контроллер (один раз)

```powershell
docker build -t ansible-controller -f Dockerfile.ansible .
```

### 0.2 Поднять ноды (один раз)

Плейбук лежит в соседней папке `ClassWork`, поэтому монтировать надо **родительский**
каталог `LessonFiles`, а не `HomeWork`. Из папки `LessonFiles`:

```powershell
cd C:\Users\avila\devops\CloudLessons\Lesson_017_18Aug2026\LessonFiles

docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/ansible" `
  ansible-controller -i HomeWork/inventory.ini ClassWork/create_nodes.yml
```

Не выходя из `HomeWork` — то же самое, родитель монтируется явно:

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$(Split-Path $PWD -Parent):/ansible" `
  ansible-controller -i HomeWork/inventory.ini ClassWork/create_nodes.yml
```

> **Почему не работает `-v "${PWD}:/ansible" ... ../ClassWork/create_nodes.yml`.**
> Так монтируется только `HomeWork`, а `WORKDIR` образа — `/ansible`. Внутри контейнера
> `../ClassWork/create_nodes.yml` превращается в `/ClassWork/create_nodes.yml` — этого пути
> в контейнере нет, и Ansible отвечает:
>
> ```
> [ERROR]: the playbook: ../ClassWork/create_nodes.yml could not be found
> ```
>
> `..` никогда не выходит за точку монтирования: всё, что выше неё, контейнеру не видно.
> Правило: **монтируй самый верхний каталог, которого касается команда**, и все пути
> задавай относительно этой точки монтирования.

Ожидаемый результат:

```
TASK [Show node status] ********************************************************
ok: [localhost] => "msg": "/node1 -> status: running, published on http://localhost:8081"
ok: [localhost] => "msg": "/node2 -> status: running, published on http://localhost:8082"

PLAY RECAP *********************************************************************
localhost                  : ok=2    changed=2    unreachable=0    failed=0
```

(при повторном запуске `changed=0` — модуль идемпотентен)

Или вручную:

```powershell
docker run -d --name node1 --restart unless-stopped -p 8081:80 nginx:alpine
docker run -d --name node2 --restart unless-stopped -p 8082:80 nginx:alpine
```

### 0.3 Доставить python3 на ноды (Ansible без него не работает)

```powershell
docker exec node1 sh -c "apk add --no-cache python3 sudo"
docker exec node2 sh -c "apk add --no-cache python3 sudo"
```

### 0.4 Проверка связи

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/ansible" `
  --entrypoint ansible ansible-controller -i inventory.ini webservers -m ping
```

Ожидаемый результат:

```
node1 | SUCCESS => { "changed": false, "ping": "pong" }
node2 | SUCCESS => { "changed": false, "ping": "pong" }
```

### 0.5 Короткая команда запуска

Дальше во всех примерах используется такая форма (PowerShell, из папки `HomeWork`):

```powershell
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/ansible" ansible-controller -i inventory.ini <playbook.yml> [-e key=value]
```

Чтобы не печатать её целиком, заведи функцию на сессию:

```powershell
function ap { docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "${PWD}:/ansible" ansible-controller -i inventory.ini @args }
# дальше просто:  ap 01_ignore_errors.yml
```

Git Bash — то же самое:

```bash
ap() { MSYS_NO_PATHCONV=1 docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$(pwd -W)":/ansible ansible-controller -i inventory.ini "$@"; }
```

> В Git Bash обязателен `MSYS_NO_PATHCONV=1` и `$(pwd -W)`, иначе пути вида
> `/var/run/docker.sock` превращаются в `C:/Program Files/Git/var/...`.

Проверка синтаксиса всех плейбуков без запуска:

```powershell
ap --syntax-check all_scenarios.yml 06_assert_validation.yml
```

```
playbook: all_scenarios.yml
playbook: 06_assert_validation.yml
```

---

## 1. `ignore_errors` — некритичная ошибка

**Ситуация:** после деплоя шлём метрику в мониторинг и пробуем остановить старый сервис `legacy-app`, которого на хосте может не быть.
**Критично?** Нет: ни мониторинг, ни legacy-сервис не влияют на работу приложения.
**Реакция:** `ignore_errors: true` — записать факт в лог и продолжить.

### Запуск

```powershell
ap 01_ignore_errors.yml
```

### Ожидаемый результат

```
TASK [1.1 Send deploy metric to monitoring (best effort)] **********************
fatal: [node1]: FAILED! => {"msg": "Status code was -1 and not [200]: Request failed:
        <urlopen error [Errno -2] Name does not resolve>", ...}
...ignoring

TASK [1.2 Business decision: monitoring is optional -> only log it] ************
ok: [node1] => {
    "msg": "Monitoring is unreachable, deploy continues. Reason: Status code was -1 ..."
}

TASK [1.3 Stop legacy service (may not exist on this host)] ********************
fatal: [node1]: FAILED! => {"msg": "Error executing command.", "rc": 2, ...}
...ignoring

TASK [1.4 Legacy service was already absent] ***********************************
ok: [node1] => {
    "msg": "No legacy-app on this host - nothing to stop."
}

TASK [1.5 Critical step still runs: nginx binary must be present] **************
ok: [node1]

TASK [1.6 Show nginx version] **************************************************
ok: [node1] => {
    "msg": "nginx version: nginx/1.31.3"
}

PLAY RECAP *********************************************************************
node1                      : ok=6    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=2
node2                      : ok=6    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=2
```

### На что смотреть

- `...ignoring` под красным `fatal:` — задача **упала**, но плейбук пошёл дальше.
- В recap: `failed=0`, зато **`ignored=2`**. Это и есть подпись `ignore_errors`.
- Задача 1.5 выполнилась — значит критичная часть работы не потеряна.

### Повторные запуски

Результат **всегда одинаковый**: `ok=6 changed=0 ignored=2`. Задачи read-only, состояние на нодах не меняется — идеальный пример идемпотентности.

### Эксперименты

1. Убери `ignore_errors: true` у задачи 1.1 и запусти снова:

   ```
   PLAY RECAP
   node1 : ok=0 changed=0 failed=1 ignored=0
   ```

   Плейбук останавливается на первой же задаче — задачи 1.2–1.6 вообще не выполняются. Верни флаг обратно.
2. Сделай игнор условным — ошибки прощаем везде, кроме прода:

   ```yaml
   ignore_errors: "{{ target_env | default('dev') != 'prod' }}"
   ```

   ```powershell
   ap 01_ignore_errors.yml -e target_env=dev    # ignored=1, плейбук идёт дальше
   ap 01_ignore_errors.yml -e target_env=prod   # failed=1, плейбук встаёт
   ```

---

## 2. `failed_when` — я сам решаю, что считать ошибкой

Три ситуации в одном плейбуке.

| # | Ситуация | Что видит Ansible по умолчанию | Правильная реакция |
|---|---|---|---|
| A | `backup.sh` пишет `ERROR`, но выходит с `rc=0` | «успех» | **ошибка** → `failed_when: "'ERROR' in stdout"` |
| B | `check_license.sh` выходит с `rc=2` = «истекает через 12 дней» | «ошибка» | предупреждение → `failed_when: rc not in [0,2]` |
| C | `grep` не нашёл строку, `rc=1` | «ошибка» | ответ «нет» → `failed_when: false` |

### Запуск (нормальный режим)

Сначала сброс — задача 2.0 (`copy`) идемпотентна, и если скрипты уже лежат на нодах
от прошлого прогона, она вернёт `ok` вместо `changed`, и цифры в `PLAY RECAP` не сойдутся
с приведёнными ниже:

```powershell
foreach ($n in @("node1","node2")) {
  docker exec $n sh -c "rm -f /usr/local/bin/backup.sh /usr/local/bin/check_license.sh"
}
```

Git Bash:

```bash
for n in node1 node2; do
  MSYS_NO_PATHCONV=1 docker exec $n sh -c "rm -f /usr/local/bin/backup.sh /usr/local/bin/check_license.sh"
done
```

Теперь сам запуск:

```powershell
ap 02_failed_when.yml
```

### Ожидаемый результат

```
TASK [2.0 Deploy business scripts] *********************************************
changed: [node1] => (item=backup.sh)
changed: [node1] => (item=check_license.sh)

TASK [2.1 Run backup (rc is always 0, the error lives in stdout)] **************
changed: [node1]

TASK [2.2 Backup report] *******************************************************
ok: [node1] => {
    "backup.stdout_lines": [
        "backup: started",
        "backup: 128 MB written to /mnt/backup/20260823",
        "backup: finished OK"
    ]
}

TASK [2.3 License check (rc=2 is a warning, not a failure)] ********************
ok: [node1]

TASK [2.4 License warning] *****************************************************
ok: [node1] => {
    "msg": "WARNING: license: valid, expires in 12 days (rc=2) - renew it, but do not stop the deploy"
}

TASK [2.5 Is the debug module enabled in nginx.conf?] **************************
ok: [node1]

TASK [2.6 grep verdict] ********************************************************
ok: [node1] => {
    "msg": "debug_connection found: no"
}

PLAY RECAP *********************************************************************
node1                      : ok=7    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Обрати внимание на 2.3: задача зелёная (`ok`), хотя скрипт вернул **rc=2** — это `failed_when` переопределил правило.

### Повторный запуск

```
node1 : ok=7    changed=1    unreachable=0    failed=0
```

`changed` уменьшился с 2 до 1: скрипты уже лежат на месте (2.0 стало `ok`), а бэкап (2.1) честно остаётся `changed` — он реально каждый раз пишет новый архив.

> Если `changed=1` пришёл уже на **первом** запуске — значит запуск был не первым: скрипты
> остались от предыдущей сессии. Проверить можно так:
>
> ```powershell
> docker exec node1 sh -c "ls -l --full-time /usr/local/bin/"
> ```
>
> Сравни время файлов с временем запуска. Лечится сбросом из блока выше.

`ok=7` одинаков в обоих случаях: счётчик считает **задачи**, а не элементы цикла — 2.0 с двумя
файлами это одна задача.

### Ключевой эксперимент: «тихая» ошибка

```powershell
ap 02_failed_when.yml -e backup_mode=broken
```

```
TASK [2.1 Run backup (rc is always 0, the error lives in stdout)] **************
[ERROR]: Task failed: Action failed: A 'failed_when' expression evaluated to 'True'.
fatal: [node1]: FAILED! => {
    "rc": 0,
    "failed_when_result": true,
    "stdout_lines": ["backup: started", "ERROR: backup destination /mnt/backup is not writable"]
}

PLAY RECAP *********************************************************************
node1                      : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

Здесь вся суть: **`rc: 0`, но `failed_when_result: true`**. Без `failed_when` Ansible нарисовал бы зелёный `changed`, бэкапа бы не было, а узнали бы мы об этом при первой аварии.

### Эксперименты

1. Убери `failed_when` из 2.1 и запусти с `-e backup_mode=broken` — задача станет `ok`, «сломанный бэкап» пройдёт незамеченным.
2. Убери `failed_when` из 2.3 — задача станет `failed` (`rc=2`), плейбук остановится на безобидном предупреждении.
3. Замени в 2.5 `failed_when: false` на `failed_when: grep_out.rc != 0` — «строка не найдена» превратится в аварию.
4. Сделай условие строже — считать ошибкой ещё и `WARNING`:

   ```yaml
   failed_when: "'ERROR' in backup.stdout or 'WARNING' in backup.stdout"
   ```

---

## 3. `changed_when` — я сам решаю, что считать изменением

**Ситуация A:** `uptime` и `cat /proc/loadavg` через модуль `command` каждый прогон рапортуют `changed` — Ansible не знает семантику команды.
**Критично?** Не ошибка, но ложный шум: отчёт перестаёт быть идемпотентным.
**Реакция:** `changed_when: false`.

**Ситуация B:** `sync_config.sh` запускается всегда, но реально меняет файл, только если конфиг отличается. От `changed` зависит **запуск handler** (перезагрузка приложения).
**Реакция:** `changed_when: "'config updated' in sync.stdout"`.

### Запуск №1 (чистый стенд)

Сброс — иначе задачи 3.4–3.6 вернут `ok` вместо `changed`, а 3.7 напечатает
`config unchanged`, и ты сразу попадёшь в «Запуск №2»:

```powershell
foreach ($n in @("node1","node2")) {
  docker exec $n sh -c "rm -rf /opt/app /usr/local/bin/sync_config.sh /var/log/app-reload.log"
}
```

Git Bash:

```bash
for n in node1 node2; do
  MSYS_NO_PATHCONV=1 docker exec $n sh -c "rm -rf /opt/app /usr/local/bin/sync_config.sh /var/log/app-reload.log"
done
```

> `/opt/app` удаляется целиком — иначе задача 3.4 (`file: state=directory`) вернёт `ok`,
> и в recap будет `changed=4`, а не 5. Побочный эффект: вместе с каталогом уходят
> и релизы сценария 5 (`/opt/app/releases`). Это нормально — сценарий 5 корректно
> отрабатывает пустой каталог (`no previous release`).

```powershell
ap 03_changed_when.yml
```

```
TASK [3.1 Read-only check: uptime (never a change)] ****************************
ok: [node1]

TASK [3.2 Read-only check: load average (never a change)] **********************
ok: [node1]

TASK [3.3 Health snapshot] *****************************************************
ok: [node1] => {
    "msg": "uptime: 09:43:37 up 18 min, 0 users, load average: 1.91, 0.89, 0.43 | loadavg: 2.09 0.94 0.46 3/544 959"
}

TASK [3.4 Ensure application directory exists] *********************************
changed: [node1]

TASK [3.5 Render the new config (module tracks changes itself)] ****************
changed: [node1]

TASK [3.6 Deploy the sync script] **********************************************
changed: [node1]

TASK [3.7 Sync config (changed ONLY when it really changed)] *******************
changed: [node1]

TASK [3.8 Sync verdict] ********************************************************
ok: [node1] => {
    "msg": "sync_config.sh -> config updated"
}

RUNNING HANDLER [Reload application] *******************************************
changed: [node1]

PLAY RECAP *********************************************************************
node1                      : ok=9    changed=5    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

### Запуск №2 — та же команда, ничего не изменилось

```powershell
ap 03_changed_when.yml
```

```
TASK [3.7 Sync config (changed ONLY when it really changed)] *******************
ok: [node1]

TASK [3.8 Sync verdict] ********************************************************
ok: [node1] => {
    "msg": "sync_config.sh -> config unchanged"
}

PLAY RECAP *********************************************************************
node1                      : ok=8    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

**`changed=0`, блока `RUNNING HANDLER` вообще нет** — приложение не перезапускалось. Это и есть цель `changed_when`.
Всего задач стало 8 вместо 9 — handler не выполнялся, значит и в recap его нет.

### Запуск №3 — конфиг реально поменялся

```powershell
ap 03_changed_when.yml -e app_port=9090
```

```
TASK [3.5 Render the new config (module tracks changes itself)] ****************
changed: [node1]

TASK [3.7 Sync config (changed ONLY when it really changed)] *******************
changed: [node1]

TASK [3.8 Sync verdict] ********************************************************
ok: [node1] => { "msg": "sync_config.sh -> config updated" }

RUNNING HANDLER [Reload application] *******************************************
changed: [node1]

PLAY RECAP *********************************************************************
node1                      : ok=9    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Handler снова сработал — потому что изменение было настоящим.

### Проверить, что handler отработал

```powershell
docker exec node1 cat /var/log/app-reload.log
```

```
2026-08-23T09:43:50Z reloaded, listen_port=8080
2026-08-23T09:44:29Z reloaded, listen_port=9090
```

Ровно две строки на три прогона — второй запуск сервис не трогал.

### Цикл для практики

```powershell
ap 03_changed_when.yml                  # changed=5, handler сработал
ap 03_changed_when.yml                  # changed=0, handler не сработал
ap 03_changed_when.yml -e app_port=9090 # changed=3, handler сработал
ap 03_changed_when.yml -e app_port=9090 # changed=0, handler не сработал
ap 03_changed_when.yml                  # changed=3 (вернулись к 8080), handler сработал
```

### Эксперименты

1. Убери `changed_when: false` у 3.1 — каждый прогон будет давать лишние `changed`, отчёт перестанет быть честным.
2. Убери `changed_when` у 3.7 — модуль `command` начнёт рапортовать `changed` **всегда**, и handler будет перезапускать приложение на каждом прогоне. Проверь по `app-reload.log`: строк станет столько же, сколько запусков.
3. Поставь `changed_when: true` у 3.7 — тот же эффект, но уже явно и осознанно.

---

## 4. Бизнес-пороги: warning vs critical

**Ситуация:** заполняется диск. Один и тот же факт требует разной реакции.

| Значение | Решение | Инструмент |
|---|---|---|
| `<= 70%` | норма | `when` (сообщение «OK») |
| `> 70%` | предупреждение, работаем дальше | `when` + `ternary` |
| `> 90%` | критично, останавливаемся | `failed_when` |

### Запуск (нормальное состояние)

```powershell
ap 04_thresholds.yml
```

```
TASK [4.1 Measure root disk usage] *********************************************
ok: [node1]

TASK [4.2 Severity via ternary] ************************************************
ok: [node1] => {
    "msg": "disk=3% threshold=70% severity=OK"
}

TASK [4.3 Warning zone: log it, but keep going] ********************************
skipping: [node1]

TASK [4.4 Free memory precondition (hard stop)] ********************************
skipping: [node1]

TASK [4.5 Host is healthy enough to deploy] ************************************
ok: [node1] => {
    "msg": "node1 OK: disk 3%, free mem 6081MB, os Alpine 3.24.1"
}

PLAY RECAP *********************************************************************
node1                      : ok=4    changed=0    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0
```

`skipped=2` — сработали `when`: предупреждение и hard stop не нужны.

### Зона предупреждения — снижаем порог

```powershell
ap 04_thresholds.yml -e disk_warning_pct=1
```

```
TASK [4.2 Severity via ternary] ************************************************
ok: [node1] => { "msg": "disk=3% threshold=1% severity=WARNING" }

TASK [4.3 Warning zone: log it, but keep going] ********************************
ok: [node1] => { "msg": "WARNING: disk usage 3% is above 1%, plan a cleanup" }

PLAY RECAP *********************************************************************
node1                      : ok=5    changed=0    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```

`ok` вырос до 5, `skipped` упал до 1, но `failed=0` — предупреждение деплой не останавливает. То же значение диска (`3%`), другая реакция — потому что изменилось бизнес-правило, а не факт.

### Критическая зона

```powershell
ap 04_thresholds.yml -e disk_critical_pct=1
```

```
TASK [4.1 Measure root disk usage] *********************************************
[ERROR]: Task failed: Action failed: A 'failed_when' expression evaluated to 'True'.
fatal: [node1]: FAILED! => {
    "cmd": "df -P / | awk 'NR==2 {print $5}' | tr -d '%'",
    "rc": 0,
    "failed_when_result": true,
    "stdout": "3"
}

PLAY RECAP *********************************************************************
node1                      : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

Снова `rc: 0` + `failed_when_result: true` — команда отработала штатно, ошибкой её сделало **бизнес-правило**.

### Повторные запуски

Стабильны: плейбук ничего не меняет на хосте (`changed=0` всегда). Разница в выводе появляется только от порогов в `-e` или от реального заполнения диска.

### Эксперименты

1. `-e min_free_mem_mb=999999` — сработает задача 4.4 (`fail`), плейбук остановится с понятным человеку сообщением, а не с «rc=1».
2. Сделай двойной порог одной строкой:

   ```yaml
   failed_when: disk.stdout | int > disk_critical_pct | int or ansible_facts['memfree_mb'] | int < min_free_mem_mb | int
   ```
3. Поменяй `ternary` в 4.2 на трёхуровневую логику через словарь-мапу (см. раздел 3.5 в [theory.md](theory.md)).

---

## 5. `block` / `rescue` / `always` — транзакционный деплой

**Ситуация:** раскатываем версию, smoke-тест не проходит.
**Критично?** Да, но есть план Б.
**Реакция:**

- `block` — сохранить текущую версию, записать новую, прогнать smoke-тест;
- `rescue` — откатиться на предыдущую версию;
- `always` — снять lock и показать активную версию (выполняется в любом случае).

### Запуск №1 — успешный деплой

Сброс — если релизы остались от прошлой сессии, задача `Keep the current version as previous`
станет `changed` («saved …») вместо `no previous release`, и `changed` в recap уедет:

```powershell
foreach ($n in @("node1","node2")) {
  docker exec $n sh -c "rm -rf /opt/app/releases /var/run/deploy.lock"
}
```

Git Bash:

```bash
for n in node1 node2; do
  MSYS_NO_PATHCONV=1 docker exec $n sh -c "rm -rf /opt/app/releases /var/run/deploy.lock"
done
```

> Здесь `/opt/app` не трогаем, только подкаталог `releases` — конфиги сценария 3
> (`config.new` / `config.active`) остаются на месте.

```powershell
ap 05_block_rescue_always.yml
```

```
TASK [Activate the new version] ************************************************
changed: [node1]

TASK [Smoke test: application answers with HTTP 200] ***************************
ok: [node1]

TASK [Deploy succeeded] ********************************************************
ok: [node1] => {
    "msg": "Version 1.4.2 is live, smoke test returned 200"
}

TASK [Always: release the deploy lock] *****************************************
changed: [node1]

TASK [Always: final state] *****************************************************
ok: [node1] => {
    "msg": "Active version on node1: 1.4.2"
}

PLAY RECAP *********************************************************************
node1                      : ok=9    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Блок `rescue` не выполнялся — в выводе его задач просто нет.

### Запуск №2 — ломаем smoke-тест

```powershell
ap 05_block_rescue_always.yml -e app_version=2.0.0-broken -e smoke_port=9999
```

```
TASK [Smoke test: application answers with HTTP 200] ***************************
fatal: [node1]: FAILED! => {"msg": "Status code was -1 and not [200]: Request failed:
        <urlopen error [Errno 111] Connection refused>", "url": "http://localhost:9999/"}

TASK [Rescue: what exactly failed] *********************************************
ok: [node1] => {
    "msg": "FAILED task: 'Smoke test: application answers with HTTP 200' | error: Status code was -1 ... Connection refused"
}

TASK [Rescue: roll back to the previous version] *******************************
changed: [node1]

TASK [Rescue: verdict] *********************************************************
ok: [node1] => {
    "msg": "Deploy of 2.0.0-broken cancelled -> rolled_back to 1.4.2"
}

TASK [Always: release the deploy lock] *****************************************
changed: [node1]

TASK [Always: final state] *****************************************************
ok: [node1] => {
    "msg": "Active version on node1: 1.4.2"
}

PLAY RECAP *********************************************************************
node1                      : ok=10   changed=4    unreachable=0    failed=0    skipped=0    rescued=1    ignored=0
```

### На что смотреть

- **`rescued=1`, `failed=0`** — ошибка была, но её обработали, плейбук считается успешным.
- `ansible_failed_task.name` и `ansible_failed_result.msg` доступны только внутри `rescue` — они показывают, что именно упало.
- Версия на диске откатилась: `Active version: 1.4.2`, хотя мы деплоили `2.0.0-broken`.
- Задачи `always` выполнились в обоих запусках — lock снят и после успеха, и после провала.

### Проверить состояние на ноде

```powershell
docker exec node1 sh -c "cat /opt/app/releases/current; echo ---; cat /opt/app/releases/previous; echo ---; ls -l /var/run/deploy.lock"
```

```
1.4.2
---
1.4.2
---
ls: /var/run/deploy.lock: No such file or directory
```

Lock-файла нет — его удалила задача из `always`.

### Повторные запуски

- Успешный прогон второй раз подряд: `changed` уменьшается (`Activate the new version` становится `ok`, версия уже та же).
- Сломанный прогон можно повторять сколько угодно — активной всегда останется последняя рабочая версия.

### Эксперименты

1. Добавь в конец `rescue` явное падение — тогда откат произойдёт, но плейбук всё равно упадёт (так делают, когда CI не должен считать деплой успешным):

   ```yaml
       - name: "Rescue: fail the play anyway"
         ansible.builtin.fail:
           msg: "Deploy of {{ app_version }} failed, rolled back"
   ```

   Recap станет: `rescued=1 failed=1`. Задачи `always` всё равно выполнятся — проверь по выводу.
2. Урони задачу внутри `always` (например, `command: /bin/nope`) — увидишь, что `always` не защищён сам по себе.
3. Перенеси `Take the deploy lock` внутрь `block` и сломай smoke-тест — lock всё равно снимется, потому что `always` не зависит от места сбоя.
4. Оберни smoke-тест в `until`/`retries`, чтобы дать приложению время подняться:

   ```yaml
         register: smoke
         until: smoke.status == 200
         retries: 5
         delay: 3
   ```

---

## 6. `assert` / `fail` — валидация входных данных

**Ситуация:** инженер запустил деплой и забыл указать версию или окружение.
**Критично?** Да. Дешевле упасть до первого изменения, чем на середине.
**Реакция:** `assert` для предусловий, `fail` для политики прода.

### Запуск №1 — без параметров

```powershell
ap 06_assert_validation.yml
```

```
TASK [6.1 Preconditions must hold] *********************************************
fatal: [node1]: FAILED! => {
    "assertion": "app_version is defined",
    "changed": false,
    "evaluated_to": false,
    "msg": "Bad parameters. Need -e app_version=X.Y.Z and -e target_env=<dev|stage|prod>"
}

PLAY RECAP *********************************************************************
node1                      : ok=0    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

`ok=0` — не выполнено **ничего**. Ansible показывает, какое именно утверждение не прошло (`assertion`).

### Запуск №2 — кривая версия

```powershell
ap 06_assert_validation.yml -e app_version=latest -e target_env=prod
```

Падает на `app_version is match('^[0-9]+\.[0-9]+\.[0-9]+$')` — `latest` не проходит регулярку.

### Запуск №3 — прод без тикета

```powershell
ap 06_assert_validation.yml -e app_version=1.4.2 -e target_env=prod
```

```
TASK [6.1 Preconditions must hold] *********************************************
ok: [node1] => { "msg": "Parameters are valid" }

TASK [6.2 Production deploy requires an approved change ticket] ****************
fatal: [node1]: FAILED! => {"changed": false, "msg": "Deploy to prod requires -e change_ticket=CHG-XXXX"}

PLAY RECAP *********************************************************************
node1                      : ok=1    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0
```

### Запуск №4 — всё корректно

```powershell
ap 06_assert_validation.yml -e app_version=1.4.2 -e target_env=prod -e change_ticket=CHG-1234
```

```
TASK [6.1 Preconditions must hold] *********************************************
ok: [node1] => { "msg": "Parameters are valid" }

TASK [6.2 Production deploy requires an approved change ticket] ****************
skipping: [node1]

TASK [6.3 Cleared for deploy] **************************************************
ok: [node1] => {
    "msg": "Deploying 1.4.2 to prod (ticket: CHG-1234)"
}

PLAY RECAP *********************************************************************
node1                      : ok=2    changed=0    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```

### Запуск №5 — dev тикета не требует

```powershell
ap 06_assert_validation.yml -e app_version=1.4.2 -e target_env=dev
```

```
ok: [node1] => { "msg": "Deploying 1.4.2 to dev (ticket: not required)" }
node1 : ok=2    changed=0    failed=0    skipped=1
```

### Эксперименты

1. `-e target_env=qa` — не входит в `allowed_envs`, падает на четвёртом утверждении.
2. Добавь в `assert` проверку ОС:

   ```yaml
         - ansible_facts['os_family'] in ['Debian', 'Alpine']
   ```

   потребуется `gather_facts: true`.
3. Замени `fail` в 6.2 на `assert` — сравни формат сообщения об ошибке.

---

## Все сценарии подряд

```powershell
ap all_scenarios.yml
```

Пять плейбуков выполняются последовательно, recap общий:

```
PLAY [S01 | Non-critical failures (ignore_errors)] *****************************
PLAY [S02 | Custom failure conditions (failed_when)] ***************************
PLAY [S03 | What counts as a change (changed_when + handlers)] *****************
PLAY [S04 | Business thresholds: warning vs critical] **************************
PLAY [S05 | Transactional deploy with rollback] ********************************

PLAY RECAP *********************************************************************
node1                      : ok=35   changed=6    unreachable=0    failed=0    skipped=2    rescued=0    ignored=2
```

Точные `changed` зависят от того, что уже лежит на нодах после предыдущих прогонов. На полностью чистом стенде `changed` больше, на втором прогоне подряд — заметно меньше. Стабильны всегда `failed=0` и `ignored=2`.

---

## Шпаргалка по флагам

| Флаг | Что делает | Пример |
|---|---|---|
| `--syntax-check` | проверить YAML, ничего не запуская | `ap --syntax-check 05_block_rescue_always.yml` |
| `--list-tasks` | показать список задач плейбука | `ap --list-tasks all_scenarios.yml` |
| `--list-hosts` | показать, на какие хосты попадёт play | `ap --list-hosts 01_ignore_errors.yml` |
| `--check` | dry-run: что изменилось бы | `ap --check 03_changed_when.yml` |
| `--diff` | показать разницу в файлах | `ap --check --diff 03_changed_when.yml` |
| `-v` / `-vvv` | подробный вывод / отладка connection | `ap -v 02_failed_when.yml` |
| `--step` | подтверждать каждую задачу вручную | `ap --step 05_block_rescue_always.yml` |
| `--start-at-task` | начать с конкретной задачи | `ap 03_changed_when.yml --start-at-task "3.7 Sync config (changed ONLY when it really changed)"` |
| `-l` / `--limit` | выполнить только на одном хосте | `ap 04_thresholds.yml -l node1` |
| `-e` | передать переменную | `ap 02_failed_when.yml -e backup_mode=broken` |

Полезно для сценария 3: в `--check` модули `command`/`shell` не выполняются вообще — задачи 3.1, 3.2 и 3.7 покажут `skipping`, а 3.8 напечатает пустой `stdout`:

```
ap --check 03_changed_when.yml
...
TASK [3.8 Sync verdict] ********************************************************
ok: [node1] => { "msg": "sync_config.sh -> " }

PLAY RECAP *********************************************************************
node1                      : ok=5    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
```

Это нормальное поведение `check_mode`: Ansible не знает, безопасна ли произвольная команда, поэтому не запускает её. Модули `file`/`copy` в `--check` работают и честно показывают, что изменилось бы (особенно с `--diff`).

---

## Сброс состояния стенда

Состояние на нодах накапливают сценарии **2, 3 и 5** — если его не сбросить, `PLAY RECAP`
не сойдётся с приведённым в тексте. Сценарии **1, 4 и 6** идемпотентны, сброса не требуют.

Точечные сбросы под каждый сценарий даны прямо в его разделе:
[сценарий 2](#2-failed_when--я-сам-решаю-что-считать-ошибкой),
[сценарий 3](#3-changed_when--я-сам-решаю-что-считать-изменением),
[сценарий 5](#5-block--rescue--always--транзакционный-деплой).

Полный сброс сразу под все сценарии:

```powershell
foreach ($n in @("node1","node2")) {
  docker exec $n sh -c "rm -rf /opt/app /var/log/app-reload.log /usr/local/bin/backup.sh /usr/local/bin/check_license.sh /usr/local/bin/sync_config.sh /var/run/deploy.lock"
}
```

Git Bash:

```bash
for n in node1 node2; do
  MSYS_NO_PATHCONV=1 docker exec $n sh -c "rm -rf /opt/app /var/log/app-reload.log /usr/local/bin/backup.sh /usr/local/bin/check_license.sh /usr/local/bin/sync_config.sh /var/run/deploy.lock"
done
```

Полный сброс нод (пересоздать контейнеры):

```powershell
docker rm -f node1 node2
# затем повторить шаги 0.2 и 0.3
```

---

## Итог: таблица решений

| Ситуация | Критична? | Реакция Ansible | Инструмент | Сценарий |
|---|---|---|---|---|
| Мониторинг недоступен | нет | залогировать, идти дальше | `ignore_errors` | 1 |
| Legacy-сервиса нет на хосте | нет | пропустить | `ignore_errors` | 1 |
| Бэкап пишет `ERROR` при rc=0 | **да** | пометить как ошибку | `failed_when` по stdout | 2 |
| Лицензия истекает (rc=2) | нет | предупредить | `failed_when: rc not in [0,2]` | 2 |
| `grep` ничего не нашёл (rc=1) | нет | это ответ «нет» | `failed_when: false` | 2 |
| Read-only проверки | нет | не помечать как change | `changed_when: false` | 3 |
| Конфиг не изменился | нет | не дёргать handler | `changed_when` по stdout | 3 |
| Диск > 70% | нет | предупредить | `when` + `ternary` | 4 |
| Диск > 90% | **да** | остановить плейбук | `failed_when` | 4 |
| Мало свободной памяти | **да** | остановить с понятным текстом | `fail` + `when` | 4 |
| Smoke-тест после деплоя упал | **да** | откатиться и снять lock | `block`/`rescue`/`always` | 5 |
| Не переданы параметры запуска | **да** | упасть до первого изменения | `assert` | 6 |
| Прод без change-тикета | **да** | заблокировать деплой | `fail` + `when` | 6 |
