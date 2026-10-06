# 4. Пробы контейнеров: startup, liveness, readiness

Задание: **Создать пробы разных типов (`startup`, liveness, `readiness`).**

Для этого шага создан отдельный деплоймент `probes-demo` (намеренно отдельно от `nginx-deploy` из предыдущих шагов — в следующих миссиях пробы будут специально "ломаться", и удобнее делать это на изолированном объекте).

## Манифест

Файл [04_probes-demo.yaml](04_probes-demo.yaml):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probes-demo
  labels:
    app: probes-demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: probes-demo
  template:
    metadata:
      labels:
        app: probes-demo
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
          startupProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 10
            timeoutSeconds: 1
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 1
            failureThreshold: 3
```

Все три пробы используют механизм `httpGet` на `/` порт `80` (стандартная страница nginx отдаёт `200 OK`), но с разными параметрами таймингов, чтобы их было легко различить в выводе `kubectl describe`.

## Применение

```bash
kubectl apply -f 04_probes-demo.yaml
```

```
deployment.apps/probes-demo created
```

```bash
kubectl rollout status deployment/probes-demo --timeout=90s
```

```
Waiting for deployment "probes-demo" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "probes-demo" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "probes-demo" rollout to finish: 2 of 3 updated replicas are available...
deployment "probes-demo" successfully rolled out
```

```bash
kubectl get pods -l app=probes-demo -o wide
```

```
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
probes-demo-c845fb76-56g6l   1/1     Running   0          8s    10.244.0.46   minikube   <none>           <none>
probes-demo-c845fb76-6bhjk   1/1     Running   0          8s    10.244.0.47   minikube   <none>           <none>
probes-demo-c845fb76-d2gf9   1/1     Running   0          8s    10.244.0.48   minikube   <none>           <none>
```

Все 3 пода стартовали и сразу прошли `startupProbe` → `readinessProbe`/`livenessProbe` (страница `/` отвечает 200 с первого запроса, поэтому `1/1 Running` появляется быстро).

---

## Проверка: как пробы отображаются на уровне пода/контейнера

```bash
kubectl describe pod probes-demo-c845fb76-56g6l
```

Ключевой фрагмент (секция `Containers`):

```
Containers:
  nginx:
    Container ID:   docker://7d8a6b560cf9...
    Image:          nginx:1.27
    Port:           80/TCP
    Host Port:      0/TCP
    State:          Running
      Started:      Tue, 18 Aug 2026 16:06:45 +0300
    Ready:          True
    Restart Count:  0
    Liveness:       http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:      http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Startup:        http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=30
    Environment:    <none>
    ...
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       True
  ContainersReady             True
  PodScheduled                True
```

**Наблюдение:** `kubectl describe pod` показывает все три пробы одной строкой в компактном формате `<механизм> <цель> delay=<initialDelaySeconds> timeout=<timeoutSeconds> period=<periodSeconds> #success=<successThreshold> #failure=<failureThreshold>` — удобно сразу видеть все параметры каждой пробы.

---

## Проверка: как пробы отображаются на уровне Deployment

```bash
kubectl get deployment probes-demo -o jsonpath='{.spec.template.spec.containers[0].startupProbe}'
```

```
{"failureThreshold":30,"httpGet":{"path":"/","port":80,"scheme":"HTTP"},"periodSeconds":2,"successThreshold":1,"timeoutSeconds":1}
```

```bash
kubectl get deployment probes-demo -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}'
```

```
{"failureThreshold":3,"httpGet":{"path":"/","port":80,"scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}
```

```bash
kubectl get deployment probes-demo -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'
```

```
{"failureThreshold":3,"httpGet":{"path":"/","port":80,"scheme":"HTTP"},"periodSeconds":5,"successThreshold":1,"timeoutSeconds":1}
```

**Наблюдение:** Deployment хранит пробы как часть `spec.template.spec.containers[].{startupProbe,livenessProbe,readinessProbe}` — это часть шаблона пода, точно так же как образ или порты.

---

## Проверка: как пробы отображаются на уровне ReplicaSet

```bash
kubectl describe rs probes-demo-c845fb76
```

Фрагмент вывода:

```
    Liveness:      http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:     http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
    Startup:       http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=30
```

**Наблюдение:** ReplicaSet просто копирует `podTemplate` из Deployment (включая пробы) — она идентична тому, что видно и на Deployment, и на Pod/Container. Пробы — это неотъемлемая часть шаблона пода, которая транслируется по всей цепочке `Deployment → ReplicaSet → Pod → Container` без изменений.

---

## Итог

| Тип пробы | Назначение | Механизм в примере | Параметры |
|---|---|---|---|
| `startupProbe` | Определяет, когда контейнер закончил стартовать. Пока не пройдёт — liveness/readiness не выполняются (чтобы не убить медленно стартующее приложение как "зависшее"). | `httpGet /` :80 | period=2s, failure=30 (до 60с на старт) |
| `livenessProbe` | Определяет, жив ли контейнер. Провал → kubelet **перезапускает контейнер**. | `httpGet /` :80 | period=10s, timeout=1s, failure=3 (после 3 неудач подряд — restart) |
| `readinessProbe` | Определяет, готов ли под принимать трафик. Провал → под **убирается из Endpoints сервиса**, но не перезапускается. | `httpGet /` :80 | period=5s, timeout=1s, failure=3 |

**Выводы:**
1. Все три типа проб задаются в спецификации контейнера (`spec.template.spec.containers[].*Probe`) — это часть шаблона пода, а не отдельный ресурс.
2. Пробы идентично видны на всех уровнях иерархии: Deployment → ReplicaSet → Pod → Container, поскольку ReplicaSet и Pod — это материализация одного и того же `podTemplate`.
3. `kubectl describe pod/rs` даёт человекочитаемое однострочное summary для каждой пробы; `kubectl get ... -o jsonpath`/`-o yaml` — точную структуру с полями `httpGet/exec/tcpSocket`, `periodSeconds`, `timeoutSeconds`, `successThreshold`, `failureThreshold`.
4. Пока `startupProbe` не подтвердит успешный старт, kubelet **не запускает** `livenessProbe` и `readinessProbe` — это видно по полю `Startup` в `describe`, которое существует отдельно от `Liveness`/`Readiness`.

Далее (следующая миссия) — намеренно фейлить эти пробы в разных комбинациях и смотреть на поведение системы (рестарты, исключение из Endpoints, влияние на rollout).
