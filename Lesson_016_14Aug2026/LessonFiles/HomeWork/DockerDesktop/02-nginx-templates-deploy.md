# Homework: Ansible — Шаг 2 (Docker Desktop). group_vars/host_vars, шаблоны Nginx и хэндлеры на двух ОС

> Задание (см. `home_work.txt`):
> - Вынести все настройки (порты, имена) в `group_vars`/`host_vars`, чтобы в самом плейбуке не было хардкода
> - Включить сбор фактов о системе (`ansible_facts`) и обновление кэша пакетов (`update_cache: yes`)
> - Написать установку Nginx так, чтобы для Ubuntu использовался `apt`, а для CentOS — `yum`/`dnf`
> - Сделать шаблон `templates/nginx.conf.j2` с динамическими переменными и условием `{% if ... %}`
> - Сделать шаблон `templates/index.html.j2` и вывести туда данные о сервере (IP, RAM, ОС) и список сервисов через цикл `{% for ... %}`
> - Настроить хэндлер (`notify`), чтобы Nginx перезапускался только если конфиг реально изменился
> - Запустить раскатку сразу на все ноды через один главный плейбук
> - Пробросить порты и открыть получившиеся странички в браузере
>
> Продолжение `01-install-ansible-ssh.md` (Docker Desktop-вариант): сеть `ansible-net`, контейнеры `ansible-control`, `node1-ubuntu`, `node2-centos` уже подняты, SSH работает, `ansible ... -m ping` отвечает `pong`.
>
> Все команды ниже — **[Container / bash]**, то есть выполняются внутри `ansible-control` (`docker exec -it ansible-control bash`), кроме финального шага открытия страниц в браузере — он на хосте.

---

## 2.1 Структура проекта

**[Container / bash]**
```bash
mkdir -p ~/ansible-nginx-demo/{group_vars,host_vars,templates}
cd ~/ansible-nginx-demo
```

```
ansible-nginx-demo/
├── inventory.ini
├── group_vars/
│   ├── all.yml
│   ├── ubuntu.yml
│   └── centos.yml
├── host_vars/
│   ├── node1-ubuntu.yml
│   └── node2-centos.yml
├── templates/
│   ├── nginx.conf.j2
│   └── index.html.j2
└── site.yml
```

---

## 2.2 inventory.ini с группами `[ubuntu]`/`[centos]`

**[Container / bash]**
```bash
cat <<EOF > inventory.ini
[ubuntu]
node1-ubuntu ansible_host=node1-ubuntu ansible_user=root

[centos]
node2-centos ansible_host=node2-centos ansible_user=root

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
```

> Комментарий: `ansible_host` — имя контейнера, не IP (сеть `ansible-net` резолвит их сама, см. Шаг 1). В Killercoda-версии этого шага IP приходилось подставлять из переменных `$NODE1_IP`/`$NODE2_IP`, полученных через `docker inspect` — здесь этот шаг просто не нужен.

---

## 2.3 group_vars — общие настройки и настройки по ОС

**[Container / bash]**
```bash
cat <<EOF > group_vars/all.yml
app_name: "Ansible Nginx Demo"
services_list:
  - nginx
  - sshd
EOF
```

```bash
cat <<EOF > group_vars/ubuntu.yml
nginx_package: nginx
EOF
```

```bash
cat <<EOF > group_vars/centos.yml
nginx_package: nginx
EOF
```

> Комментарий: `nginx_package` вынесен по группам на случай, если для одной из ОС понадобится другое имя пакета — тогда меняется только `group_vars`-файл, а не плейбук.

---

## 2.4 host_vars — настройки конкретной ноды (порт)

**[Container / bash]**
```bash
cat <<EOF > host_vars/node1-ubuntu.yml
http_port: 8080
EOF
```

```bash
cat <<EOF > host_vars/node2-centos.yml
http_port: 8081
EOF
```

> Комментарий: `http_port: 8080` — это порт **внутри** контейнера node1-ubuntu (то, что слушает nginx), не путать с портом на хосте. В Шаге 1 контейнер был опубликован как `-p 18080:8080` (хостовый `8080` был занят другим процессом), поэтому снаружи страница будет на `http://localhost:18080`, а `http_port` в этом файле остаётся `8080` без изменений. Для `node2-centos` хостовый и внутренний порт совпадают (`-p 8081:8081`), поэтому здесь без разночтений.

---

## 2.5 templates/nginx.conf.j2 — динамические переменные и `{% if %}`

**[Container / bash]**
```bash
cat <<'EOF' > templates/nginx.conf.j2
user {% if ansible_os_family == "Debian" %}www-data{% else %}nginx{% endif %};
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    server {
        listen {{ http_port }};
        server_name {{ inventory_hostname }};

        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
EOF
```

> Комментарий: директива `user` в конфиге nginx на Debian/Ubuntu по умолчанию `www-data`, а на RedHat-семействе (CentOS/Rocky) — `nginx`; неверное значение не даст nginx стартовать. Условие `{% if ansible_os_family == "Debian" %}...{% else %}...{% endif %}` решает это без дублирования файла на две ОС. `{{ http_port }}` берётся из `host_vars` — порт не захардкожен ни в шаблоне, ни в плейбуке.

---

## 2.6 templates/index.html.j2 — данные о сервере и список сервисов через `{% for %}`

**[Container / bash]**
```bash
cat <<'EOF' > templates/index.html.j2
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>{{ app_name }} — {{ inventory_hostname }}</title>
</head>
<body>
    <h1>{{ app_name }}</h1>
    <h2>{{ inventory_hostname }}</h2>

    <ul>
        <li><strong>IP:</strong> {{ ansible_default_ipv4.address | default('n/a') }}</li>
        <li><strong>OS:</strong> {{ ansible_distribution }} {{ ansible_distribution_version }} ({{ ansible_os_family }})</li>
        <li><strong>RAM total:</strong> {{ ansible_memtotal_mb }} MB</li>
    </ul>

    <h3>Services</h3>
    <ul>
    {% for svc in services_list %}
        <li>{{ svc }}</li>
    {% endfor %}
    </ul>
</body>
</html>
EOF
```

> Комментарий: `ansible_default_ipv4`, `ansible_distribution`, `ansible_distribution_version`, `ansible_os_family`, `ansible_memtotal_mb` — факты (`ansible_facts`), собранные при подключении к ноде; без `gather_facts: yes` в плейбуке (см. 2.7) они будут пустыми. Здесь `ansible_default_ipv4.address` покажет внутренний IP контейнера в сети `ansible-net` (например, `172.x.x.x`) — это ожидаемо, снаружи (с хоста) страница всё равно открывается по `localhost:<порт>` благодаря `-p` из Шага 1.

---

## 2.7 Главный плейбук site.yml

**[Container / bash]**
```bash
cat <<'EOF' > site.yml
---
- name: Deploy Nginx on all nodes (Ubuntu via apt, CentOS/Rocky via dnf)
  hosts: all
  become: true
  gather_facts: yes

  tasks:
    - name: Update apt cache (Debian/Ubuntu)
      ansible.builtin.apt:
        update_cache: yes
      when: ansible_os_family == "Debian"

    - name: Install EPEL repo (RedHat family, needed for nginx package)
      ansible.builtin.dnf:
        name: epel-release
        state: present
      when: ansible_os_family == "RedHat" or ansible_distribution == "Rocky"

    - name: Update dnf cache (RedHat/CentOS)
      ansible.builtin.dnf:
        update_cache: yes
      when: ansible_os_family == "RedHat" or ansible_distribution == "Rocky"

    - name: Install Nginx on Debian/Ubuntu
      ansible.builtin.apt:
        name: "{{ nginx_package }}"
        state: present
      when: ansible_os_family == "Debian"

    - name: Install Nginx on RedHat/CentOS
      ansible.builtin.dnf:
        name: "{{ nginx_package }}"
        state: present
      when: ansible_os_family == "RedHat" or ansible_distribution == "Rocky"

    - name: Deploy nginx.conf from template
      ansible.builtin.template:
        src: templates/nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        owner: root
        group: root
        mode: "0644"
      notify: Restart nginx

    - name: Deploy index.html from template
      ansible.builtin.template:
        src: templates/index.html.j2
        dest: /usr/share/nginx/html/index.html
        owner: root
        group: root
        mode: "0644"

    - name: Start Nginx master process (no systemd in container, start once)
      ansible.builtin.command: nginx
      args:
        creates: /run/nginx.pid

  handlers:
    - name: Restart nginx
      ansible.builtin.command: nginx -s reload
EOF
```

> Комментарий:
> - `gather_facts: yes` — явно включённый сбор фактов, от него зависят `ansible_os_family`, `ansible_distribution` и т.д. в шаблонах.
> - Установка идёт через `ansible.builtin.apt` на Debian-семействе и `ansible.builtin.dnf` на RedHat-семействе, имя пакета берётся из `{{ nginx_package }}` (`group_vars`) — в плейбуке нет ни одного хардкод-имени пакета или порта.
> - Ноды — голые Docker-контейнеры без systemd/init (`sleep infinity` как PID 1, см. Шаг 1), поэтому `ansible.builtin.service`/`systemd` здесь не сработает. Nginx стартует напрямую командой `nginx` (сам демонизируется), `creates: /run/nginx.pid` не даёт перезапускать процесс на каждом прогоне.
> - Хэндлер `Restart nginx` подписан на задачу `template` через `notify` и по умолчанию выполняется **только если задача сообщила `changed`** (конфиг реально изменился) — это и есть требуемое поведение из задания. `nginx -s reload` перечитывает конфиг без даунтайма.
> - Условие `when: ansible_os_family == "RedHat" or ansible_distribution == "Rocky"` (а не просто `== "RedHat"`) — обходной путь для конкретной версии Ansible: `apt install -y ansible` на Ubuntu 22.04 ставит **Ansible 2.10.8** (2020 год), выпущенный до появления Rocky Linux (сер. 2021). Его таблица `DISTRIBUTION_FAMILY_MAP` не знает про Rocky и reportит `ansible_os_family: "Rocky"` вместо ожидаемого `"RedHat"` — из-за этого все задачи с `when: ansible_os_family == "RedHat"` молча пропускаются (`skipping`, не `failed`) на `node2-centos`, nginx не ставится, а следующая по списку задача `template` падает с `Destination directory /etc/nginx does not exist`. Проверить факт можно так: `ansible node2-centos -i inventory.ini -m setup -a "filter=ansible_os_family"`. Более новый Ansible (`pip3 install --user ansible` вместо `apt`) отражает Rocky как `RedHat` корректно и в этом обходном пути не нуждается — но `or ansible_distribution == "Rocky"` работает в обоих случаях, поэтому оставлен как есть.

---

## 2.8 Запуск плейбука сразу на все ноды

**[Container / bash]**
```bash
ansible-playbook -i inventory.ini site.yml
```

Проверка изнутри `ansible-control`:

```bash
curl -s http://node1-ubuntu:8080 | head -20
curl -s http://node2-centos:8081 | head -20
```

---

## 2.9 Открытие страниц в браузере (с хоста, без проброса — уже есть)

Порты уже опубликованы на хост при создании контейнеров в Шаге 1 (`-p 18080:8080`, `-p 8081:8081`), поэтому дополнительный проброс (как `socat` в Killercoda-версии) не нужен.

**[Host / PowerShell]**
```powershell
curl.exe http://localhost:18080
curl.exe http://localhost:8081
```

Или просто открыть в браузере Windows:
- `http://localhost:18080` — `node1-ubuntu` (Ubuntu, `www-data`, apt-путь установки)
- `http://localhost:8081` — `node2-centos` (Rocky Linux, `nginx`-пользователь, dnf-путь установки)

Каждая страница должна показывать свой хостнейм, внутренний IP контейнера, ОС, RAM и список сервисов (`nginx`, `sshd`).

---

## Итог шага 2

- [ ] `inventory.ini` с группами `[ubuntu]`/`[centos]` создан, `ansible_host` указывает на имена контейнеров (без IP)
- [ ] Настройки (порты, имена пакетов, список сервисов) вынесены в `group_vars`/`host_vars`, в `site.yml` нет хардкода
- [ ] `gather_facts: yes` включён, `update_cache: yes` выполняется отдельными задачами по ОС
- [ ] Nginx ставится через `apt` на Ubuntu и через `dnf` на CentOS-совместимой ноде
- [ ] `templates/nginx.conf.j2` использует переменные (`http_port`, `inventory_hostname`) и условие `{% if ansible_os_family == "Debian" %}`
- [ ] `templates/index.html.j2` выводит IP/RAM/ОС ноды и список сервисов через `{% for svc in services_list %}`
- [ ] Хэндлер `notify: Restart nginx` перезапускает (`reload`) Nginx только при реальном изменении конфига
- [ ] `ansible-playbook -i inventory.ini site.yml` раскатывает конфигурацию сразу на обе ноды одним запуском
- [ ] Страницы открываются в браузере на `http://localhost:18080` и `http://localhost:8081` — порты были проброшены ещё при создании контейнеров (Шаг 1), без `socat`

> Далее (Шаг 3, бонус со звёздочкой) — Blue-Green deployment: переменная `active_color`, динамическое переключение upstream-порта в `nginx.conf.j2` и обновление без простоя сервиса — см. `03-blue-green-deploy.md` в этой же папке.
