# Homework: Ansible — Шаг 1 (Docker Desktop). Установка Ansible и подключение по SSH к двум нодам (Ubuntu и CentOS)

> То же задание («Установить Ansible и подключиться по SSH к двум нодам на разных ОС — Ubuntu и CentOS»), адаптированное под локальный **Docker Desktop на Windows** вместо Killercoda.
> Идея та же: control node с Ansible + две ноды (Ubuntu, CentOS-совместимая) — только все три контейнера теперь поднимаются на локальной машине, а не в браузерной песочнице.
> Команды идут в двух видах, помечены явно:
> - **[Host / PowerShell]** — выполняется на самом Windows-хосте, где работает Docker Desktop
> - **[Container / bash]** — выполняется внутри контейнера `ansible-control` (после `docker exec -it ansible-control bash`)

---

## 1.0 Предпосылки

**[Host / PowerShell]**
```powershell
docker version
```

> Комментарий: убеждаемся, что Docker Desktop запущен и `docker` CLI доступен из PowerShell — команда должна показать и `Client`, и `Server` секции. Если `Server` пустой/недоступен — Docker Desktop не запущен.

---

## 1.1 Изолированная Docker-сеть для трёх контейнеров

**[Host / PowerShell]**
```powershell
docker network create ansible-net
```

> Комментарий: в Killercoda-варианте пришлось вручную искать IP через `docker inspect`, потому что использовалась дефолтная `bridge`-сеть, у которой нет встроенного DNS между контейнерами. User-defined сеть (созданная через `docker network create`) в Docker Desktop даёт встроенный DNS — контейнеры на ней резолвят друг друга **по имени** (`node1-ubuntu`, `node2-centos`), IP-адреса вообще не понадобятся.

---

## 1.2 Control-node контейнер с Ansible

**[Host / PowerShell]**
```powershell
docker run -d --name ansible-control --hostname ansible-control --network ansible-net ubuntu:22.04 sleep infinity
docker exec ansible-control bash -c "apt-get update && apt-get install -y ansible openssh-client python3 curl"
```

> Комментарий: Ansible нативно не работает на Windows, поэтому control node тоже поднимается как Linux-контейнер (проще и переносимее, чем настраивать WSL под это). `sleep infinity` — тот же приём, что и в Killercoda-варианте: процесс-заглушка вместо отсутствующего в контейнере init/systemd, чтобы контейнер не завершался сразу после старта. `curl` ставится сразу — понадобится на Шаге 2 для проверки страниц Nginx изнутри `ansible-control` (по умолчанию в минимальном образе Ubuntu его нет).

---

## 1.3 Две ноды — Ubuntu и CentOS-совместимая (Rocky) — с портами для будущего Nginx

**[Host / PowerShell]**
```powershell
docker run -d --name node1-ubuntu --hostname node1-ubuntu --network ansible-net -p 18080:8080 ubuntu:22.04 sleep infinity
docker exec node1-ubuntu bash -c "apt-get update && apt-get install -y openssh-server sudo python3"
docker exec node1-ubuntu mkdir -p /run/sshd
```

```powershell
docker run -d --name node2-centos --hostname node2-centos --network ansible-net -p 8081:8081 rockylinux:9 sleep infinity
docker exec node2-centos bash -c "dnf install -y openssh-server python3 sudo"
docker exec node2-centos ssh-keygen -A
```

> Комментарий:
> - `-p 18080:8080` / `-p 8081:8081` пробрасывают порты **сразу при создании контейнера** — правая часть (`8080`/`8081`) это те же порты, которые займёт Nginx на Шаге 2 (`host_vars.http_port`), левая часть — порт на самом хосте. На Docker Desktop страницы будут доступны прямо на `http://localhost:18080` / `http://localhost:8081` в браузере Windows — в отличие от Killercoda, где для этого пришлось городить `socat` + панель Traffic.
> - Хостовый порт `18080` (а не `8080`) выбран потому, что `8080` уже занят другим процессом на этой машине (`Get-NetTCPConnection -LocalPort 8080` показал слушающий `java`-процесс) — если у вас `8080` свободен, можно использовать `-p 8080:8080` как обычно, ничего в остальных шагах/шаблонах менять не придётся: `http_port: 8080` в `host_vars` — это порт **внутри** контейнера, к внешнему пробросу не привязан.
> - Официальный образ `centos` сейчас практически бесполезен (репозитории CentOS Linux 8- остановлены, `mirrorlist.centos.org` не отвечает) — используется `rockylinux:9`, бинарно совместимый преемник (тот же `dnf`, тот же `ansible_os_family: RedHat`).
> - `ssh-keygen -A` генерирует SSH host-ключи — в минимальном образе Rocky они не создаются автоматически при установке пакета (в отличие от Ubuntu, где это делает postinst-скрипт `apt`).

---

Дальше всё выполняется **внутри** контейнера `ansible-control`:

**[Host / PowerShell]**
```powershell
docker exec -it ansible-control bash
```

> Комментарий: после этой команды приглашение в терминале сменится на что-то вроде `root@ansible-control:/#` — вы внутри Linux-контейнера, все следующие команды (кроме отдельно помеченных `[Host / PowerShell]`) выполняются там, один в один как в обычном Linux-терминале.

---

## 1.4 Генерация SSH-ключа на control node

**[Container / bash]**
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

> Комментарий: `-N ""` — пустая passphrase, чтобы Ansible мог подключаться без интерактивного ввода пароля к ключу.

---

## 1.5 Копирование публичного ключа в обе ноды и запуск sshd

Контейнер `ansible-control` не имеет доступа к Docker-сокету (он не смонтирован), поэтому `docker cp`/`docker exec` для других контейнеров нельзя вызвать изнутри него — эта часть выполняется **с хоста**. `docker cp` также не умеет копировать напрямую между двумя контейнерами (`container:path → container:path` не поддерживается), поэтому ключ сначала выгружается на хост, а затем раскладывается по нодам:

**[Host / PowerShell]** *(открыть отдельное окно PowerShell, не закрывая сессию `ansible-control`)*
```powershell
docker cp ansible-control:/root/.ssh/id_rsa.pub .\id_rsa.pub

foreach ($c in @("node1-ubuntu","node2-centos")) {
  docker exec $c mkdir -p /root/.ssh
  docker exec $c chmod 700 /root/.ssh
  docker cp .\id_rsa.pub "${c}:/root/.ssh/authorized_keys"
  docker exec $c chmod 600 /root/.ssh/authorized_keys
  docker exec -d $c /usr/sbin/sshd -D
}
```

> Комментарий: `docker exec -d ... sshd -D` запускает `sshd` в контейнере в фоне; флаг `-D` держит процесс на переднем плане (не даёт ему самому демонизироваться через двойной fork) — так надёжнее в контейнерной среде без своего init. Это единственный шаг всего Шага 1, который обязательно выполняется на хосте, а не внутри `ansible-control`.
>
> **Важно про порядок**: `mkdir`/`chmod 700 /root/.ssh` должны выполняться **внутри** `foreach` — с конкретным `$c` для каждого контейнера — и **до** `docker cp` в `authorized_keys`. Если `$c` не определён (команда вызвана вне цикла) или права на `.ssh`/`authorized_keys` не выставлены как `700`/`600`, `sshd` молча игнорирует публичный ключ и откатывается на запрос пароля — а пароль root в этих образах не задан, так что зайти всё равно не получится. Именно так выглядит симптом: `ssh` вместо мгновенного подключения показывает `password:`.

---

## 1.6 Проверка SSH-подключения по именам контейнеров (без IP)

Вернуться в сессию `ansible-control` (если закрылась — `docker exec -it ansible-control bash`):

**[Container / bash]**
```bash
ssh-keyscan -H node1-ubuntu node2-centos >> ~/.ssh/known_hosts
```

```bash
ssh root@node1-ubuntu "hostname && cat /etc/os-release | head -1"
ssh root@node2-centos "hostname && cat /etc/os-release | head -1"
```

> Комментарий: благодаря user-defined сети `ansible-net` (см. 1.1) ноды доступны прямо по именам контейнеров — Docker Desktop резолвит их через встроенный DNS. Никакого `docker inspect`/переменных с IP не требуется — в этом главное отличие и упрощение по сравнению с Killercoda-версией. Подключение должно проходить без пароля (ключ уже в `authorized_keys`), вывод должен подтвердить: `node1-ubuntu` — Ubuntu, `node2-centos` — RedHat-совместимая ОС (Rocky Linux).

---

## 1.7 Быстрая проверка связи через Ansible ad-hoc (модуль ping)

**[Container / bash]**
```bash
cat <<EOF > /tmp/test_inventory.ini
node1-ubuntu ansible_host=node1-ubuntu ansible_user=root
node2-centos ansible_host=node2-centos ansible_user=root
EOF
```

```bash
ansible all -i /tmp/test_inventory.ini -m ping
```

> Комментарий: `ansible_host=node1-ubuntu` — это тоже имя контейнера, а не IP (см. 1.6). Модуль `ping` проверяет, что Ansible может подключиться по SSH, аутентифицироваться и выполнить Python на хосте. Успешный ответ — `"ping": "pong"` для обеих нод.

---

## Итог шага 1

- [ ] Docker Desktop запущен, `docker version` отвечает
- [ ] Создана изолированная сеть `ansible-net` с DNS-резолвингом по именам контейнеров
- [ ] Поднят control-node контейнер `ansible-control` с установленным Ansible
- [ ] Подняты две ноды (`node1-ubuntu`, `node2-centos` на базе Rocky Linux) с портами 18080→8080 / 8081→8081, проброшенными на хост
- [ ] Сгенерирован SSH-ключ внутри `ansible-control`
- [ ] Публичный ключ скопирован в обе ноды (через хост, т.к. `ansible-control` не имеет доступа к Docker-сокету), `sshd` запущен в обоих контейнерах
- [ ] SSH-подключение к обеим нодам работает без пароля, **по именам контейнеров**, без IP-адресов
- [ ] `ansible ... -m ping` вернул `pong` для обеих нод

> Далее (Шаг 2 задания) — оформление постоянного `inventory.ini` с группами `[ubuntu]`/`[centos]` и раскладка файлов проекта по папкам (`group_vars`, `host_vars`, `templates`, плейбук) — см. `02-nginx-templates-deploy.md` в этой же папке.
