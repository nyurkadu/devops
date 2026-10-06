# 5. Как пробы отображаются в Deployment / ReplicaSet / Pod / Container

Задание: **Проверить, как они отображаются в информации о деплойменте, репликасете, подах и контейнерах.**

Используется тот же `probes-demo` из [04_probes_create.md](04_probes_create.md) со всеми тремя пробами (startup, liveness, readiness).

```bash
kubectl get deployment probes-demo -o wide
```
```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
probes-demo   3/3     3            3           14m   nginx        nginx:1.27   app=probes-demo
```

```bash
kubectl get rs -l app=probes-demo
```
```
NAME                   DESIRED   CURRENT   READY   AGE
probes-demo-c845fb76   3         3         3       14m
```

```bash
kubectl get pods -l app=probes-demo -o wide
```
```
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
probes-demo-c845fb76-56g6l   1/1     Running   0          14m   10.244.0.46   minikube   <none>           <none>
probes-demo-c845fb76-6bhjk   1/1     Running   0          14m   10.244.0.47   minikube   <none>           <none>
probes-demo-c845fb76-d2gf9   1/1     Running   0          14m   10.244.0.48   minikube   <none>           <none>
```

Общее число проб на объект: `describe` показывает пробы **только** на Deployment, ReplicaSet и Pod/Container — на уровне `kubectl get deployment/rs/pods` (короткий листинг без `-o wide`/`-o yaml`) проб не видно вообще, они скрыты внутри `spec`.

---

## Уровень 1: Deployment

### `-o yaml` — источник истины (спецификация)

```bash
kubectl get deployment probes-demo -o yaml | grep -A6 -E "startupProbe|livenessProbe|readinessProbe"
```

```yaml
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 10
--
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 5
--
        startupProbe:
          failureThreshold: 30
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 2
```

Пробы лежат внутри `spec.template.spec.containers[].{startupProbe,livenessProbe,readinessProbe}` — то есть являются частью **шаблона пода**, а не отдельными полями Deployment.

### `kubectl describe deployment`

`describe deployment` **не печатает пробы напрямую** в общем summary (там только образы, стратегия, реплики, события) — чтобы увидеть их человекочитаемо, нужно смотреть уровень ниже (Pod/ReplicaSet), либо явно вытаскивать через `-o jsonpath`:

```bash
kubectl get deployment probes-demo -o jsonpath='{.spec.template.spec.containers[0].startupProbe}'
```
```
{"failureThreshold":30,"httpGet":{"path":"/","port":80,"scheme":"HTTP"},"periodSeconds":2,"successThreshold":1,"timeoutSeconds":1}
```

**Вывод по Deployment:** это единственный уровень, где пробы существуют как **декларация** ("что должно быть") — сырые данные в `spec`, без какого-либо статуса выполнения.

---

## Уровень 2: ReplicaSet

```bash
kubectl get rs probes-demo-c845fb76 -o yaml | grep -A6 -E "startupProbe|livenessProbe|readinessProbe"
```

```yaml
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 10
--
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 5
--
        startupProbe:
          failureThreshold: 30
          httpGet:
            path: /
            port: 80
            scheme: HTTP
          periodSeconds: 2
```

Побайтово идентично Deployment — ReplicaSet хранит **копию** `podTemplate`, зафиксированную на момент создания этой ревизии.

```bash
kubectl describe rs probes-demo-c845fb76
```

Фрагмент вывода (человекочитаемое summary, как и у пода):

```
    Liveness:      http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:     http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Startup:       http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=30
```

**Вывод по ReplicaSet:** тоже только **декларация**, без статуса выполнения — ReplicaSet вообще не знает, проходят ли пробы у его подов прямо сейчас, он лишь следит за количеством реплик.

---

## Уровень 3: Pod (spec) и Container (status)

### `spec` пода — та же декларация

```bash
kubectl get pod probes-demo-c845fb76-56g6l -o yaml | grep -A6 -E "startupProbe|livenessProbe|readinessProbe"
```

```yaml
    livenessProbe:
      failureThreshold: 3
      httpGet:
        path: /
        port: 80
        scheme: HTTP
      periodSeconds: 10
--
    readinessProbe:
      failureThreshold: 3
      httpGet:
        path: /
        port: 80
        scheme: HTTP
      periodSeconds: 5
--
    startupProbe:
      failureThreshold: 30
      httpGet:
        path: /
        port: 80
        scheme: HTTP
      periodSeconds: 2
```

### `status.containerStatuses` — а вот это уже **результат выполнения**, а не декларация

```bash
kubectl get pod probes-demo-c845fb76-56g6l -o yaml | grep -A15 "containerStatuses:"
```

```yaml
containerStatuses:
- containerID: docker://7d8a6b560cf9...
  image: nginx:1.27
  imageID: docker-pullable://nginx@sha256:6784fb...
  lastState: {}
  name: nginx
  ready: true
  resources: {}
  restartCount: 0
  started: true
  state:
    running:
      startedAt: "2026-08-18T13:06:45Z"
```

```bash
kubectl get pod probes-demo-c845fb76-56g6l -o jsonpath='{.status.containerStatuses[0].started}{"\n"}{.status.containerStatuses[0].ready}{"\n"}'
```

```
true
true
```

Это — единственное место во всей иерархии, где видно **живой статус** проб, а не их конфигурацию:

| Поле в `containerStatuses[0]` | Чем управляется | Значение сейчас |
|---|---|---|
| `started` | результат **startupProbe** (`true` после первого успеха, дальше не меняется) | `true` |
| `ready` | текущий результат **readinessProbe** (переключается туда-обратно в реальном времени) | `true` |
| `restartCount` | растёт при провале **livenessProbe** (или crash) | `0` |
| `state.running` / `lastState` | если livenessProbe провалит контейнер — здесь появится `state.waiting` (CrashLoopBackOff) и `lastState.terminated` с причиной | `running` |

### `kubectl describe pod` — человекочитаемая сводка обоих миров (декларация + статус)

```bash
kubectl describe pod probes-demo-c845fb76-56g6l
```

```
Containers:
  nginx:
    Image:          nginx:1.27
    Port:           80/TCP
    State:          Running
      Started:      Tue, 18 Aug 2026 16:06:45 +0300
    Ready:          True
    Restart Count:  0
    Liveness:       http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:      http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Startup:        http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=30
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
```

**Вывод по Pod/Container:** это единственный уровень в иерархии, где одновременно видна и **декларация** (`Liveness:`/`Readiness:`/`Startup:` — что настроено), и **текущий результат** (`Ready: True`, `Restart Count: 0`, `Conditions: Ready=True`) — потому что именно на подах пробы физически выполняются kubelet-ом.

---

## Сводная таблица: что на каком уровне видно

| Уровень | Хранит конфигурацию проб? | Хранит результат выполнения проб? | Где смотреть |
|---|---|---|---|
| **Deployment** | Да (`spec.template.spec.containers[].*Probe`) | Нет | `-o yaml` / `-o jsonpath`, в `describe` не выводится напрямую |
| **ReplicaSet** | Да (копия из Deployment) | Нет | `describe rs` (краткий вид), `-o yaml` (полный) |
| **Pod (`spec`)** | Да (копия из ReplicaSet/Deployment) | — | `-o yaml` |
| **Pod (`status.containerStatuses`)** | Нет | **Да** — `started`, `ready`, `restartCount`, `state`/`lastState` | `-o yaml`, `-o jsonpath`, `describe pod` |
| **Container (внутри пода)** | — | Да, оттуда и берётся `status` | `describe pod` (секция `Containers`) |

**Главные выводы:**
1. Пробы как **конфигурация** реплицируются без изменений по всей цепочке `Deployment → ReplicaSet → Pod.spec` — это просто часть шаблона пода.
2. Пробы как **результат выполнения** (прошла/не прошла, сколько раз перезапускали) видны **только на Pod/Container уровне**, в `status.containerStatuses` — ни Deployment, ни ReplicaSet этого не знают и не хранят.
3. `kubectl describe` на Deployment/ReplicaSet показывает пробы как статичную сводку настроек; `kubectl describe pod` — единственное место, где рядом видно и настройки, и живой статус (`Ready`, `Restart Count`).
4. Для отладки "что реально происходит с пробами прямо сейчас" всегда нужно смотреть на **Pod**, а не выше по иерархии.
