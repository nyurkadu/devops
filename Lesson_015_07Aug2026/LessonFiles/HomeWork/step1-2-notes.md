# Homework: Minikube & kubectl — Шаги 1-4

## Шаг 1. Создание Pod и YAML Manifests

### 1.1 Запуск nginx Pod через `kubectl run`

```bash
kubectl run nginx --image=nginx
```

Вывод:
```
pod/nginx created
```

Проверка:
```bash
kubectl get pod nginx -o wide
```

Вывод:
```
NAME    READY   STATUS              RESTARTS   AGE   IP       NODE       NOMINATED NODE   READINESS GATES
nginx   0/1     ContainerCreating   0          0s    <none>   minikube   <none>           <none>
```

> Комментарий: `kubectl run` — императивный способ создать Pod одной командой, без YAML-файла. Полезно для быстрых тестов, но не подходит для версионирования конфигурации.

### 1.2 Генерация YAML-манифеста через `--dry-run=client -o yaml`

```bash
kubectl run nginx --image=nginx --dry-run=client -o yaml > nginx-pod.yaml
```

> Комментарий: флаг `--dry-run=client` не отправляет запрос на создание объекта в кластер — команда только генерирует объект локально и рендерит его в YAML (`-o yaml`), который перенаправляется в файл `nginx-pod.yaml`. Это стандартный приём для быстрого получения "скелета" манифеста, который потом можно доработать вручную.

Содержимое `nginx-pod.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: nginx
  name: nginx
spec:
  containers:
  - image: nginx
    name: nginx
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
status: {}
```

### 1.3 Запуск Pod из полученного `.yaml` файла

Перед повторным созданием Pod из файла, ранее созданный императивно Pod был удалён во избежание конфликта имён:

```bash
kubectl delete pod nginx
```

Вывод:
```
pod "nginx" deleted from default namespace
```

Создание Pod из манифеста:

```bash
kubectl apply -f nginx-pod.yaml
```

Вывод:
```
pod/nginx created
```

Проверка:
```bash
kubectl get pod nginx -o wide
```

Вывод:
```
NAME    READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
nginx   1/1     Running   0          3s    10.244.0.8   minikube   <none>           <none>
```

> Комментарий: `kubectl apply -f <файл>` — декларативный способ создания/обновления объекта из YAML-манифеста. Именно этот подход используется в реальных проектах, так как манифест хранится в git и может проходить code review.

---

## Шаг 2. Инспекция, Logs и Exec

### 2.1 `kubectl describe pod` — детали Pod

```bash
kubectl describe pod nginx
```

Вывод (сокращённо, ключевые поля):
```
Name:             nginx
Namespace:        default
Node:             minikube/192.168.49.2
Status:           Running
IP:               10.244.0.8
Containers:
  nginx:
    Image:          nginx
    State:          Running
      Started:      Wed, 12 Aug 2026 18:02:05 +0300
    Ready:          True
    Restart Count:  0
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
QoS Class:                   BestEffort
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  82s   default-scheduler  Successfully assigned default/nginx to minikube
  Normal  Pulling    81s   kubelet            Pulling image "nginx"
  Normal  Pulled     80s   kubelet            Successfully pulled image "nginx" in 1.322s
  Normal  Created    79s   kubelet            Container created
  Normal  Started    79s   kubelet            Container started
```

> Комментарий: `describe pod` показывает **runtime-состояние конкретного экземпляра**: на какой node он запланирован, его IP, состояние контейнера, точное время старта, точки монтирования и хронологию событий (Scheduled → Pulling → Pulled → Created → Started).

### 2.2 `kubectl describe` для ReplicaSet — сравнение

Для сравнения был создан отдельный манифест ReplicaSet `nginx-rs.yaml`:

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: nginx-rs
  labels:
    app: nginx-rs
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx-rs
  template:
    metadata:
      labels:
        app: nginx-rs
    spec:
      containers:
      - name: nginx
        image: nginx
```

```bash
kubectl apply -f nginx-rs.yaml
```

Вывод:
```
replicaset.apps/nginx-rs created
```

```bash
kubectl get rs nginx-rs
kubectl get pods -l app=nginx-rs
```

Вывод:
```
NAME       DESIRED   CURRENT   READY   AGE
nginx-rs   3         3         2       6s

NAME             READY   STATUS              RESTARTS   AGE
nginx-rs-hdvfw   1/1     Running             0          6s
nginx-rs-vqzcj   1/1     Running             0          6s
nginx-rs-w2pc9   0/1     ContainerCreating   0          6s
```

```bash
kubectl describe rs nginx-rs
```

Вывод:
```
Name:         nginx-rs
Namespace:    default
Selector:     app=nginx-rs
Labels:       app=nginx-rs
Annotations:  <none>
Replicas:     3 current / 3 desired
Pods Status:  3 Running / 0 Waiting / 0 Succeeded / 0 Failed
Pod Template:
  Labels:  app=nginx-rs
  Containers:
   nginx:
    Image:         nginx
    Port:          <none>
    Host Port:     <none>
    Environment:   <none>
    Mounts:        <none>
  Volumes:         <none>
Events:
  Type    Reason            Age   From                   Message
  ----    ------            ----  ----                   -------
  Normal  SuccessfulCreate  9s    replicaset-controller  Created pod: nginx-rs-hdvfw
  Normal  SuccessfulCreate  9s    replicaset-controller  Created pod: nginx-rs-vqzcj
  Normal  SuccessfulCreate  9s    replicaset-controller  Created pod: nginx-rs-w2pc9
```

#### Сравнение `describe pod` vs `describe rs`

**`kubectl describe pod`**
- Что показывает: runtime-состояние **одного** экземпляра — node, IP, состояние контейнера, mounts, conditions
- События: жизненный цикл контейнера — `Scheduled` → `Pulling` → `Pulled` → `Created` → `Started`
- Владение: у Pod'а, созданного через RS, будет строка `Controlled By: ReplicaSet/nginx-rs`
- Назначение: диагностика конкретного контейнера/instance

**`kubectl describe rs`**
- Что показывает: желаемое состояние **набора** — selector, кол-во реплик (desired/current), Pod template
- События: `SuccessfulCreate` — по одному событию на каждый созданный Pod
- Владение: у самого RS нет "родителя" (если он не создан через Deployment)
- Назначение: контроль за количеством реплик и их здоровьем в целом

> Комментарий: ReplicaSet сам по себе не описывает запущенный контейнер — он описывает **шаблон** (template) и статус согласования (reconciliation). Реальные runtime-детали (IP, статус контейнера) видны только при `describe` конкретного дочернего Pod.

### 2.3 Логи через `kubectl logs`

```bash
kubectl logs nginx
```

Вывод:
```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: Getting the checksum of /etc/nginx/conf.d/default.conf
10-listen-on-ipv6-by-default.sh: info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf
/docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/08/12 15:02:05 [notice] 1#1: using the "epoll" event method
2026/08/12 15:02:05 [notice] 1#1: nginx/1.31.3
2026/08/12 15:02:05 [notice] 1#1: built by gcc 14.2.0 (Debian 14.2.0-19)
2026/08/12 15:02:05 [notice] 1#1: OS: Linux 6.6.87.2-microsoft-standard-WSL2
2026/08/12 15:02:05 [notice] 1#1: start worker processes
2026/08/12 15:02:05 [notice] 1#1: start worker process 30
...
2026/08/12 15:02:05 [notice] 1#1: start worker process 41
```

> Комментарий: `kubectl logs <pod>` выводит stdout/stderr контейнера — то же самое, что видно в `docker logs`. Здесь видно стандартный лог запуска nginx: обработка конфигурации entry-point скриптами, затем запуск master-процесса и worker-процессов (по числу CPU).

### 2.4 Заход внутрь Pod через `kubectl exec`

Целевая команда:
```bash
kubectl exec -it nginx -- /bin/sh
```

> Комментарий: флаги `-i` (interactive) и `-t` (tty) требуют настоящего терминала с TTY, поэтому команда выполнялась в неинтерактивном виде (без `-it`, с явной командой в кавычках), чтобы получить эквивалентный результат в автоматизированной среде:

```bash
kubectl exec nginx -- /bin/sh -c "hostname && whoami && nginx -v && ls /usr/share/nginx/html && head -3 /etc/os-release"
```

Вывод:
```
nginx
root
nginx version: nginx/1.31.3
50x.html
index.html
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
```

> Комментарий: `kubectl exec` открывает shell/выполняет команду прямо внутри контейнера. Подтверждено: пользователь внутри контейнера — `root`, версия nginx — 1.31.3, ОС — Debian 13 (trixie), корень сайта — `/usr/share/nginx/html`. Для полноценной интерактивной сессии (`kubectl exec -it nginx -- /bin/sh`) нужно выполнять команду в обычном терминале.

### 2.5 Проброс порта через `kubectl port-forward`

Первая попытка (порт 8080) — неудачная, порт был занят другим процессом в Windows:

```bash
kubectl port-forward pod/nginx 8080:80
```

Вывод:
```
Unable to listen on port 8080: Listeners failed to create with the following errors: [unable to create listener: Error listen tcp4 127.0.0.1:8080: bind: An attempt was made to access a socket in a way forbidden by its access permissions. unable to create listener: Error listen tcp6 [::1]:8080: bind: An attempt was made to access a socket in a way forbidden by its access permissions.]
error: unable to listen on any of the requested ports: [{8080 80}]
```

Повторная попытка на порту 8888 — успешно, процесс запущен в фоне (detached), чтобы не завершиться вместе с сессией:

```powershell
Start-Process -FilePath "kubectl" -ArgumentList "port-forward","pod/nginx","8888:80" -WindowStyle Hidden
```

Проверка доступа:

```powershell
Invoke-WebRequest -Uri "http://localhost:8888" -UseBasicParsing | Select-Object -ExpandProperty StatusCode
```

Вывод:
```
200
```

```bash
curl -s http://localhost:8888
```

Вывод (фрагмент):
```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
<h1>Welcome to nginx!</h1>
<p>If you see this page, nginx is successfully installed and working.</p>
```

Открытие в браузере:
```powershell
Start-Process "http://localhost:8888"
```

> Комментарий: `kubectl port-forward` пробрасывает локальный порт машины напрямую на порт внутри Pod'а, минуя Service — удобно для быстрой отладки. Порт 8080 оказался занят другим процессом на Windows (bind permission error), поэтому проброс был выполнен на порт 8888. Итог — страница приветствия nginx открылась в браузере по адресу `http://localhost:8888`.

---

## Шаг 3. Жизненный цикл и Self-Healing

Состояние перед началом шага:

```bash
kubectl get pods -o wide
```

```
NAME             READY   STATUS    RESTARTS   AGE     IP            NODE       NOMINATED NODE   READINESS GATES
nginx            1/1     Running   0          6m47s   10.244.0.8    minikube   <none>           <none>
nginx-rs-hdvfw   1/1     Running   0          5m16s   10.244.0.10   minikube   <none>           <none>
nginx-rs-vqzcj   1/1     Running   0          5m16s   10.244.0.9    minikube   <none>           <none>
nginx-rs-w2pc9   1/1     Running   0          5m16s   10.244.0.11   minikube   <none>           <none>
```

### 3.1 Удаление одиночного Pod (без контроллера)

```bash
kubectl delete pod nginx
```

Вывод:
```
pod "nginx" deleted from default namespace
```

Проверка через 10 секунд:

```bash
kubectl get pod nginx
```

Вывод:
```
Error from server (NotFound): pods "nginx" not found
```

```bash
kubectl get pods
```

Вывод:
```
NAME             READY   STATUS    RESTARTS   AGE
nginx-rs-hdvfw   1/1     Running   0          5m32s
nginx-rs-vqzcj   1/1     Running   0          5m32s
nginx-rs-w2pc9   1/1     Running   0          5m32s
```

> Комментарий: одиночный Pod `nginx` был создан напрямую (`kubectl apply -f nginx-pod.yaml`), без ReplicaSet/Deployment над ним. Значит, у него нет контроллера, который следит за его существованием и пересоздаёт его. После `kubectl delete pod nginx` Pod исчезает навсегда — self-healing здесь не работает.

### 3.2 Удаление Pod, управляемого ReplicaSet

```bash
kubectl delete pod nginx-rs-hdvfw
```

Вывод:
```
pod "nginx-rs-hdvfw" deleted from default namespace
```

Проверка через 5 секунд:

```bash
kubectl get pods -l app=nginx-rs -o wide
```

Вывод:
```
NAME             READY   STATUS    RESTARTS   AGE     IP            NODE       NOMINATED NODE   READINESS GATES
nginx-rs-cghtb   1/1     Running   0          7s      10.244.0.12   minikube   <none>           <none>
nginx-rs-vqzcj   1/1     Running   0          5m45s   10.244.0.9    minikube   <none>           <none>
nginx-rs-w2pc9   1/1     Running   0          5m45s   10.244.0.11   minikube   <none>           <none>
```

События ReplicaSet после удаления:

```bash
kubectl describe rs nginx-rs
```

Вывод (Events):
```
Events:
  Type    Reason            Age    From                   Message
  ----    ------            ----   ----                   -------
  Normal  SuccessfulCreate  5m50s  replicaset-controller  Created pod: nginx-rs-hdvfw
  Normal  SuccessfulCreate  5m50s  replicaset-controller  Created pod: nginx-rs-vqzcj
  Normal  SuccessfulCreate  5m50s  replicaset-controller  Created pod: nginx-rs-w2pc9
  Normal  SuccessfulCreate  12s    replicaset-controller  Created pod: nginx-rs-cghtb
```

> Комментарий: как только `nginx-rs-hdvfw` был удалён, ReplicaSet-контроллер обнаружил, что фактическое число подходящих под selector Pod'ов (2) меньше желаемого (`replicas: 3`), и немедленно создал новый Pod `nginx-rs-cghtb`, чтобы вернуть систему к желаемому состоянию. Это и есть self-healing на уровне ReplicaSet.

### 3.3 Ручное добавление Pod с теми же labels в ReplicaSet

Создан отдельный манифест `nginx-manual-pod.yaml` — обычный Pod (не через ReplicaSet), но с тем же label, что использует selector ReplicaSet (`app: nginx-rs`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-manual
  labels:
    app: nginx-rs
spec:
  containers:
  - name: nginx
    image: nginx
```

```bash
kubectl apply -f nginx-manual-pod.yaml
```

Вывод:
```
pod/nginx-manual created
```

Сразу после создания:
```bash
kubectl get pods -l app=nginx-rs -o wide
```
```
NAME             READY   STATUS        RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-manual     0/1     Terminating   0          0s    <none>        minikube   <none>           <none>
nginx-rs-cghtb   1/1     Running       0          22s   10.244.0.12   minikube   <none>           <none>
nginx-rs-vqzcj   1/1     Running       0          6m    10.244.0.9    minikube   <none>           <none>
nginx-rs-w2pc9   1/1     Running       0          6m    10.244.0.11   minikube   <none>           <none>
```

Через 8 секунд:
```bash
kubectl get pods -l app=nginx-rs -o wide
```
```
NAME             READY   STATUS    RESTARTS   AGE    IP            NODE       NOMINATED NODE   READINESS GATES
nginx-rs-cghtb   1/1     Running   0          30s    10.244.0.12   minikube   <none>           <none>
nginx-rs-vqzcj   1/1     Running   0          6m8s   10.244.0.9    minikube   <none>           <none>
nginx-rs-w2pc9   1/1     Running   0          6m8s   10.244.0.11   minikube   <none>           <none>
```

События ReplicaSet и финальная проверка:
```bash
kubectl describe rs nginx-rs
kubectl get pod nginx-manual
kubectl get rs nginx-rs
```

Вывод:
```
Events:
  Type    Reason            Age    From                   Message
  ----    ------            ----   ----                   -------
  Normal  SuccessfulCreate  6m14s  replicaset-controller  Created pod: nginx-rs-hdvfw
  Normal  SuccessfulCreate  6m14s  replicaset-controller  Created pod: nginx-rs-vqzcj
  Normal  SuccessfulCreate  6m14s  replicaset-controller  Created pod: nginx-rs-w2pc9
  Normal  SuccessfulCreate  36s    replicaset-controller  Created pod: nginx-rs-cghtb
  Normal  SuccessfulDelete  14s    replicaset-controller  Deleted pod: nginx-manual

Error from server (NotFound): pods "nginx-manual" not found

NAME       DESIRED   CURRENT   READY   AGE
nginx-rs   3         3         3       6m15s
```

> Комментарий: ReplicaSet управляет Pod'ами **не по имени и не по факту создания через себя, а по совпадению labels с полем `selector`**. Как только `kubectl apply` создал `nginx-manual` с label `app: nginx-rs`, контроллер ReplicaSet увидел 4 Pod'а, подходящих под selector, хотя `replicas: 3`. Реакция была мгновенной: контроллер выбрал "лишний" Pod (в данном случае — только что созданный вручную) и удалил его (`SuccessfulDelete`), вернув фактическое число реплик к желаемому (3). Это показывает, что ReplicaSet не "усыновляет" вручную добавленные Pod'ы как дополнительные — он лишь поддерживает нужное **количество** Pod'ов с заданными labels, и любой "лишний" под тем же selector будет удалён.

---

## Шаг 4. Практика YAML & JSONPath

Состояние кластера на момент выполнения (после шага 3, ReplicaSet `nginx-rs` с 3 репликами):

```bash
kubectl get pods -o wide
```
```
NAME             READY   STATUS    RESTARTS   AGE     IP            NODE       NOMINATED NODE   READINESS GATES
nginx-rs-cghtb   1/1     Running   0          5m23s   10.244.0.12   minikube   <none>           <none>
nginx-rs-vqzcj   1/1     Running   0          11m     10.244.0.9    minikube   <none>           <none>
nginx-rs-w2pc9   1/1     Running   0          11m     10.244.0.11   minikube   <none>           <none>
```

Ниже — 10 популярных примеров синтаксиса `kubectl get -o jsonpath='{...}'`, от простых до более сложных (wildcard, `range`, фильтры).

### 4.1 Имена всех Pod'ов (wildcard по массиву)

```bash
kubectl get pods -o jsonpath='{.items[*].metadata.name}'
```

Вывод:
```
nginx-rs-cghtb nginx-rs-vqzcj nginx-rs-w2pc9
```

> Документация: `.items[*]` — обращение к списку объектов, который `kubectl get` всегда возвращает как обёртку `List` (`items: [...]`). Символ `*` — wildcard, "взять все элементы массива". `.metadata.name` вытаскивает одно и то же поле у каждого элемента. Базовый паттерн, с которого начинается почти любой jsonpath-запрос к `kubectl get`.

### 4.2 Имя + фаза Pod'а через `range`/`end` (построчный вывод)

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
```

Вывод:
```
nginx-rs-cghtb	Running
nginx-rs-vqzcj	Running
nginx-rs-w2pc9	Running
```

> Документация: `{range .items[*]} ... {end}` — цикл по массиву, аналог `for` в других языках. Внутри цикла `{.metadata.name}` и `{.status.phase}` берутся по одному разу на итерацию (в отличие от wildcard, который сразу разворачивает всё через пробел). `{"\t"}` и `{"\n"}` — литеральные строки-разделители (таб и перевод строки), которые вставляются буквально. `range` — ключевая конструкция для построения "таблиц" из нескольких полей.

### 4.3 Список образов (images) всех контейнеров

```bash
kubectl get pods -o jsonpath='{.items[*].spec.containers[*].image}'
```

Вывод:
```
nginx nginx nginx
```

> Документация: двойной wildcard — сначала по `.items[*]` (все Pod'ы), затем по `.spec.containers[*]` (все контейнеры внутри каждого Pod'а, на случай multi-container Pod'ов). Полезно для быстрого аудита — какие образы реально крутятся в кластере, без открытия каждого манифеста.

### 4.4 Конкретное поле у одного объекта — IP Pod'а

```bash
kubectl get pod nginx-rs-cghtb -o jsonpath='{.status.podIP}'
```

Вывод:
```
10.244.0.12
```

> Документация: если запрашивается **один** объект (а не список через `get pods`), верхнего `.items[*]` нет — путь идёт сразу от корня объекта (`.status.podIP`). Такой точечный запрос часто используют в bash-скриптах: `IP=$(kubectl get pod X -o jsonpath='{.status.podIP}')`, чтобы подставить значение в следующую команду.

### 4.5 Имена всех node в кластере

```bash
kubectl get nodes -o jsonpath='{.items[*].metadata.name}'
```

Вывод:
```
minikube
```

> Документация: тот же паттерн `.items[*].metadata.name`, что и для Pod'ов — jsonpath работает одинаково для любого ресурса Kubernetes, потому что все `List`-объекты API имеют одинаковую структуру-обёртку.

### 4.6 Фильтрация массива по условию — `InternalIP` у node

```bash
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
```

Вывод:
```
192.168.49.2
```

> Документация: `status.addresses` — это массив объектов вида `{type: InternalIP, address: ...}`, `{type: Hostname, address: ...}` и т.д. Синтаксис `[?(@.type=="InternalIP")]` — **фильтр-выражение**: `@` означает "текущий элемент массива", а всё выражение в скобках — условие отбора. Это самый мощный элемент jsonpath в kubectl — позволяет выбрать нужный элемент из массива по значению поля, а не по индексу.

### 4.7 Labels конкретного Pod'а (вывод целой map/объекта)

```bash
kubectl get pod nginx-rs-cghtb -o jsonpath='{.metadata.labels}'
```

Вывод:
```
{"app":"nginx-rs"}
```

> Документация: если путь указывает не на строку/число, а на объект (map), jsonpath выводит его как JSON целиком. Удобно, когда нужно посмотреть все labels/annotations сразу, не выбирая конкретный ключ.

### 4.8 Имя + количество рестартов контейнера (диагностика через `range`)

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

Вывод:
```
nginx-rs-cghtb	0
nginx-rs-vqzcj	0
nginx-rs-w2pc9	0
```

> Документация: `.status.containerStatuses[0]` — обращение по **индексу** массива (первый контейнер в Pod'е), в отличие от wildcard `[*]`. Такой запрос — практичный способ быстро проверить, не крашится ли что-то в кластере (`RESTARTS` — один из первых показателей проблем), без полного `kubectl get pods` с лишними колонками.

### 4.9 Desired vs current replicas у ReplicaSet

```bash
kubectl get rs nginx-rs -o jsonpath='{.spec.replicas}{"/"}{.status.replicas}'
```

Вывод:
```
3/3
```

> Документация: два разных поля объекта (`spec` — желаемое состояние, `status` — фактическое) объединяются в одну строку через литерал `{"/"}` между ними. Показывает, что jsonpath-выражение может состоять из нескольких `{...}` блоков подряд — они просто конкатенируются в вывод.

### 4.10 Многоколоночная "таблица" из нескольких полей (name, IP, node)

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.nodeName}{"\n"}{end}'
```

Вывод:
```
nginx-rs-cghtb	10.244.0.12	minikube
nginx-rs-vqzcj	10.244.0.9	minikube
nginx-rs-w2pc9	10.244.0.11	minikube
```

> Документация: комбинация всех приёмов выше — `range` для итерации по Pod'ам и несколько полей (`metadata.name`, `status.podIP`, `spec.nodeName`) через табуляцию. По сути, это самодельная замена `kubectl get pods -o wide`/`-o custom-columns`, но с полным контролем над тем, какие именно поля и в каком порядке выводить — именно так jsonpath используют в реальных shell-скриптах и CI/CD пайплайнах (например, чтобы получить список IP для последующего curl/ssh).

#### Итог по разделу

- **Wildcard по массиву** — `[*]` — взять значение поля у всех элементов сразу
- **Индекс массива** — `[0]` — взять конкретный элемент (например, первый контейнер)
- **Цикл** — `{range}...{end}` — нужно несколько полей на "строку" / построчный вывод
- **Литерал** — `{"текст"}` — вставить разделитель (таб, перевод строки, "/")
- **Фильтр** — `[?(@.field=="value")]` — выбрать элемент массива по значению поля, а не по индексу
- **Объект целиком** — `.metadata.labels` (без выбора ключа) — вывести map/JSON как есть
