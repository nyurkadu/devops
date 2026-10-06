# Ноды `node3` и `node4` под управлением `ansible-control`

**Задача:** поднять две ноды на Ubuntu 22.04 и поставить их под управление
уже существующего контейнера-контроллера `ansible-control` (в нём есть
`ansible`, `ansible-vault` и SSH-ключ `/root/.ssh/id_rsa`).

Каталог работы: `Lesson_019_25Aug2026/LessonFiles/HomeWork`

> **Все команды в этом документе — PowerShell 7 (`pwsh`), выполняются на хосте Windows.**
> Сам Ansible под Windows не работает, поэтому он всегда запускается внутри
> Linux-контейнера, а PowerShell выступает управляющей оболочкой:
> создаёт файлы, дёргает `docker` и разбирает вывод.
>
> Два правила PowerShell, о которые чаще всего спотыкаются:
>
> * bash-циклы `for c in a b; do ... done` не существуют — вместо них `foreach ($c in 'a','b') { ... }`;
> * закрывающая кавычка here-string `'@` должна стоять **в самом начале строки**, без отступа, иначе получите `ParserError`.

---

## Установка и настройка

Обе ноды — на **Ubuntu 22.04**, управляются по SSH из уже существующего
контейнера-контроллера `ansible-control` (в нём есть `ansible`, `ansible-vault`
и ключ `/root/.ssh/id_rsa`).

### 1. Создать контейнеры-ноды

```powershell
docker run -d --name node3 --hostname node3 --network ansible-net ubuntu:22.04 sleep infinity
docker run -d --name node4 --hostname node4 --network ansible-net ubuntu:22.04 sleep infinity
```

**Что делает:**

* `-d` — запуск в фоне; `--name`/`--hostname` — имя контейнера и его hostname (по нему нода будет видна в инвентаре).
* `--network ansible-net` — та же пользовательская сеть, в которой уже находится `ansible-control`. Это ключевой момент: в user-defined сети Docker даёт встроенный DNS, поэтому контроллер обращается к нодам просто по именам `node3`/`node4`, без IP-адресов (на дефолтной сети `bridge` такого DNS нет).
* `sleep infinity` — процесс-заглушка в роли PID 1. В образе `ubuntu:22.04` нет своего init/systemd, и без долгоживущего процесса контейнер завершился бы сразу после старта.

Проверка сети:

```powershell
docker network inspect ansible-net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}'
```

Ожидаем увидеть три записи: `ansible-control`, `node3`, `node4`.

### 2. Доставить на ноды то, что требует Ansible

```powershell
foreach ($c in 'node3','node4') {
  docker exec $c bash -c "apt-get update -qq && apt-get install -y -qq openssh-server python3 sudo"
  docker exec $c mkdir -p /run/sshd
}
```

**Что делает каждый пакет:**

* `openssh-server` — транспорт: Ansible будет подключаться по SSH (`ansible_connection=ssh`).
* `python3` — обязателен на управляемом узле: все модули Ansible (кроме `raw`/`command` в сыром виде) выполняются как Python-код прямо на ноде.
* `sudo` — нужен для `become: true`. Даже при подключении под `root` Ansible по умолчанию использует `sudo` как become-метод, и без пакета задача упадёт с `sudo: command not found`.
* `mkdir -p /run/sshd` — каталог privilege separation для `sshd`; в минимальном образе он не создаётся, и демон отказывается стартовать с ошибкой `Missing privilege separation directory`.

### 3. Разложить публичный ключ контроллера

```powershell
# 1. Забрать публичный ключ из ansible-control в переменную
$pub = docker exec ansible-control cat /root/.ssh/id_rsa.pub

# 2. Записать его в authorized_keys обеих нод
foreach ($c in 'node3','node4') {
  docker exec $c sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && printf '%s\n' '$pub' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
}
```

**Что делает:** это ручной эквивалент `ssh-copy-id`. Использовать сам `ssh-copy-id`
нельзя — у контейнеров нет пароля root, а `sshd` ещё даже не запущен.
Ключ передаётся через переменную и пишется на ноде командой `printf`, **минуя
файл на Windows-хосте**. Это принципиально: если сохранить ключ через
`Set-Content`, PowerShell запишет его с переводами строк CRLF, и `sshd` откажется
принимать такой `authorized_keys` — вход по ключу молча перестанет работать.

Права `700` на каталог и `600` на файл обязательны: при более широких правах
`sshd` тоже игнорирует `authorized_keys`.

> Если ключа в `ansible-control` нет, его нужно сначала создать:
>
> ```powershell
> docker exec ansible-control ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N '""'
> ```
>
> Пустая passphrase нужна, чтобы Ansible подключался без интерактивного ввода.

### 4. Запустить SSH-демон на нодах

```powershell
foreach ($c in 'node3','node4') { docker exec -d $c /usr/sbin/sshd -D }
```

**Что делает:** `docker exec -d` — запуск в фоне относительно вашего терминала;
`sshd -D` — не давать демону самому уходить в фон двойным fork'ом. В контейнере
без своего init такой «форграунд»-режим работает надёжнее: процесс остаётся
дочерним для контейнера и не теряется.

> **Важно:** это единственный шаг, который **не переживает перезапуск контейнера**.
> После `docker stop/start node3` нужно снова выполнить
> `docker exec -d node3 /usr/sbin/sshd -D` — пакеты и ключи сохраняются в слое
> контейнера, а запущенные процессы нет.

Проверка, что демон слушает:

```powershell
docker exec node3 ps aux | Select-String 'sshd' | Measure-Object -Line
```

### 5. Прописать ноды в `known_hosts` контроллера

```powershell
docker exec ansible-control sh -c 'ssh-keyscan -H node3 node4 >> /root/.ssh/known_hosts 2>/dev/null'
```

**Что делает:** заранее забирает host-ключи обеих нод и кладёт их в `known_hosts`.
Без этого первое подключение зависнет на интерактивном вопросе
`Are you sure you want to continue connecting (yes/no)?` — а Ansible на этот
вопрос отвечать некому, и play упадёт по таймауту. Флаг `-H` хеширует имена
хостов в файле (так же, как это делает сам ssh).

Перенаправление `>>` и `2>/dev/null` здесь выполняет `sh` **внутри контейнера**,
а не PowerShell — поэтому вся команда завёрнута в одинарные кавычки и передана
как один аргумент.

### 6. Проверить SSH-связность

```powershell
docker exec ansible-control ssh -o BatchMode=yes root@node3 'hostname; python3 -V'
docker exec ansible-control ssh -o BatchMode=yes root@node4 'hostname; python3 -V'
```

**Что делает:** `BatchMode=yes` запрещает любые интерактивные запросы (пароль,
подтверждение ключа). Если команда отработала и вернула `node3` / `Python 3.10.x` —
транспорт полностью готов; если запросила пароль, значит ключ не принят
(смотреть права на `/root/.ssh` и содержимое `authorized_keys`).

### 7. Инвентарь внутри `ansible-control`

Heredoc'ов в PowerShell нет, поэтому файл собирается одним `printf` внутри контейнера:

```powershell
docker exec ansible-control sh -c "mkdir -p /root/homework && printf '%s\n' '[webservers]' 'node3' 'node4' '' '[webservers:vars]' 'ansible_connection=ssh' 'ansible_user=root' 'ansible_python_interpreter=/usr/bin/python3' > /root/homework/inventory.ini"

# проверить результат
docker exec ansible-control cat /root/homework/inventory.ini
```

Должно получиться:

```ini
[webservers]
node3
node4

[webservers:vars]
ansible_connection=ssh
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
```

**Что делает:** описывает ту же группу `webservers`, что используется дальше по
инструкции, но с SSH-транспортом вместо `community.docker.docker`. Имя группы
менять нельзя — от него зависит путь `group_vars/webservers/`, откуда
подхватываются переменные и зашифрованный Vault.
`ansible_python_interpreter` задаётся явно, чтобы убрать предупреждение
про автоопределение интерпретатора.

### 8. Контрольная проверка через Ansible

```powershell
docker exec ansible-control ansible -i /root/homework/inventory.ini webservers -m ping
```

Ожидаемый вывод:

```text
node3 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
node4 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

`pong` от обеих нод означает, что работает вся цепочка: SSH-ключ, `sshd`,
`python3` на узле и разбор инвентаря. Только после этого имеет смысл переходить
к основной части задания.

### 9. Войти внутрь контроллера

Все предыдущие команды запускались снаружи, через `docker exec`. Когда работы
внутри много, удобнее один раз зайти в контейнер и дальше работать в его
собственной оболочке:

```powershell
docker exec -it ansible-control bash
```

**Что делает:** `-i` держит открытым stdin (иначе оболочка сразу увидит конец
ввода и завершится), `-t` выделяет псевдотерминал — без него не будет ни
приглашения `root@...#`, ни подсветки, ни обработки `Ctrl+C`. Именно поэтому
для интерактивного входа нужны **оба** флага, а для разовой команды — ни одного.

Внутри контейнера сразу переходим в каталог с инвентарём:

```bash
cd /root/homework
ansible -i inventory.ini webservers -m ping
ansible -i inventory.ini webservers -m shell -a 'uname -sr' -o
```

Обратите внимание: внутри контейнера это уже **bash**, а не PowerShell —
здесь работают привычные `for c in node3 node4; do ... done`, heredoc'и и `sed -i`.

Выйти обратно:

```bash
exit
```

> Выход из `bash` **не останавливает контейнер**: вы завершаете свою сессию
> оболочки, а не PID 1. `ansible-control` продолжает работать, что подтвердит
> `docker ps`.

Сравнение двух режимов:

| Режим | Команда | Когда применять |
|---|---|---|
| Разовый запуск | `docker exec ansible-control ansible -i /root/homework/inventory.ini webservers -m ping` | одна-две команды, скрипты, автоматизация |
| Интерактивный вход | `docker exec -it ansible-control bash` | отладка, серия команд, правка файлов внутри |

### 10. Подключить к тому же контроллеру node1 и node2 (необязательно)

Чтобы под тот же контроллер попали и `node1`/`node2`, их нужно подключить к сети
контроллера и доустановить SSH (они на `nginx:alpine`, пакетный менеджер — `apk`):

```powershell
foreach ($c in 'node1','node2') {
  docker network connect ansible-net $c
  docker exec $c apk add --no-cache openssh python3 sudo
  docker exec $c ssh-keygen -A          # в Alpine host-ключи не генерируются автоматически
  docker exec $c sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
}
# дальше — те же шаги 3-6 для node1/node2
```

### 11. Стенд постоянный: как поддерживать его в рабочем состоянии

`node3` и `node4` **не удаляются** — это постоянный учебный стенд. Команда
`docker rm -f node3 node4` в этом сценарии не применяется: она уничтожила бы
установленные пакеты и разложенные SSH-ключи, и всю подготовку (шаги 1-6)
пришлось бы делать заново.

**Что переживает перезапуск, а что нет:**

| Объект | Живёт в | Переживает `docker restart` | Переживает `docker rm` |
|---|---|---|---|
| `openssh-server`, `python3`, `sudo` | слой контейнера | да | нет |
| `/root/.ssh/authorized_keys` | слой контейнера | да | нет |
| запущенный процесс `sshd` | память | **нет** | нет |
| `known_hosts` в `ansible-control` | слой контроллера | да | — |

Отсюда единственное регулярное действие: **после каждого перезапуска нод
(или Docker Desktop) заново поднять `sshd`.**

#### Восстановление после перезапуска

```powershell
# 1. Поднять контейнеры, если они остановлены
docker start node3 node4

# 2. Заново запустить sshd (процессы не переживают рестарт)
foreach ($c in 'node3','node4') { docker exec -d $c /usr/sbin/sshd -D }

# 3. Убедиться, что контроллер снова их видит
docker exec ansible-control ansible -i /root/homework/inventory.ini webservers -m ping
```

#### Чтобы контейнеры поднимались сами

```powershell
docker update --restart unless-stopped node3 node4
```

**Что делает:** задаёт политику перезапуска уже созданным контейнерам —
после рестарта Docker Desktop или перезагрузки Windows они стартуют
автоматически. `unless-stopped` означает «поднимать всегда, кроме случая,
когда контейнер остановили вручную». Шаг 2 (запуск `sshd`) всё равно остаётся
за вами: политика перезапуска возвращает к жизни только PID 1
(`sleep infinity`), а не фоновые процессы внутри контейнера.

> Если когда-нибудь ноды всё же будут пересозданы, в `known_hosts` контроллера
> останется старый host-ключ, и SSH выдаст
> `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`. Лечится удалением записи:
> `docker exec ansible-control ssh-keygen -R node3 -f /root/.ssh/known_hosts`.
