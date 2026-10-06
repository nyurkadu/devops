# Homework: Ansible — Шаг 3 (⭐ бонус, Docker Desktop). Blue-Green deployment через `active_color`

> Задание (см. `home_work.txt`):
> ⭐️ Реализовать Blue-Green deployment через динамическую смену переменной активного цвета (`active_color`) и переключение портов upstream в шаблоне Nginx без простоя сервиса.
>
> Продолжение `02-nginx-templates-deploy.md` (Docker Desktop-вариант) — используется тот же проект `~/ansible-nginx-demo` внутри контейнера `ansible-control`.
>
> Как и раньше: **[Container / bash]** — внутри `ansible-control` (`docker exec -it ansible-control bash`), **[Host / PowerShell]** — на Windows-хосте.

---

## 3.1 Идея

На каждой ноде поднимаются **два** независимых backend-процесса — «blue» и «green» — оба работают одновременно на разных портах. Nginx смотрит только на один из них через `upstream`, выбор порта зависит от переменной `active_color`. Переключение = перегенерировать `nginx.conf` из шаблона с новым `active_color` и сделать `nginx -s reload`.

> Комментарий: `reload` не убивает мастер-процесс nginx — запускает новые worker-процессы с новым конфигом, донашивает старые соединения на старых воркерах и гасит их. Простоя нет именно потому, что оба backend'а (`blue` и `green`) уже живы в момент переключения — меняется только то, куда nginx проксирует *новые* запросы.

---

## 3.2 Переменные: активный цвет и порты backend'ов

**[Container / bash]**
```bash
cd ~/ansible-nginx-demo
cat <<EOF >> group_vars/all.yml
active_color: blue
app_port_blue: 9001
app_port_green: 9002
EOF
```

> Комментарий: `active_color` задан по умолчанию `blue`, но при запуске плейбука переопределяется через `-e active_color=green` (extra-vars — наивысший приоритет в Ansible, выше `group_vars`/`host_vars`) — без правки файлов.

---

## 3.3 Два backend'а blue/green на каждой ноде

**[Container / bash]** — дописать в конец `tasks:` в `site.yml` (перед `handlers:`):

```yaml
    - name: Create blue/green content dirs
      ansible.builtin.file:
        path: "/var/www/{{ item }}"
        state: directory
      loop:
        - blue
        - green

    - name: Deploy blue page
      ansible.builtin.copy:
        dest: /var/www/blue/index.html
        content: "<h1 style='background:#3b82f6;color:#fff;padding:2em;font-family:sans-serif'>BLUE — {{ inventory_hostname }}</h1>"

    - name: Deploy green page
      ansible.builtin.copy:
        dest: /var/www/green/index.html
        content: "<h1 style='background:#22c55e;color:#fff;padding:2em;font-family:sans-serif'>GREEN — {{ inventory_hostname }}</h1>"

    - name: Check if blue backend is already running
      ansible.builtin.shell: pgrep -f "http.server {{ app_port_blue }}" || true
      register: blue_running
      changed_when: false

    - name: Start blue backend
      ansible.builtin.shell: nohup python3 -m http.server {{ app_port_blue }} --directory /var/www/blue >/tmp/blue.log 2>&1 & disown
      args:
        executable: /bin/bash
      when: blue_running.stdout == ""

    - name: Check if green backend is already running
      ansible.builtin.shell: pgrep -f "http.server {{ app_port_green }}" || true
      register: green_running
      changed_when: false

    - name: Start green backend
      ansible.builtin.shell: nohup python3 -m http.server {{ app_port_green }} --directory /var/www/green >/tmp/green.log 2>&1 & disown
      args:
        executable: /bin/bash
      when: green_running.stdout == ""
```

> Комментарий: как и с nginx, в контейнерах нет systemd — фоновые процессы стартуют через `nohup ... & disown`, а не `service`/`systemd`. Проверка `pgrep` перед стартом нужна для идемпотентности. `blue` и `green` запускаются **оба и всегда** — неактивная версия не выключается, а простаивает в горячем резерве.

Проще всего пересоздать файл целиком — вот полный `site.yml`, объединяющий задачи Шага 2 (включая фикс `ansible_os_family == "RedHat" or ansible_distribution == "Rocky"`, см. `02-nginx-templates-deploy.md`) и новые blue/green-задачи из этого раздела:

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

    - name: Create blue/green content dirs
      ansible.builtin.file:
        path: "/var/www/{{ item }}"
        state: directory
      loop:
        - blue
        - green

    - name: Deploy blue page
      ansible.builtin.copy:
        dest: /var/www/blue/index.html
        content: "<h1 style='background:#3b82f6;color:#fff;padding:2em;font-family:sans-serif'>BLUE — {{ inventory_hostname }}</h1>"

    - name: Deploy green page
      ansible.builtin.copy:
        dest: /var/www/green/index.html
        content: "<h1 style='background:#22c55e;color:#fff;padding:2em;font-family:sans-serif'>GREEN — {{ inventory_hostname }}</h1>"

    - name: Check if blue backend is already running
      ansible.builtin.shell: pgrep -f "http.server {{ app_port_blue }}" || true
      register: blue_running
      changed_when: false

    - name: Start blue backend
      ansible.builtin.shell: nohup python3 -m http.server {{ app_port_blue }} --directory /var/www/blue >/tmp/blue.log 2>&1 & disown
      args:
        executable: /bin/bash
      when: blue_running.stdout == ""

    - name: Check if green backend is already running
      ansible.builtin.shell: pgrep -f "http.server {{ app_port_green }}" || true
      register: green_running
      changed_when: false

    - name: Start green backend
      ansible.builtin.shell: nohup python3 -m http.server {{ app_port_green }} --directory /var/www/green >/tmp/green.log 2>&1 & disown
      args:
        executable: /bin/bash
      when: green_running.stdout == ""

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

> Комментарий: blue/green-задачи вставлены **после** установки nginx-пакета, но **до** рендера `nginx.conf` и `index.html` — так дирректории `/var/www/blue` и `/var/www/green` и оба backend-процесса уже существуют к моменту, когда `nginx.conf` (со ссылкой на них в `upstream`) применяется и nginx стартует/перечитывает конфиг.

---

## 3.4 templates/nginx.conf.j2 — upstream с условным портом

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

    upstream release_backend {
        {% if active_color == "blue" %}
        server 127.0.0.1:{{ app_port_blue }};
        {% else %}
        server 127.0.0.1:{{ app_port_green }};
        {% endif %}
    }

    server {
        listen {{ http_port }};
        server_name {{ inventory_hostname }};

        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        location /release/ {
            proxy_pass http://release_backend/;
            proxy_set_header Host $host;
        }
    }
}
EOF
```

> Комментарий: `{% if active_color == "blue" %}...{% else %}...{% endif %}` — переключение порта upstream через условие в шаблоне. В `upstream release_backend` всегда объявлен ровно один `server` — активный цвет; неактивный продолжает работать как процесс (см. 3.3), готовый стать активным при следующем рендере. `location /` по-прежнему отдаёт статическую страницу Шага 2, `location /release/` — новый путь с текущей blue/green-версией.

---

## 3.5 Раскатка и переключение цвета

**[Container / bash]**
```bash
ansible-playbook -i inventory.ini site.yml
```

Проверка с хоста (порт `18080`→`8080` уже опубликован на `localhost` из Шага 1):

**[Host / PowerShell]**
```powershell
curl.exe http://localhost:18080/release/
```

Ожидаемый вывод — синяя страница (`BLUE — node1-ubuntu`).

Переключение на green **без правки файлов**, через extra-vars:

**[Container / bash]**
```bash
ansible-playbook -i inventory.ini site.yml -e active_color=green
```

**[Host / PowerShell]**
```powershell
curl.exe http://localhost:18080/release/
```

Ожидаемый вывод — зелёная страница (`GREEN — node1-ubuntu`).

> Комментарий: между двумя прогонами `site.yml`: (1) `copy`-задачи для blue/green страниц — `ok`, не `changed` (содержимое не менялось); (2) `pgrep`-проверки находят оба уже запущенных backend-процесса, старт пропускается; (3) `nginx.conf`, отрендеренный с `active_color=green`, отличается от предыдущего (порт в `upstream` поменялся) — задача `template` помечается `changed` → срабатывает `notify: Restart nginx` → хэндлер делает `nginx -s reload`. Меняется только upstream-порт, сам nginx не останавливается.

---

## 3.6 Проверка «без простоя» (zero-downtime)

Поскольку порт уже опубликован на хост (`18080`→`8080`), весь тест можно провести прямо из PowerShell на Windows — не заходя в контейнер.

**[Host / PowerShell]** — в отдельном окне запускаем непрерывный опрос `/release/` во время переключения:
```powershell
while ($true) {
  curl.exe -s -o NUL -w "%{http_code} " http://localhost:18080/release/
  Start-Sleep -Milliseconds 200
}
```

**[Container / bash]** — во втором окне (внутри `ansible-control`) в этот момент выполняем переключение обратно на blue:
```bash
ansible-playbook -i inventory.ini site.yml -e active_color=blue
```

> Комментарий: в первом окне должна идти сплошная строка `200 200 200 200 ...` без единого обрыва, `000` или `502` — это и есть доказательство отсутствия простоя. Если бы вместо `reload` использовался `restart` (полная остановка + запуск нового мастер-процесса), в этом месте почти наверняка проскочили бы несколько `000`/ошибок соединения, пока порт недоступен. Остановить цикл в PowerShell — `Ctrl+C`.

---

## Итог шага 3 (бонус)

- [ ] `active_color`, `app_port_blue`, `app_port_green` вынесены в `group_vars/all.yml`
- [ ] На каждой ноде одновременно работают два backend-процесса — blue (`{{ app_port_blue }}`) и green (`{{ app_port_green }}`)
- [ ] `templates/nginx.conf.j2` выбирает порт в `upstream release_backend` условием `{% if active_color == "blue" %}...{% else %}...{% endif %}`
- [ ] Переключение цвета выполняется без правки файлов — через `ansible-playbook ... -e active_color=green|blue`
- [ ] Хэндлер `notify: Restart nginx` делает `nginx -s reload`, а не полный рестарт — переключение происходит без простоя
- [ ] Непрерывный опрос `http://localhost:18080/release/` с хоста во время переключения не показывает ни одного неуспешного ответа
