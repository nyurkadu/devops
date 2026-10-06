# Homework: Ansible — Шаг 3 (⭐ бонус). Blue-Green deployment через `active_color`

> Задание (см. `home_work.txt`):
> ⭐️ Реализовать Blue-Green deployment через динамическую смену переменной активного цвета (`active_color`) и переключение портов upstream в шаблоне Nginx без простоя сервиса.
>
> Продолжение Шага 2 (`02-nginx-templates-deploy.md`) — используется тот же проект `~/ansible-nginx-demo` на control node Killercoda: `inventory.ini`, `group_vars`, `host_vars`, `site.yml`, `templates/nginx.conf.j2` уже созданы и раскатаны.

---

## 3.1 Идея

Поднимаем на каждой ноде **два** независимых backend-процесса — «blue» и «green» — оба работают одновременно на разных портах. Nginx смотрит только на один из них через `upstream`, выбор порта зависит от переменной `active_color`. Переключение = перегенерировать `nginx.conf` из шаблона с новым `active_color` и сделать `nginx -s reload`.

> Комментарий: `reload` (в отличие от `restart`) не убивает мастер-процесс nginx — он запускает новые worker-процессы с новым конфигом и донашивает старые соединения на старых воркерах, затем гасит их. Простоя нет именно потому, что оба backend'а (`blue` и `green`) уже живы в момент переключения — меняется только то, куда nginx проксирует *новые* запросы.

---

## 3.2 Переменные: активный цвет и порты backend'ов

Добавляем в `group_vars/all.yml` (дописать к уже существующему файлу из Шага 2):

```bash
cat <<EOF >> group_vars/all.yml
active_color: blue
app_port_blue: 9001
app_port_green: 9002
EOF
```

> Комментарий: `active_color` задан по умолчанию как `blue` в `group_vars`, но при запуске плейбука его можно переопределить через `-e active_color=green` (extra-vars имеют наивысший приоритет в Ansible, выше `group_vars`/`host_vars`) — это и есть требуемая «динамическая смена переменной», без правки файлов.

---

## 3.3 Два backend'а blue/green на каждой ноде

Для демонстрации используем `python3 -m http.server` — лёгкий встроенный HTTP-сервер, отдаёт статическую страницу с явным указанием цвета (чтобы визуально видеть переключение).

Добавляем задачи в конец `tasks:` в `site.yml` (перед секцией `handlers:`):

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

> Комментарий: как и с nginx в Шаге 2, в контейнерах нет systemd — фоновые процессы стартуют через `nohup ... & disown`, а не через `service`/`systemd`. Проверка `pgrep` перед стартом нужна для идемпотентности: повторный запуск плейбука не должен плодить дубликаты процессов на одном порту. `blue` и `green` запускаются **оба и всегда** — в этом и есть blue-green: неактивная версия не выключается, а простаивает в горячем резерве, готовая принять трафик в любой момент.

---

## 3.4 templates/nginx.conf.j2 — upstream с условным портом

Перезаписываем шаблон из Шага 2, добавив `upstream`-блок и `location /release/`:

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

> Комментарий: `{% if active_color == "blue" %}...{% else %}...{% endif %}` — это и есть требуемое «переключение портов upstream в шаблоне через условие». В `upstream release_backend` в любой момент времени объявлен ровно один `server` — активный цвет; неактивный просто не попадает в конфиг, но продолжает работать как процесс (см. 3.3), готовый стать активным при следующем рендере шаблона. `location /` по-прежнему отдаёт статическую страницу Step 2 (инфо о сервере), `location /release/` — новый путь, показывающий текущую blue/green-версию.

---

## 3.5 Раскатка и переключение цвета

Первый прогон (поднимает оба backend'а, `active_color` по умолчанию `blue` из `group_vars/all.yml`):

```bash
ansible-playbook -i inventory.ini site.yml
```

Проверка:

```bash
curl -s http://$NODE1_IP:8080/release/
```

Ожидаемый вывод — синяя страница (`BLUE — node1-ubuntu`).

Переключение на green **без правки файлов**, через extra-vars:

```bash
ansible-playbook -i inventory.ini site.yml -e active_color=green
```

```bash
curl -s http://$NODE1_IP:8080/release/
```

Ожидаемый вывод — зелёная страница (`GREEN — node1-ubuntu`).

> Комментарий: между двумя прогонами `site.yml` playbook: (1) видит, что содержимое `/var/www/blue`, `/var/www/green` не изменилось — `copy`-задачи `ok`, не `changed`; (2) видит, что оба backend-процесса уже запущены — `pgrep`-проверки находят их, старт пропускается; (3) видит, что `nginx.conf`, отрендеренный с `active_color=green`, отличается от предыдущего (порт в `upstream` поменялся) — задача `template` помечается `changed` → срабатывает `notify: Restart nginx` → хэндлер делает `nginx -s reload`. Меняется **только** upstream-порт, сам nginx не останавливается.

---

## 3.6 Проверка «без простоя» (zero-downtime)

В отдельном терминале (второй вкладке Killercoda или второй сессии control node) запускаем непрерывный опрос `/release/` во время переключения:

```bash
while true; do
  curl -s -o /dev/null -w "%{http_code} " http://$NODE1_IP:8080/release/
  sleep 0.2
done
```

В первом терминале в этот момент выполняем переключение цвета обратно на blue:

```bash
ansible-playbook -i inventory.ini site.yml -e active_color=blue
```

> Комментарий: во втором терминале должна идти сплошная строка `200 200 200 200 ...` без единого обрыва, `000` или `502` — это и есть доказательство отсутствия простоя. Если бы вместо `reload` использовался `restart` (полная остановка + запуск нового мастер-процесса), в этом месте почти наверняка проскочили бы несколько `000`/`Connection refused`, пока порт 8080 недоступен.

---

## Итог шага 3 (бонус)

- [ ] `active_color`, `app_port_blue`, `app_port_green` вынесены в `group_vars/all.yml`
- [ ] На каждой ноде одновременно работают два backend-процесса — blue (`{{ app_port_blue }}`) и green (`{{ app_port_green }}`)
- [ ] `templates/nginx.conf.j2` выбирает порт в `upstream release_backend` условием `{% if active_color == "blue" %}...{% else %}...{% endif %}`
- [ ] Переключение цвета выполняется без правки файлов — через `ansible-playbook ... -e active_color=green|blue`
- [ ] Хэндлер `notify: Restart nginx` делает `nginx -s reload`, а не полный рестарт — переключение происходит без простоя
- [ ] Непрерывный `curl`-опрос во время переключения не показывает ни одного неуспешного ответа
