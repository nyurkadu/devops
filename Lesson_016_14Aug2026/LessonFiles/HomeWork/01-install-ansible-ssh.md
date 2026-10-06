# Homework: Ansible — Шаг 1. Установка Ansible на Killercoda и подключение по SSH к двум нодам (Ubuntu и CentOS)

> Задание: «Установить Ansible на Killercoda и подключиться по SSH к двум нодам на разных ОС (Ubuntu и CentOS)».
> Ниже — план команд, которые выполняются в терминале Killercoda (control node), с комментариями к каждому шагу.
> Команды выполняются в самом Killercoda (внешняя браузерная песочница), не в этой рабочей директории — файл фиксирует их как runbook/лог.

---

## 1.1 Проверка, установлен ли Ansible на control node

```bash
ansible --version
```

> Комментарий: на многих сценариях Killercoda (например, "Ansible Playground") Ansible уже предустановлен на control node. Эта команда — первая проверка, чтобы не ставить лишний раз.

Если команда не найдена — устанавливаем (control node в Killercoda обычно на базе Ubuntu/Debian):

```bash
sudo apt update
sudo apt install -y ansible
```

> Комментарий: `apt update` обновляет индекс пакетов перед установкой, `-y` — автоподтверждение, чтобы команда не блокировалась интерактивным запросом.

Альтернатива через pip (если пакет apt устарел или отсутствует):

```bash
sudo apt install -y python3-pip
pip3 install --user ansible
```

> Комментарий: pip-путь ставит более свежую версию Ansible, но требует, чтобы `~/.local/bin` был в `PATH`.

---

## 1.2 Определение доступных нод в сценарии Killercoda

```bash
cat /etc/hosts
```

Вывод:
```
127.0.0.1 localhost

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
127.0.0.1 ubuntu
127.0.0.1 host01
172.30.1.2 local-registry
```

```bash
ping -c 1 node01
```

Вывод:
```
ping: node01: Name or service not known
```

> Комментарий: изначальное предположение о хостнеймах `node01`/`node02` не подтвердилось — в `/etc/hosts` этой Killercoda-сессии нет отдельных нод, есть только сам control node (`ubuntu`/`host01`, оба указывают на `127.0.0.1`, то есть это одна и та же машина) и `local-registry`. Значит выбранный сценарий Killercoda — однонодовый (например, обычный "Ubuntu Playground"), а не готовый multi-node Ansible-сценарий с предустановленными Ubuntu- и CentOS-нодами. Для задания нужны ещё два отдельных хоста (Ubuntu и CentOS) — их предстоит поднять отдельно (см. ниже).

Проверка ОС на каждой ноде (если доступ уже есть, например, через встроенный в сценарий Killercoda беспарольный SSH):

```bash
ssh node01 "cat /etc/os-release"
ssh node02 "cat /etc/os-release"
```

> Комментарий: важно заранее убедиться, какая нода Ubuntu, а какая CentOS — это понадобится дальше для group_vars/host_vars и условной установки Nginx через apt/yum.

---

## 1.3 Поднятие двух нод (Ubuntu и CentOS-совместимая) через Docker-контейнеры

Раз сценарий Killercoda однонодовый, а Docker на control node уже есть (виден `local-registry` в `/etc/hosts`), две "ноды" поднимаются как Docker-контейнеры с работающим `sshd` — Ansible работает с ними по SSH точно так же, как с полноценными VM.

```bash
docker --version
```

> Комментарий: подтверждаем, что Docker доступен на control node, прежде чем поднимать контейнеры.

### Ubuntu-нода

```bash
docker run -d --name node1-ubuntu --hostname node1-ubuntu ubuntu:22.04 sleep infinity
docker exec node1-ubuntu bash -c "apt-get update && apt-get install -y openssh-server sudo python3"
docker exec node1-ubuntu mkdir -p /run/sshd
```

> Комментарий: `sleep infinity` — процесс-заглушка (PID 1), чтобы контейнер не завершался сразу после старта (в нём нет своего init/systemd). `openssh-server` нужен для SSH-доступа, `python3` — обязательное условие для выполнения модулей Ansible на управляемом хосте (кроме `raw`/`command`), `/run/sshd` — каталог, которого не хватает у sshd в минимальном образе.

### CentOS-совместимая нода

```bash
docker run -d --name node2-centos --hostname node2-centos rockylinux:9 sleep infinity
docker exec node2-centos bash -c "dnf install -y openssh-server python3 sudo"
docker exec node2-centos ssh-keygen -A
```

> Комментарий: официальный образ `centos` сейчас практически бесполезен — репозитории CentOS Linux (8 и ниже) остановлены, `mirrorlist.centos.org` не отвечает, и `yum install` в чистом образе `centos:7/8` падает без ручной правки на `vault.centos.org`. Поэтому вместо него используется `rockylinux:9` — прямой бинарно-совместимый преемник CentOS (тот же `dnf`/`yum`, тот же `ansible_os_family: RedHat`, та же логика `{% if ansible_os_family == "RedHat" %}` в шаблонах), что и требуется по заданию. Если нужен именно образ `centos:7` — можно заменить на него и добавить в контейнере `sed -i 's/mirrorlist/#mirrorlist/; s|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/*.repo` перед `yum install`. `ssh-keygen -A` генерирует host-ключи SSH — в минимальном образе они не создаются автоматически при установке пакета (в отличие от Ubuntu, где это делает postinst-скрипт apt).

---

## 1.4 Генерация SSH-ключа на control node

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

> Комментарий: `-t rsa -b 4096` — тип и длина ключа, `-f` — путь к файлу ключа, `-N ""` — пустая passphrase, чтобы Ansible мог подключаться без интерактивного ввода пароля к ключу.

---

## 1.5 Копирование публичного ключа в обе ноды и запуск sshd

Контейнеры не имеют пароля root и `ssh-copy-id` использовать не по чему (SSH ещё не запущен) — ключ кладётся напрямую в файловую систему контейнера через `docker cp`/`docker exec`:

```bash
for c in node1-ubuntu node2-centos; do
  docker exec "$c" mkdir -p /root/.ssh
  docker exec "$c" chmod 700 /root/.ssh
  docker cp ~/.ssh/id_rsa.pub "$c":/root/.ssh/authorized_keys
  docker exec "$c" chmod 600 /root/.ssh/authorized_keys
  docker exec -d "$c" /usr/sbin/sshd -D
done
```

> Комментарий: `docker cp` копирует публичный ключ прямо в `authorized_keys` контейнера, минуя сеть — эквивалент того, что делает `ssh-copy-id`, но без необходимости в пароле. `docker exec -d ... sshd -D` запускает `sshd` в контейнере в фоне; флаг `-D` держит процесс на переднем плане (не даёт ему самому демонизироваться через двойной fork), что надёжнее работает в контейнерной среде без своего init.

---

## 1.6 Определение IP-адресов нод и проверка SSH-подключения

```bash
NODE1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' node1-ubuntu)
NODE2_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' node2-centos)
echo "node1-ubuntu: $NODE1_IP"
echo "node2-centos: $NODE2_IP"
```

> Комментарий: контейнеры на стандартной Docker-сети (`bridge`) получают собственный IP, доступный напрямую с control node (хоста) — проброс портов не нужен, SSH идёт на порт 22 контейнера напрямую по этому IP. В этой Killercoda-сессии прямой путь `{{.NetworkSettings.IPAddress}}` падает с ошибкой `map has no entry for key "IPAddress"` — поле пустое/отсутствует на верхнем уровне, а IP лежит вложенно в `NetworkSettings.Networks.<имя-сети>`. Поэтому используется `{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}`, который проходит по всем подключённым сетям контейнера и не зависит от конкретного имени сети (в отличие от, например, `{{.NetworkSettings.Networks.bridge.IPAddress}}`).

```bash
ssh-keyscan -H "$NODE1_IP" "$NODE2_IP" >> ~/.ssh/known_hosts
```

> Комментарий: заранее добавляет host-ключи обеих нод в `known_hosts`, чтобы первое SSH/Ansible-подключение не зависало на интерактивном вопросе `Are you sure you want to continue connecting (yes/no)?`.

```bash
ssh root@"$NODE1_IP" "hostname && cat /etc/os-release | head -1"
ssh root@"$NODE2_IP" "hostname && cat /etc/os-release | head -1"
```

> Комментарий: финальная проверка — подключение должно проходить без пароля (ключ уже в `authorized_keys`), и вывод должен подтвердить, что node1-ubuntu — Ubuntu, node2-centos — RedHat-совместимая ОС (Rocky Linux).

---

## 1.7 Быстрая проверка связи через Ansible ad-hoc (модуль ping)

Минимальный временный inventory для проверки (полноценный `inventory.ini` с группами `[ubuntu]`/`[centos]` будет создан на Шаге 2 задания):

```bash
cat <<EOF > /tmp/test_inventory.ini
node1-ubuntu ansible_host=$NODE1_IP ansible_user=root
node2-centos ansible_host=$NODE2_IP ansible_user=root
EOF
```

```bash
ansible all -i /tmp/test_inventory.ini -m ping
```

> Комментарий: модуль `ping` в Ansible — это не ICMP-пинг, а проверка того, что Ansible может подключиться по SSH к хосту, аутентифицироваться и выполнить на нём Python. Успешный ответ — `"ping": "pong"` для обеих нод — подтверждает, что Ansible готов к дальнейшей работе с обоими хостами (Ubuntu и CentOS-совместимая Rocky Linux).

---

## Итог шага 1

- [ ] Ansible установлен и доступен на control node Killercoda (`ansible --version`)
- [ ] Подняты две ноды разных ОС через Docker (`node1-ubuntu`, `node2-centos` на базе Rocky Linux)
- [ ] Сгенерирован SSH-ключ на control node
- [ ] Публичный ключ скопирован в обе ноды (`docker cp` в `authorized_keys`), `sshd` запущен в обоих контейнерах
- [ ] SSH-подключение к обеим нодам работает без пароля
- [ ] `ansible ... -m ping` вернул `pong` для обеих нод

> Далее (Шаг 2 задания) — оформление постоянного `inventory.ini` с группами `[ubuntu]`/`[centos]` и раскладка файлов проекта по папкам (`group_vars`, `host_vars`, `templates`, `roles`/плейбуки).
