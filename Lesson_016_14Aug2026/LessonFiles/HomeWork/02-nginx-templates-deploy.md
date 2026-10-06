# Homework: Ansible — Шаг 2. group_vars/host_vars, шаблоны Nginx и хэндлеры на двух ОС

> Задание (см. `home_work.txt`):
> - Вынести все настройки (порты, имена) в `group_vars`/`host_vars`, чтобы в самом плейбуке не было хардкода
> - Включить сбор фактов о системе (`ansible_facts`) и обновление кэша пакетов (`update_cache: yes`)
> - Написать установку Nginx так, чтобы для Ubuntu использовался `apt`, а для CentOS — `yum`/`dnf`
> - Сделать шаблон `templates/nginx.conf.j2` с динамическими переменными и условием `{% if ... %}`
> - Сделать шаблон `templates/index.html.j2` и вывести туда данные о сервере (IP, RAM, ОС) и список сервисов через цикл `{% for ... %}`
> - Настроить хэндлер (`notify`), чтобы Nginx перезапускался только если конфиг реально изменился
> - Запустить раскатку сразу на все ноды через один главный плейбук
> - Пробросить порты в Killercoda и открыть получившиеся странички в браузере
>
> Предполагается, что Шаг 1 (`01-install-ansible-ssh.md`) уже выполнен: контейнеры `node1-ubuntu` и `node2-centos` подняты, SSH-ключ разложен, `ansible ... -m ping` отвечает `pong` для обеих нод. Команды ниже выполняются там же — в терминале Killercoda (control node).

---

## 2.1 Структура проекта

```bash
mkdir -p ~/ansible-nginx-demo/{group_vars,host_vars,templates}
cd ~/ansible-nginx-demo
```

Итоговая структура:

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

> Комментарий: `group_vars/<имя_группы>.yml` применяется ко всем хостам группы из `inventory.ini`, `host_vars/<имя_хоста>.yml` — только к конкретному хосту и имеет более высокий приоритет. Это и есть механизм «настройки вне плейбука», который требует задание.

---

## 2.2 inventory.ini с группами `[ubuntu]`/`[centos]`

IP-адреса контейнеров могут отличаться от сессии к сессии (Docker выдаёт их динамически), поэтому подставляем текущие `$NODE1_IP`/`$NODE2_IP` из Шага 1:

```bash
cat <<EOF > inventory.ini
[ubuntu]
node1-ubuntu ansible_host=$NODE1_IP ansible_user=root

[centos]
node2-centos ansible_host=$NODE2_IP ansible_user=root

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
```

> Комментарий: группы `[ubuntu]`/`[centos]` — это то, к чему привязаны `group_vars/ubuntu.yml` и `group_vars/centos.yml`. Имя группы должно совпадать с именем файла в `group_vars/`.

---

## 2.3 group_vars — общие настройки и настройки по ОС

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

> Комментарий: `app_name` и `services_list` — общие для всех нод (идут в `all.yml`), `nginx_package` вынесен по группам на случай, если для одной из ОС понадобится другое имя пакета (например, `nginx-core`) — тогда меняется только соответствующий `group_vars`-файл, а не плейбук.

---

## 2.4 host_vars — настройки конкретной ноды (порт)

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

> Комментарий: порт сделан per-host (а не общий в `all.yml`), чтобы обе ноды можно было пробросить в Killercoda и открыть в браузере одновременно, без конфликта портов на control node (см. 2.10).

---

## 2.5 templates/nginx.conf.j2 — динамические переменные и `{% if %}`

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

> Комментарий: директива `user` в конфиге nginx на Debian/Ubuntu по умолчанию `www-data`, а на RedHat-семействе (CentOS/Rocky) — `nginx`; неверное значение не даст nginx стартовать. Условие `{% if ansible_os_family == "Debian" %}...{% else %}...{% endif %}` решает это без дублирования файла на две ОС. `{{ http_port }}` берётся из `host_vars` (см. 2.4) — порт не захардкожен ни в шаблоне, ни в плейбуке.

---

## 2.6 templates/index.html.j2 — данные о сервере и список сервисов через `{% for %}`

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

> Комментарий: `ansible_default_ipv4`, `ansible_distribution`, `ansible_distribution_version`, `ansible_os_family`, `ansible_memtotal_mb` — всё это факты (`ansible_facts`), собранные Ansible при подключении к ноде; без `gather_facts: yes` в плейбуке (см. 2.7) эти переменные будут пустыми. `{% for svc in services_list %}` проходит по списку из `group_vars/all.yml`.

---

## 2.7 Главный плейбук site.yml

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
      when: ansible_os_family == "RedHat"

    - name: Update dnf cache (RedHat/CentOS)
      ansible.builtin.dnf:
        update_cache: yes
      when: ansible_os_family == "RedHat"

    - name: Install Nginx on Debian/Ubuntu
      ansible.builtin.apt:
        name: "{{ nginx_package }}"
        state: present
      when: ansible_os_family == "Debian"

    - name: Install Nginx on RedHat/CentOS
      ansible.builtin.dnf:
        name: "{{ nginx_package }}"
        state: present
      when: ansible_os_family == "RedHat"

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
> - `gather_facts: yes` — явно включённый сбор фактов (пункт задания), от него зависят `ansible_os_family`, `ansible_distribution` и т.д. в шаблонах.
> - `update_cache: yes` вызывается отдельной задачей на каждой ветке ОС, а не как параметр внутри задачи установки — так проще ограничить её через `when` только нужной группой и не дублировать индекс пакетов там, где он не нужен.
> - Установка идёт через `ansible.builtin.apt` на Debian-семействе и `ansible.builtin.dnf` на RedHat-семействе — имя пакета берётся из `{{ nginx_package }}` (`group_vars`), в плейбуке нет ни одного хардкод-имени пакета или порта.
> - Ноды — это голые Docker-контейнеры без systemd/init (см. Шаг 1, `sleep infinity` как PID 1), поэтому модуль `ansible.builtin.service`/`systemd` здесь не сработает — нечем управлять юнитами. Вместо этого nginx стартует напрямую командой `nginx` (сам демонизируется, `creates: /run/nginx.pid` не даёт перезапускать процесс на каждом прогоне).
> - Хэндлер `Restart nginx` подписан на задачу `template` через `notify: Restart nginx` и по умолчанию в Ansible выполняется **только если задача реально сообщила `changed`** (то есть содержимое `/etc/nginx/nginx.conf` действительно изменилось) — это и есть требуемое поведение «перезапуск только при реальном изменении конфига», без дополнительной логики. `nginx -s reload` посылает мастер-процессу сигнал перечитать конфиг без даунтайма (в отличие от полного перезапуска).

---

## 2.8 Запуск плейбука сразу на все ноды

```bash
ansible-playbook -i inventory.ini site.yml
```

> Комментарий: один запуск плейбука раскатывает конфигурацию сразу на `node1-ubuntu` и `node2-centos` (`hosts: all` в `site.yml`), Ansible параллельно подключается по SSH к обеим нодам, определяет `ansible_os_family` через факты и выполняет нужную ветку задач на каждой.

Проверка локально с control node (пока без проброса портов):

```bash
curl -s http://$NODE1_IP:8080 | head -20
curl -s http://$NODE2_IP:8081 | head -20
```

---

## 2.9 Проброс портов в Killercoda и просмотр страниц в браузере

Порты Killercoda пробрасывает наружу с **control node**, а не с произвольного IP контейнера в `bridge`-сети — поэтому 8080/8081 сначала нужно перекинуть с control node на IP контейнеров через `socat`:

```bash
sudo apt install -y socat
socat TCP-LISTEN:8080,fork,reuseaddr TCP:$NODE1_IP:8080 &
socat TCP-LISTEN:8081,fork,reuseaddr TCP:$NODE2_IP:8081 &
```

> Комментарий: `socat TCP-LISTEN:8080,fork,reuseaddr TCP:$NODE1_IP:8080` слушает порт 8080 на control node и прозрачно перенаправляет каждое подключение на `$NODE1_IP:8080` (Nginx внутри `node1-ubuntu`). `fork` — обрабатывать каждое соединение в отдельном процессе, `reuseaddr` — не падать с "address already in use" при перезапуске. `&` уводит оба форвардера в фон, чтобы не занимать терминал.

Дальше — в самом Killercoda:

1. В верхней панели сценария найти кнопку/иконку **Traffic** (или «порт»/значок глобуса рядом с терминалом).
2. Добавить/выбрать порт **8080** — откроется страница `node1-ubuntu` (Ubuntu, `www-data`, apt-путь установки).
3. Аналогично добавить порт **8081** — откроется страница `node2-centos` (Rocky Linux, `nginx`-пользователь, dnf-путь установки).

Каждая страница должна показывать свой хостнейм, IP, ОС, RAM и список сервисов (`nginx`, `sshd`) — то, что подставил `index.html.j2` из фактов и `group_vars`.

---

## Итог шага 2

- [ ] `inventory.ini` с группами `[ubuntu]`/`[centos]` создан, IP подставлены из Шага 1
- [ ] Настройки (порты, имена пакетов, список сервисов) вынесены в `group_vars`/`host_vars`, в `site.yml` нет хардкода
- [ ] `gather_facts: yes` включён, `update_cache: yes` выполняется отдельными задачами по ОС
- [ ] Nginx ставится через `apt` на Ubuntu и через `dnf` на CentOS-совместимой ноде
- [ ] `templates/nginx.conf.j2` использует переменные (`http_port`, `inventory_hostname`) и условие `{% if ansible_os_family == "Debian" %}`
- [ ] `templates/index.html.j2` выводит IP/RAM/ОС ноды и список сервисов через `{% for svc in services_list %}`
- [ ] Хэндлер `notify: Restart nginx` перезапускает (`reload`) Nginx только при реальном изменении конфига
- [ ] `ansible-playbook -i inventory.ini site.yml` раскатывает конфигурацию сразу на обе ноды одним запуском
- [ ] Порты 8080/8081 проброшены на control node через `socat` и открыты в браузере через Killercoda Traffic

> Далее (Шаг 3, бонус со звёздочкой) — Blue-Green deployment: переменная `active_color`, динамическое переключение upstream-порта в `nginx.conf.j2` и обновление без простоя сервиса.
