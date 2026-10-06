# 6. Провал проб в разных комбинациях: связь с поведением системы

Задание: **Пофейлить пробы в разных комбинациях и проследить связь между ними и поведением системы.**

## Стенд

Для этой миссии нужен способ **ломать пробу на живом поде**, не пересоздавая его (иначе не отделить эффект пробы от эффекта рестарта). Поэтому вместо одного общего пути `/` каждая проба получила свой собственный URL, за которым стоит обычный файл в корне nginx:

| Проба | Путь | Файл |
|---|---|---|
| `startupProbe` | `/startup` | `/usr/share/nginx/html/startup` |
| `livenessProbe` | `/live` | `/usr/share/nginx/html/live` |
| `readinessProbe` | `/ready` | `/usr/share/nginx/html/ready` |

Файлы создаются командой контейнера при старте. Удаляем файл через `kubectl exec` → nginx начинает отдавать `404` → соответствующая проба падает. Возвращаем файл → проба снова зелёная. Это даёт точечное управление: можно уронить ровно одну пробу на ровно одном поде.

Файл [06_probes-fail-demo.yaml](06_probes-fail-demo.yaml):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probes-fail
  labels:
    app: probes-fail
spec:
  replicas: 3
  selector:
    matchLabels:
      app: probes-fail
  template:
    metadata:
      labels:
        app: probes-fail
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          # при старте создаём "маркеры здоровья" — файлы, которые отдаются пробам.
          # Удалив файл через kubectl exec, получаем 404 и провал нужной пробы.
          command:
            - /bin/sh
            - -c
            - >
              echo ok > /usr/share/nginx/html/live &&
              echo ok > /usr/share/nginx/html/ready &&
              echo ok > /usr/share/nginx/html/startup &&
              exec nginx -g 'daemon off;'
          ports:
            - containerPort: 80
          startupProbe:
            httpGet:
              path: /startup
              port: 80
            periodSeconds: 2
            failureThreshold: 15
          livenessProbe:
            httpGet:
              path: /live
              port: 80
            periodSeconds: 5
            timeoutSeconds: 1
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 80
            periodSeconds: 5
            timeoutSeconds: 1
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: probes-fail-svc
spec:
  selector:
    app: probes-fail
  ports:
    - port: 80
      targetPort: 80
```

Вместе с деплойментом создан `Service` — без него не увидеть главный эффект readiness (исключение пода из Endpoints).

```bash
kubectl apply -f 06_probes-fail-demo.yaml
kubectl rollout status deploy/probes-fail --timeout=120s
```

```
deployment.apps/probes-fail created
service/probes-fail-svc created
Waiting for deployment "probes-fail" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "probes-fail" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "probes-fail" rollout to finish: 2 of 3 updated replicas are available...
deployment "probes-fail" successfully rolled out
```

Исходное (здоровое) состояние — 3 пода, все три в Endpoints:

```bash
kubectl get pods -l app=probes-fail -o wide
kubectl get endpoints probes-fail-svc
```

```
NAME                           READY   STATUS    RESTARTS   AGE   IP            NODE
probes-fail-75dd85dfb8-5hm6w   1/1     Running   0          4s    10.244.0.60   minikube
probes-fail-75dd85dfb8-g8l7s   1/1     Running   0          4s    10.244.0.61   minikube
probes-fail-75dd85dfb8-ljrqn   1/1     Running   0          4s    10.244.0.62   minikube

NAME              ENDPOINTS                                      AGE
probes-fail-svc   10.244.0.60:80,10.244.0.61:80,10.244.0.62:80   4s
```

---

## Сценарий A: падает только readiness (liveness жива)

Роняем readiness на **одном** поде `...-5hm6w`:

```bash
kubectl exec probes-fail-75dd85dfb8-5hm6w -- rm /usr/share/nginx/html/ready
```

Наблюдение по времени:

```
--- t+0s ---
probes-fail-75dd85dfb8-5hm6w   1/1   Running   0     23s
probes-fail-75dd85dfb8-g8l7s   1/1   Running   0     23s
probes-fail-75dd85dfb8-ljrqn   1/1   Running   0     23s
--- t+6s ---
probes-fail-75dd85dfb8-5hm6w   1/1   Running   0     29s      <- ещё Ready: не набрано 3 провала
--- t+12s ---
probes-fail-75dd85dfb8-5hm6w   0/1   Running   0     35s      <- failureThreshold=3 набран, под NotReady
probes-fail-75dd85dfb8-g8l7s   1/1   Running   0     35s
probes-fail-75dd85dfb8-ljrqn   1/1   Running   0     35s
--- t+24s ---
probes-fail-75dd85dfb8-5hm6w   0/1   Running   0     47s      <- RESTARTS так и остаётся 0
```

```bash
kubectl get endpoints probes-fail-svc
kubectl get deploy probes-fail
```

```
NAME              ENDPOINTS                       AGE
probes-fail-svc   10.244.0.61:80,10.244.0.62:80   47s        <- IP 10.244.0.60 исчез

NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   2/3     3            2           47s
```

```bash
kubectl describe pod probes-fail-75dd85dfb8-5hm6w
```

```
Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       False
  ContainersReady             False
  PodScheduled                True

Events:
  Type     Reason     Age               From      Message
  ----     ------     ----              ----      -------
  Warning  Unhealthy  3s (x7 over 29s)  kubelet   spec.containers{nginx}: Readiness probe failed: HTTP probe failed with statuscode: 404
```

```bash
kubectl get pod probes-fail-75dd85dfb8-5hm6w -o jsonpath='{range .status.containerStatuses[*]}started={.started} ready={.ready} restartCount={.restartCount} state={.state}{"\n"}{end}'
```

```
started=true ready=false restartCount=0 state={"running":{"startedAt":"2026-08-20T15:11:19Z"}}
```

**Наблюдения:**
- Контейнер **продолжает работать**: `state=running`, `restartCount=0`, статус пода `Running`. Kubernetes не считает провал readiness поводом что-либо перезапускать.
- Меняется только `READY 1/1 → 0/1` и условия пода `Ready=False`, `ContainersReady=False`.
- Под **немедленно выпадает из Endpoints сервиса** — трафик на него больше не идёт.
- Deployment показывает `2/3 AVAILABLE`: readiness напрямую формирует счётчик доступных реплик.
- Провал сработал не мгновенно, а через `periodSeconds × failureThreshold = 5 × 3 = 15 c` (между t+6s и t+12s).

Возвращаем файл:

```bash
kubectl exec probes-fail-75dd85dfb8-5hm6w -- sh -c 'echo ok > /usr/share/nginx/html/ready'
```

```
--- t+7s ---
probes-fail-75dd85dfb8-5hm6w   1/1   Running   0     69s

NAME              ENDPOINTS                                      AGE
probes-fail-svc   10.244.0.60:80,10.244.0.61:80,10.244.0.62:80   76s

NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   3/3     3            3           77s
```

**Наблюдение:** восстановление занимает один успешный цикл (`successThreshold=1`, т.е. ~5 c) — под возвращается в Endpoints без всякого рестарта. Провал readiness **полностью обратим**.

---

## Сценарий B: падает только liveness (readiness жива)

Роняем liveness на поде `...-g8l7s`:

```bash
kubectl exec probes-fail-75dd85dfb8-g8l7s -- rm /usr/share/nginx/html/live
```

```
--- t+0s ---
probes-fail-75dd85dfb8-g8l7s   1/1   Running   0            87s
--- t+10s ---
probes-fail-75dd85dfb8-g8l7s   1/1   Running   0            97s
--- t+15s ---
probes-fail-75dd85dfb8-g8l7s   1/1   Running   1 (2s ago)   102s   <- контейнер перезапущен
--- t+30s ---
probes-fail-75dd85dfb8-g8l7s   1/1   Running   1 (19s ago)  119s
```

Endpoints на протяжении всего сценария:

```
probes-fail-svc   10.244.0.60:80,10.244.0.61:80,10.244.0.62:80
```

```bash
kubectl describe pod probes-fail-75dd85dfb8-g8l7s
```

```
    State:          Running
      Started:      Thu, 20 Aug 2026 18:12:57 +0300
    Last State:     Terminated
      Reason:       Completed
      Exit Code:    0
      Started:      Thu, 20 Aug 2026 18:11:19 +0300
      Finished:     Thu, 20 Aug 2026 18:12:57 +0300
    Ready:          True
    Restart Count:  1

Events:
  Warning  Unhealthy  25s (x3 over 35s)   kubelet   spec.containers{nginx}: Liveness probe failed: HTTP probe failed with statuscode: 404
  Normal   Killing    25s                 kubelet   spec.containers{nginx}: Container nginx failed liveness probe, will be restarted
```

**Наблюдения:**
- Провал liveness → `Killing ... will be restarted`, `Restart Count: 1`. Это **единственная** проба, которая перезапускает контейнер.
- Перезапускается **контейнер внутри пода**, а не под: имя пода, его IP, `AGE` и узел не изменились — сменился только Container ID и появился `Last State: Terminated`.
- `Exit Code: 0` — контейнер не падал сам, его корректно остановил kubelet.
- **Из Endpoints под фактически не выпал**: readiness была зелёной, а окно рестарта (~1–2 с) короче, чем период readiness-пробы (5 с). При редких рестартах liveness почти незаметна для сервиса — и именно поэтому опасна: приложение может циклически убиваться, а сервис будет «мигать» трафиком в перезапускающийся под.
- Рестарт заново выполнил `command` контейнера, а значит **пересоздал удалённый файл** — проблема «вылечилась» рестартом. Это ровно та ситуация, ради которой liveness и придумана: перезапуск как способ выйти из зависшего состояния.

---

## Сценарий C: liveness и readiness падают одновременно

Роняем обе пробы на поде `...-ljrqn`:

```bash
kubectl exec probes-fail-75dd85dfb8-ljrqn -- rm /usr/share/nginx/html/live /usr/share/nginx/html/ready
```

```
--- t+10s ---
probes-fail-75dd85dfb8-ljrqn   1/1   Running   0            2m27s
  EP: 10.244.0.60:80,10.244.0.61:80,10.244.0.62:80
--- t+15s ---
probes-fail-75dd85dfb8-ljrqn   0/1   Running   1 (4s ago)   2m32s   <- NotReady И перезапуск
  EP: 10.244.0.60:80,10.244.0.61:80                                 <- .62 выпал из Endpoints
--- t+20s ---
probes-fail-75dd85dfb8-ljrqn   1/1   Running   1 (9s ago)   2m37s   <- рестарт вернул файлы
  EP: 10.244.0.60:80,10.244.0.61:80,10.244.0.62:80
```

```
Events:
  Warning  Unhealthy  22s (x2 over 29s)    kubelet   spec.containers{nginx}: Readiness probe failed: HTTP probe failed with statuscode: 404
  Warning  Unhealthy  20s (x3 over 32s)    kubelet   spec.containers{nginx}: Liveness probe failed: HTTP probe failed with statuscode: 404
  Normal   Killing    20s                  kubelet   spec.containers{nginx}: Container nginx failed liveness probe, will be restarted
```

**Наблюдения:**
- Эффекты **складываются и не мешают друг другу**: под и выпал из Endpoints (эффект readiness), и был перезапущен (эффект liveness). Пробы работают независимо, у каждой свой счётчик провалов.
- Пробы стартовали одновременно и имеют одинаковые `period=5s, failure=3`, поэтому оба эффекта наступили практически в одну секунду. В реальных конфигурациях readiness обычно делают **более чувствительной** (меньше `failureThreshold`), чтобы под успел уйти из балансировки *до* того, как его убьют — иначе часть запросов попадёт в уже умирающий контейнер.
- Счётчик readiness успел зафиксировать только 2 провала (`x2`) — контейнер убили раньше, чем набралось 3. После рестарта счётчики обнуляются.

---

## Сценарий D: падает startup probe

Здесь важно проверить главный вопрос: **работают ли liveness/readiness, пока startup не прошла?** Для этого — отдельный деплоймент [06_probes-fail-startup.yaml](06_probes-fail-startup.yaml), где startup заведомо провальная, а liveness сделана **максимально агрессивной и тоже провальной** (`period=1s, failureThreshold=1` — если бы она работала, контейнер умирал бы через секунду):

```yaml
          # startup заведомо не проходит: такого пути нет -> 404
          startupProbe:
            httpGet:
              path: /no-such-startup
              port: 80
            periodSeconds: 2
            failureThreshold: 5      # ~10 c и контейнер будет убит
          # liveness тоже заведомо провальная и очень агрессивная:
          # если бы она работала, контейнер умер бы через 1 секунду
          livenessProbe:
            httpGet:
              path: /no-such-live
              port: 80
            periodSeconds: 1
            failureThreshold: 1
          readinessProbe:            # эта, наоборот, заведомо успешная
            httpGet:
              path: /
              port: 80
            periodSeconds: 2
```

```bash
kubectl apply -f 06_probes-fail-startup.yaml
```

```
--- t+0s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   ContainerCreating   0            0s
--- t+8s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   Running             0            8s    <- живёт дольше 1 c!
--- t+16s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   Running             1 (7s ago)   17s
--- t+24s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   Running             2 (3s ago)   25s
--- t+40s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   Running             3 (9s ago)   41s
--- t+48s ---
probes-fail-startup-848d5ddfcc-2v5vl   0/1   CrashLoopBackOff    3 (8s ago)   50s
```

```bash
kubectl describe pod probes-fail-startup-848d5ddfcc-2v5vl
```

```
    Ready:          False
    Restart Count:  4
    Liveness:       http-get http://:80/no-such-live delay=0s timeout=1s period=1s #success=1 #failure=1
    Readiness:      http-get http://:80/ delay=0s timeout=1s period=2s #success=1 #failure=3
    Startup:        http-get http://:80/no-such-startup delay=0s timeout=1s period=2s #success=1 #failure=5

Events:
  Type     Reason     Age                From      Message
  ----     ------     ----               ----      -------
  Normal   Killing    26s (x4 over 58s)  kubelet   spec.containers{nginx}: Container nginx failed startup probe, will be restarted
  Warning  BackOff    25s (x3 over 26s)  kubelet   spec.containers{nginx}: Back-off restarting failed container nginx ...
  Warning  Unhealthy  1s (x21 over 66s)  kubelet   spec.containers{nginx}: Startup probe failed: HTTP probe failed with statuscode: 404
```

```bash
kubectl get pod ... -o jsonpath='{range .status.containerStatuses[*]}started={.started} ready={.ready} restartCount={.restartCount}{"\n"}{end}'
```

```
started=false ready=false restartCount=4
```

**Наблюдения:**
- В событиях **нет ни одной записи `Liveness probe failed` и ни одной `Readiness probe failed`** — при том что liveness настроена «убить через 1 секунду», а readiness была бы успешной. Пока startup не прошла, обе другие пробы kubelet **вообще не запускает**. Это и есть главный смысл startup-пробы: защитить медленно стартующее приложение от преждевременного убийства по liveness.
- Провал startup ведёт себя как liveness — `Killing ... failed startup probe, will be restarted`, но по **своему** таймауту: `period=2s × failure=5 = 10 c` (`Started 18:15:01 → Finished 18:15:11`).
- Поле `started=false` в `containerStatuses` — прямой индикатор «startup ещё не пройдена». Это отдельный флаг, не путать с `ready`.
- Цикл «старт → провал startup → рестарт» повторяется, и с 3–4-го раза kubelet включает экспоненциальную задержку → статус `CrashLoopBackOff`. Под **никогда не становится Ready** и никогда не попадает в Endpoints.

### D2: чиним startup, оставляя liveness сломанной

Проверка «от обратного»: если startup начнёт проходить, liveness должна немедленно ожить.

```bash
kubectl patch deploy probes-fail-startup --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/httpGet/path","value":"/"}]'
```

```
--- t+8s ---
probes-fail-startup-646557799d-lh4fx   0/1   Running            2 (1s ago)    8s
--- t+16s ---
probes-fail-startup-646557799d-lh4fx   0/1   CrashLoopBackOff   2 (6s ago)    16s
```

```
Events:
  Warning  Unhealthy  23s (x4 over 43s)  kubelet   spec.containers{nginx}: Liveness probe failed: HTTP probe failed with statuscode: 404
  Normal   Killing    23s (x4 over 42s)  kubelet   spec.containers{nginx}: Container nginx failed liveness probe, will be restarted
  Warning  Unhealthy  22s (x2 over 36s)  kubelet   spec.containers{nginx}: Readiness probe failed: Get "http://10.244.0.64:80/": dial tcp ...: connect: connection refused
  Warning  BackOff    18s (x8 over 37s)  kubelet   spec.containers{nginx}: Back-off restarting failed container nginx ...
```

**Наблюдение:** как только startup стала проходить, **сразу же** появились события и от liveness, и от readiness — которых в сценарии D не было вовсе. Причина рестартов в событиях сменилась со `failed startup probe` на `failed liveness probe`, а темп рестартов вырос (liveness с `period=1s` убивает почти мгновенно, вместо 10 c у startup). Заодно видно, как выглядит readiness-провал по **другой** причине: не `404`, а `connection refused` — контейнера в этот момент просто нет.

Демо удалено, чтобы не крутить бесконечный CrashLoop:

```bash
kubectl delete -f 06_probes-fail-startup.yaml
```

---

## Сценарий E: сломанная readiness в новой версии блокирует rollout

Возвращаемся к `probes-fail` и ломаем readiness **на уровне шаблона** (т.е. для всех новых подов), одновременно сократив дедлайн прогресса, чтобы не ждать дефолтные 600 c:

```bash
kubectl patch deploy probes-fail --type=json -p='[
  {"op":"add","path":"/spec/progressDeadlineSeconds","value":60},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/no-such-ready"}
]'
kubectl rollout status deploy/probes-fail --timeout=75s
```

```
deployment.apps/probes-fail patched
Waiting for deployment "probes-fail" rollout to finish: 1 out of 3 new replicas have been updated...
error: deployment "probes-fail" exceeded its progress deadline
```

```bash
kubectl get deploy probes-fail
kubectl get rs -l app=probes-fail
kubectl get pods -l app=probes-fail
kubectl get endpoints probes-fail-svc
```

```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   3/3     1            3           6m41s

NAME                     DESIRED   CURRENT   READY   AGE
probes-fail-75dd85dfb8   3         3         3       6m41s     <- старая RS цела
probes-fail-79949c6968   1         1         0       71s       <- новая RS застряла на 1 неготовом поде

NAME                           READY   STATUS    RESTARTS        AGE
probes-fail-75dd85dfb8-5hm6w   1/1     Running   0               6m41s
probes-fail-75dd85dfb8-g8l7s   1/1     Running   1 (5m1s ago)    6m41s
probes-fail-75dd85dfb8-ljrqn   1/1     Running   1 (4m13s ago)   6m41s
probes-fail-79949c6968-fh8n8   0/1     Running   0               71s

NAME              ENDPOINTS                                      AGE
probes-fail-svc   10.244.0.60:80,10.244.0.61:80,10.244.0.62:80   6m41s
```

```bash
kubectl describe deploy probes-fail
```

```
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    False   ProgressDeadlineExceeded
OldReplicaSets:  probes-fail-75dd85dfb8 (3/3 replicas created)
```

**Наблюдения:**
- Rolling update при `maxUnavailable=25%` (для 3 реплик → 0) **не имеет права** гасить старые поды, пока новый не станет Ready. Новый под Ready не становится никогда → раскатка встаёт на первом поде и дальше не идёт.
- `AVAILABLE 3/3` и `Available=True` — **приложение продолжает работать на старой версии**, пользователи ничего не замечают. Новый (битый) под в Endpoints не попал: его IP отсутствует в списке.
- Через `progressDeadlineSeconds` появляется `Progressing=False / ProgressDeadlineExceeded`, и `kubectl rollout status` завершается с ненулевым кодом — это тот сигнал, по которому CI/CD должен автоматически откатывать релиз.
- Вывод: **readiness — главная защита от выкатки сломанной версии**. Она превращает «плохой деплой» в «деплой, который не состоялся».

---

## Сценарий F: сломанная liveness в новой версии — rollout проходит, а потом всё разваливается

Тот же деплоймент, но теперь наоборот: readiness чиним, liveness ломаем для всех новых подов.

```bash
kubectl patch deploy probes-fail --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/no-such-live"},
  {"op":"replace","path":"/spec/progressDeadlineSeconds","value":120}
]'
```

```
--- t+12s ---
probes-fail   3/3   3     3     7m9s                                    <- rollout УСПЕШНО завершён
  probes-fail-8b8bb464d-4mg7l   1/1   Running   0     11s
  probes-fail-8b8bb464d-7kkrz   1/1   Running   0     14s
  probes-fail-8b8bb464d-bdlbl   1/1   Running   0     6s
  EP: 10.244.0.66:80,10.244.0.67:80,10.244.0.68:80

--- t+36s ---
probes-fail   3/3   3     3     7m33s
  probes-fail-8b8bb464d-4mg7l   1/1   Running   2 (3s ago)    35s        <- пошли рестарты
  probes-fail-8b8bb464d-7kkrz   1/1   Running   2 (6s ago)    38s
  probes-fail-8b8bb464d-bdlbl   1/1   Running   1 (13s ago)   30s
  EP: 10.244.0.66:80,10.244.0.67:80,10.244.0.68:80

--- t+48s ---
probes-fail   1/3   3     1     7m46s                                    <- доступность просела
  probes-fail-8b8bb464d-4mg7l   1/1   Running   2 (16s ago)   48s
  probes-fail-8b8bb464d-7kkrz   0/1   Running   3 (3s ago)    51s
  probes-fail-8b8bb464d-bdlbl   0/1   Running   2 (5s ago)    43s
  EP: 10.244.0.67:80                                                     <- в сервисе остался 1 эндпоинт

--- t+72s ---
probes-fail   1/3   3     1     8m10s
  probes-fail-8b8bb464d-4mg7l   0/1   CrashLoopBackOff   3 (9s ago)    73s
  probes-fail-8b8bb464d-7kkrz   0/1   CrashLoopBackOff   3 (13s ago)   76s
  probes-fail-8b8bb464d-bdlbl   1/1   Running            3 (10s ago)   68s
  EP: 10.244.0.68:80

--- t+96s ---
probes-fail   3/3   3     3     8m36s                                    <- «здоров» ровно между рестартами
  EP: 10.244.0.67:80,10.244.0.68:80
```

**Наблюдения:**
- **Rollout прошёл успешно** — старые поды удалены, новые объявлены доступными (`3/3`). Deployment-контроллер смотрит только на readiness; про liveness он ничего не знает.
- Деградация началась **после** завершения раскатки, когда liveness набрала свои 3 провала. Все три пода одновременно ушли в цикл рестартов.
- Показатель `READY` и состав Endpoints **колеблются** (`3/3 → 1/3 → 3/3 → 1/3`): каждый рестарт ненадолго выбивает под из балансировки, пока контейнер поднимается заново. Сервис при этом формально жив, но часть запросов теряется.
- Старой ревизии, на которую можно было бы «не переключаться», уже нет — откатываться приходится вручную.
- **Ключевая асимметрия:** сломанная readiness = раскатка не состоялась, продакшн цел. Сломанная liveness = раскатка состоялась, продакшн сломался. Ошибка в liveness обходится сильно дороже.

### Восстановление

```bash
kubectl rollout history deploy/probes-fail
kubectl rollout undo deploy/probes-fail --to-revision=1
kubectl rollout status deploy/probes-fail --timeout=120s
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>

deployment.apps/probes-fail rolled back
Waiting for deployment "probes-fail" rollout to finish: 1 old replicas are pending termination...
deployment "probes-fail" successfully rolled out

NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   3/3     3            3           9m17s
probes-fail-75dd85dfb8-cg2pm   1/1   Running   0     28s
probes-fail-75dd85dfb8-lfr72   1/1   Running   0     30s
probes-fail-75dd85dfb8-whg9p   1/1   Running   0     24s

probes-fail-svc   10.244.0.69:80,10.244.0.70:80,10.244.0.71:80
```

---

## Сценарий G: readiness падает на всех подах сразу

Крайний случай — роняем readiness на всех трёх подах:

```bash
for p in $(kubectl get pods -l app=probes-fail -o name); do
  kubectl exec $p -- rm /usr/share/nginx/html/ready
done
```

```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   0/3     3            0           9m49s

probes-fail-75dd85dfb8-cg2pm   0/1   Running   0     61s
probes-fail-75dd85dfb8-lfr72   0/1   Running   0     63s
probes-fail-75dd85dfb8-whg9p   0/1   Running   0     57s

NAME              ENDPOINTS   AGE
probes-fail-svc               9m50s          <- ПУСТО

Conditions:
  Type           Status  Reason
  ----           ------  ------
  Progressing    True    NewReplicaSetAvailable
  Available      False   MinimumReplicasUnavailable
```

**Наблюдения:**
- Endpoints сервиса **полностью пусты** — обращение к сервису получит `connection refused` / таймаут, хотя все поды `Running` и ни один не перезапущен. Классическая картина «поды живы, сервис не отвечает».
- `Available=False / MinimumReplicasUnavailable` на Deployment — это условие считается именно по readiness.
- Kubernetes при этом **не предпринимает ничего**: не перезапускает, не пересоздаёт поды. Провал readiness — не повод для действий, это лишь сигнал «не шлите сюда трафик».

Восстановление (файлы возвращены) — всё вернулось за один цикл проб:

```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
probes-fail   3/3     3            3           10m
probes-fail-svc   10.244.0.69:80,10.244.0.70:80,10.244.0.71:80
```

---

## Сводная таблица: комбинации провалов

| # | startup | liveness | readiness | Рестарт контейнера | В Endpoints | Статус пода | Итог |
|---|---|---|---|---|---|---|---|
| — | ✅ | ✅ | ✅ | нет | да | `1/1 Running` | норма |
| A | ✅ | ✅ | ❌ | **нет** | **нет** | `0/1 Running` | под жив, трафика нет; обратимо без рестарта |
| B | ✅ | ❌ | ✅ | **да** | да (мигает) | `1/1 Running`, RESTARTS↑ | рестарт «лечит» состояние |
| C | ✅ | ❌ | ❌ | **да** | **нет** | `0/1 Running`, RESTARTS↑ | эффекты складываются независимо |
| D | ❌ | ❌ (не запускается) | ✅ (не запускается) | **да**, по таймауту startup | нет | `0/1 CrashLoopBackOff` | liveness/readiness заблокированы, `started=false` |
| E | ✅ | ✅ | ❌ (в новой версии) | нет | нет (только новый под) | rollout завис | старая версия продолжает работать, `ProgressDeadlineExceeded` |
| F | ✅ | ❌ (в новой версии) | ✅ | да, на всех подах | мигает | rollout **успешен**, затем CrashLoop | продакшн сломан выкаткой |
| G | ✅ | ✅ | ❌ на всех | нет | **пусто** | `0/1 Running` ×3 | `Available=False`, сервис не отвечает |

## Тайминги: через сколько наступает эффект

| Проба | Формула | В этом стенде | Что происходит |
|---|---|---|---|
| readiness | `periodSeconds × failureThreshold` | 5 × 3 = **15 c** | под уходит из Endpoints |
| liveness | `periodSeconds × failureThreshold` | 5 × 3 = **15 c** | контейнер убивается и стартует заново |
| startup | `periodSeconds × failureThreshold` | 2 × 5 = **10 c** (в D-демо) | контейнер убивается, liveness/readiness всё это время не работают |
| возврат в Ready | `periodSeconds × successThreshold` | 5 × 1 = **5 c** | под возвращается в Endpoints |

## Выводы

1. **У каждой пробы ровно одна зона ответственности, и они не пересекаются:**
   - `readiness` → **состав Endpoints** и счётчик `AVAILABLE`. Никогда не перезапускает.
   - `liveness` → **перезапуск контейнера**. На маршрутизацию напрямую не влияет — только косвенно, через недоступность во время рестарта.
   - `startup` → **шлюз**: пока не пройдена, liveness и readiness не выполняются вовсе; её собственный провал убивает контейнер.
2. **Комбинации не создают новых эффектов** — они просто складываются (сценарий C). Единственное исключение — startup, которая не складывается, а **подавляет** остальные пробы (сценарий D).
3. **Пробы не мгновенны.** Между реальной поломкой и реакцией системы проходит `period × failureThreshold`. Проектируя пробы, этот лаг нужно закладывать: слишком большой — трафик уходит в мёртвый под; слишком маленький — под выбивается из балансировки от случайного таймаута.
4. **Readiness должна быть чувствительнее liveness** (меньше `failureThreshold` и/или `periodSeconds`). Иначе, как в сценарии C, контейнер убьют раньше, чем он успеет уйти из балансировки, и часть запросов гарантированно потеряется.
5. **Readiness защищает раскатку, liveness — нет.** Сломанная readiness останавливает rollout и спасает продакшн (E); сломанная liveness пропускает rollout и ломает продакшн уже после «успешного» деплоя (F). Поэтому liveness стоит делать максимально простой (жив ли процесс), а всю проверку зависимостей — БД, кэшей, внешних API — выносить в readiness.
6. **Провал readiness полностью обратим и не имеет побочных эффектов** — под возвращается в строй за один успешный цикл. Провал liveness необратим: контейнер уже перезапущен, состояние в памяти потеряно, счётчик `RESTARTS` растёт навсегда.
7. **Диагностика всегда идёт через `kubectl describe pod`:** секция `Events` прямо называет и пробу, и причину (`Readiness probe failed: ... statuscode: 404`, `Container nginx failed liveness probe, will be restarted`, `failed startup probe`), а `status.containerStatuses` даёт три ключевых флага — `started` (startup), `ready` (readiness) и `restartCount` (liveness).
