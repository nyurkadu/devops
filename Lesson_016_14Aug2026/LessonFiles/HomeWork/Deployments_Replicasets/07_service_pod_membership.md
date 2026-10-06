# 7. Service и управление составом подов

Задание: **Создать сервис (`Service`) и управлять составом подов (добавлять и удалять).**

## Идея стенда

Состав сервиса определяется **только лейблами**, а не тем, кто создал под. Чтобы это было видно наглядно, поды несут **два независимых лейбла**:

| Лейбл | Кто им пользуется | Что означает |
|---|---|---|
| `app: svc-demo` | `selector` ReplicaSet'а | **владение**: этот под принадлежит контроллеру |
| `tier: web` | `selector` Service'а | **членство**: этот под получает трафик сервиса |

Такое разделение позволяет менять состав сервиса, не трогая Deployment, и наоборот. Если бы оба селектора смотрели на один лейбл (как обычно и делают), эти два эффекта было бы не разделить.

Каждый под отдаёт своё имя в `index.html` — по ответу сразу видно, кто именно обслужил запрос.

Файл [07_svc-demo.yaml](07_svc-demo.yaml):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: svc-demo
  labels:
    app: svc-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: svc-demo          # по этому лейблу поды принадлежат ReplicaSet'у
  template:
    metadata:
      labels:
        app: svc-demo        # "владение" контроллером
        tier: web            # "членство" в сервисе — отдельный лейбл
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          # каждый под представляется своим именем — так видно, кто ответил через сервис
          command:
            - /bin/sh
            - -c
            - >
              echo "I am $HOSTNAME" > /usr/share/nginx/html/index.html &&
              exec nginx -g 'daemon off;'
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: svc-demo-svc
spec:
  type: ClusterIP
  selector:
    tier: web                # сервис отбирает поды по tier, а не по app
  ports:
    - name: http
      port: 8080             # порт самого сервиса
      targetPort: 80         # порт в контейнере
```

## Создание сервиса

```bash
kubectl apply -f 07_svc-demo.yaml
kubectl rollout status deploy/svc-demo --timeout=90s
```

```
deployment.apps/svc-demo created
service/svc-demo-svc created
deployment "svc-demo" successfully rolled out
```

```bash
kubectl get svc svc-demo-svc -o wide
kubectl describe svc svc-demo-svc
```

```
NAME           TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE   SELECTOR
svc-demo-svc   ClusterIP   10.105.131.225   <none>        8080/TCP   2s    tier=web

Name:                     svc-demo-svc
Namespace:                default
Selector:                 tier=web
Type:                     ClusterIP
IP:                       10.105.131.225
Port:                     http  8080/TCP
TargetPort:               80/TCP
Endpoints:                10.244.0.77:80,10.244.0.78:80
Session Affinity:         None
Internal Traffic Policy:  Cluster
```

```bash
kubectl get pods -l tier=web -o wide
kubectl get endpoints svc-demo-svc
```

```
svc-demo-77dcb4b498-n8vlj   1/1   10.244.0.78
svc-demo-77dcb4b498-zxx52   1/1   10.244.0.77

NAME           ENDPOINTS                       AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80   2s
```

**Наблюдения:**
- `CLUSTER-IP 10.105.131.225` — виртуальный адрес сервиса. Он не принадлежит ни одному поду и не пингуется как обычный хост; трафик на него перехватывает и раскидывает kube-proxy.
- `PORT(S) 8080/TCP` — порт **сервиса**; `TargetPort: 80` — порт **контейнера**. Эти номера намеренно сделаны разными, чтобы было видно, что сервис умеет их транслировать.
- В `Endpoints` попали ровно те IP, что у подов с `tier=web`.

### Клиент для проверки

Отдельный под-клиент внутри кластера — обращаться к ClusterIP снаружи нельзя:

```bash
kubectl run client --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl exec client -- sh -c 'for i in $(seq 1 8); do wget -qO- http://svc-demo-svc:8080/; done' | sort | uniq -c
```

```
      3 I am svc-demo-77dcb4b498-n8vlj
      5 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдения:**
- Обращение идёт **по DNS-имени** `svc-demo-svc:8080` — имя сервиса резолвится CoreDNS в его ClusterIP (полная форма: `svc-demo-svc.default.svc.cluster.local`).
- Запросы распределяются между всеми подами сервиса, но **не строго по кругу**: kube-proxy выбирает бэкенд случайно, поэтому счётчики 3/5, а не 4/4.

---

## A. Добавляем поды: `kubectl scale` 2 → 4

```bash
kubectl scale deploy/svc-demo --replicas=4
```

```
NAME                        READY   IP
svc-demo-77dcb4b498-c9kd8   1/1     10.244.0.79      <- новый
svc-demo-77dcb4b498-n8vlj   1/1     10.244.0.78
svc-demo-77dcb4b498-zpkl6   1/1     10.244.0.80      <- новый
svc-demo-77dcb4b498-zxx52   1/1     10.244.0.77

NAME           ENDPOINTS                                                    AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80,10.244.0.79:80 + 1 more...     22s
```

```bash
kubectl exec client -- sh -c 'for i in $(seq 1 12); do wget -qO- http://svc-demo-svc:8080/; done' | sort | uniq -c
```

```
      3 I am svc-demo-77dcb4b498-c9kd8
      4 I am svc-demo-77dcb4b498-n8vlj
      4 I am svc-demo-77dcb4b498-zpkl6
      1 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдение:** новые поды получили лейбл `tier=web` из шаблона → сервис подхватил их **автоматически**, никаких действий над самим Service не потребовалось. Трафик пошёл на все четыре.

## B. Убираем поды: `kubectl scale` 4 → 2

```bash
kubectl scale deploy/svc-demo --replicas=2
```

```
svc-demo-77dcb4b498-n8vlj   1/1   Running   10.244.0.78
svc-demo-77dcb4b498-zxx52   1/1   Running   10.244.0.77

NAME           ENDPOINTS                       AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80   41s

      4 I am svc-demo-77dcb4b498-n8vlj
      4 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдение:** удалённые поды исчезли из Endpoints, трафик на них больше не идёт. Управление составом сервиса через масштабирование Deployment — самый обычный, «штатный» способ.

---

## C. Добавляем в сервис под, не принадлежащий Deployment

Ключевая проверка: сервис отбирает поды **по лейблу**, а не по владельцу. Создаём одиночный под с `tier=web`, но **без** `app=svc-demo` — файл [07_svc-demo-standalone.yaml](07_svc-demo-standalone.yaml):

```yaml
# Одиночный под: НЕ принадлежит Deployment/ReplicaSet (нет лейбла app=svc-demo),
# но имеет tier=web -> попадает в тот же Service.
apiVersion: v1
kind: Pod
metadata:
  name: standalone-web
  labels:
    tier: web
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      command:
        - /bin/sh
        - -c
        - >
          echo "I am STANDALONE pod (no Deployment)" > /usr/share/nginx/html/index.html &&
          exec nginx -g 'daemon off;'
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
      readinessProbe:
        httpGet:
          path: /
          port: 80
        periodSeconds: 3
```

```bash
kubectl apply -f 07_svc-demo-standalone.yaml
kubectl wait --for=condition=Ready pod/standalone-web --timeout=90s
```

```
NAME                        READY   IP
standalone-web              1/1     10.244.0.81       <- одиночный под
svc-demo-77dcb4b498-n8vlj   1/1     10.244.0.78
svc-demo-77dcb4b498-zxx52   1/1     10.244.0.77

NAME           ENDPOINTS                                      AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80,10.244.0.81:80   57s

NAME       READY   UP-TO-DATE   AVAILABLE   AGE
svc-demo   2/2     2            2           57s               <- Deployment не изменился
```

Первая проверка трафика — сразу после появления эндпоинта:

```
      4 I am svc-demo-77dcb4b498-n8vlj
      5 I am svc-demo-77dcb4b498-zxx52
```

Повтор через несколько секунд:

```bash
kubectl exec client -- sh -c 'for i in $(seq 1 15); do wget -qO- http://svc-demo-svc:8080/; done' | sort | uniq -c
```

```
      2 I am STANDALONE pod (no Deployment)
      9 I am svc-demo-77dcb4b498-n8vlj
      4 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдения:**
- Одиночный под **вошёл в сервис наравне с подами Deployment** — сервису безразлично, есть ли у пода контроллер. Достаточно совпадения лейблов и готовности (`Ready`).
- Deployment остался `2/2` и о новом поде ничего не знает: его селектор `app=svc-demo` этот под не захватывает, а значит ReplicaSet его не усыновляет и не считает своим.
- В первом прогоне запросы на новый под ещё **не попали**, хотя IP уже был в Endpoints. Между записью эндпоинта в API и обновлением правил на узле есть лаг kube-proxy — в реальной эксплуатации это те самые «несколько сотен миллисекунд», из-за которых свежий под пару мгновений не получает трафик.

---

## D. Убираем под из сервиса лейблом (под остаётся жив)

Снимаем `tier` у одного пода Deployment'а:

```bash
kubectl label pod svc-demo-77dcb4b498-n8vlj tier-
```

```
pod/svc-demo-77dcb4b498-n8vlj unlabeled
```

```bash
kubectl get pods -l tier=web
kubectl get endpoints svc-demo-svc
```

```
standalone-web              1/1   10.244.0.81
svc-demo-77dcb4b498-zxx52   1/1   10.244.0.77

NAME           ENDPOINTS                       AGE
svc-demo-svc   10.244.0.77:80,10.244.0.81:80   82s        <- 10.244.0.78 выбыл
```

Что при этом с самим подом:

```bash
kubectl get pod svc-demo-77dcb4b498-n8vlj -o wide
kubectl get pod svc-demo-77dcb4b498-n8vlj -o jsonpath='{.metadata.labels}{"\n"}{.metadata.ownerReferences[*].kind}/{.metadata.ownerReferences[*].name}{"\n"}'
kubectl get deploy svc-demo
```

```
svc-demo-77dcb4b498-n8vlj   1/1   Running   10.244.0.78

{"app":"svc-demo","pod-template-hash":"77dcb4b498"}
ReplicaSet/svc-demo-77dcb4b498

NAME       READY   UP-TO-DATE   AVAILABLE   AGE
svc-demo   2/2     2            2           82s
```

```
      5 I am STANDALONE pod (no Deployment)
      5 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдения:**
- Под **работает как ни в чём не бывало** (`1/1 Running`), но трафика больше не получает — он вышел из сервиса.
- Лейбл `app=svc-demo` остался → под всё ещё принадлежит ReplicaSet'у (`ownerReferences: ReplicaSet/...`), Deployment по-прежнему `2/2` и **замену не создаёт**.
- Это стандартный приём отладки: «вынуть» проблемный под из-под трафика, не убивая его, и спокойно снять с него логи, дампы, `exec`-сессию. Обратная сторона — реплик под нагрузкой становится меньше, а Deployment об этом не подозревает.

Возвращаем лейбл:

```bash
kubectl label pod svc-demo-77dcb4b498-n8vlj tier=web
```

```
NAME           ENDPOINTS                                      AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80,10.244.0.81:80   100s

      2 I am STANDALONE pod (no Deployment)
      4 I am svc-demo-77dcb4b498-n8vlj
      3 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдение:** под мгновенно вернулся в сервис. Членство в сервисе — полностью обратимая операция над лейблом, состояние самого пода при этом не меняется.

---

## E. Разрываем связь с контроллером, оставляя под в сервисе

Обратный случай: меняем `app` (лейбл владения), а `tier=web` (лейбл членства) оставляем.

```bash
kubectl label pod svc-demo-77dcb4b498-n8vlj app=quarantine --overwrite
```

```
NAME                        READY   IP
standalone-web              1/1     10.244.0.81
svc-demo-77dcb4b498-6bb9n   1/1     10.244.0.82      <- ReplicaSet создал замену
svc-demo-77dcb4b498-n8vlj   1/1     10.244.0.78      <- осиротевший под
svc-demo-77dcb4b498-zxx52   1/1     10.244.0.77

labels={"app":"quarantine","pod-template-hash":"77dcb4b498","tier":"web"}
owner=/                                              <- ownerReferences пуст!

NAME       READY   UP-TO-DATE   AVAILABLE   AGE
svc-demo   2/2     2            2           109s

NAME                  DESIRED   CURRENT   READY   AGE
svc-demo-77dcb4b498   2         2         2       109s

NAME           ENDPOINTS                                                  AGE
svc-demo-svc   10.244.0.77:80,10.244.0.78:80,10.244.0.81:80 + 1 more...   109s
```

```bash
kubectl exec client -- sh -c 'for i in $(seq 1 16); do wget -qO- http://svc-demo-svc:8080/; done' | sort | uniq -c
```

```
      1 I am STANDALONE pod (no Deployment)
      9 I am svc-demo-77dcb4b498-6bb9n
      2 I am svc-demo-77dcb4b498-n8vlj
      4 I am svc-demo-77dcb4b498-zxx52
```

**Наблюдения:**
- ReplicaSet **потерял** этот под: `ownerReferences` очистились, под стал «сиротой». Ни Deployment, ни ReplicaSet им больше не управляют.
- Увидев, что подов под его селектором стало 1 вместо 2, ReplicaSet **немедленно создал замену** — `...-6bb9n`. Deployment так и показывает `2/2`, хотя реально живых подов с приложением стало 3.
- А сервис по-прежнему видит **4 эндпоинта** — сироту он не отпустил, ведь `tier=web` на месте. Трафик идёт на все четыре, включая под, за которым уже никто не следит.
- Это самая коварная комбинация: `kubectl get deploy` показывает норму, а в трафике участвует лишний неуправляемый под. Сироту приходится убирать руками:

```bash
kubectl delete pod svc-demo-77dcb4b498-n8vlj
```

```
standalone-web              1/1   Running
svc-demo-77dcb4b498-6bb9n   1/1   Running
svc-demo-77dcb4b498-zxx52   1/1   Running

NAME       READY   UP-TO-DATE   AVAILABLE   AGE
svc-demo   2/2     2            2           2m6s

NAME           ENDPOINTS                                      AGE
svc-demo-svc   10.244.0.77:80,10.244.0.81:80,10.244.0.82:80   2m6s
```

**Наблюдение:** удаление сироты замену **не породило** — ReplicaSet его своим уже не считал, а его собственные 2 пода на месте.

---

## F. Императивный способ: `kubectl expose`

```bash
kubectl expose deployment svc-demo --name=svc-demo-exposed --port=80 --target-port=80
```

```
service/svc-demo-exposed exposed

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
svc-demo-exposed   ClusterIP   10.97.173.241   <none>        80/TCP    1s    app=svc-demo

NAME               ENDPOINTS                       AGE
svc-demo-exposed   10.244.0.77:80,10.244.0.82:80   5s
```

**Наблюдения:**
- `kubectl expose` берёт селектор **из селектора самого Deployment** — получился `app=svc-demo`, а не `tier=web`.
- Поэтому у двух сервисов над одними и теми же подами **разный состав**: в `svc-demo-exposed` попали только 2 пода Deployment'а, а одиночный `standalone-web` — нет. Наглядно: состав сервиса задаёт исключительно его собственный селектор.
- Один и тот же под может состоять сразу в нескольких сервисах — это нормально и часто используется (например, отдельный сервис для метрик).

## G. Сервис, под селектор которого не подходит ни один под

```bash
kubectl get svc svc-demo-empty -o wide
kubectl get endpoints svc-demo-empty
```

```
NAME             TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
svc-demo-empty   ClusterIP   10.107.135.75   <none>        80/TCP    4s    tier=nonexistent

NAME             ENDPOINTS   AGE
svc-demo-empty   <none>      4s
```

```bash
kubectl exec client -- sh -c 'wget -T 5 -qO- http://svc-demo-empty:80/ || echo "EXIT=$?"'
```

```
wget: can't connect to remote host (10.107.135.75): Connection refused
EXIT=1 — соединение не установлено
```

**Наблюдения:**
- Сервис **создаётся успешно** и получает ClusterIP, даже если под его селектор не подходит ни один под. Kubernetes не проверяет, что селектор кого-то находит — опечатка в лейбле не вызовет никакой ошибки при `apply`.
- DNS-имя резолвится, но подключение сразу отбивается `Connection refused`. Пустой `Endpoints` — первое, что нужно смотреть при «сервис не отвечает».

---

## Сводка: способы управления составом сервиса

| Действие | Команда | Что меняется в сервисе | Что с Deployment |
|---|---|---|---|
| Добавить поды | `kubectl scale --replicas=N` (больше) | новые IP в Endpoints автоматически | штатное масштабирование |
| Убрать поды | `kubectl scale --replicas=N` (меньше) | IP исчезают из Endpoints | штатное масштабирование |
| Добавить чужой под | создать Pod с лейблом сервиса | +1 эндпоинт | не знает о нём |
| Вывести под из трафика | `kubectl label pod X tier-` | −1 эндпоинт, под жив | `READY` не меняется, **замены нет** |
| Вернуть под в трафик | `kubectl label pod X tier=web` | +1 эндпоинт | без изменений |
| Оторвать под от контроллера | `kubectl label pod X app=... --overwrite` | эндпоинт остаётся | RS создаёт **замену**, под становится сиротой |
| Удалить под | `kubectl delete pod X` | −1 эндпоинт | RS сразу создаёт замену (если под был его) |

## Выводы

1. **Service — это не «список подов», а живой запрос по лейблам.** В нём нет перечня участников: есть `selector`, и контроллер эндпоинтов постоянно пересобирает состав по всем подам, которые под него подходят.
2. **Владение (контроллер) и членство (сервис) — две независимые вещи.** Разведя их по разным лейблам, можно вывести под из трафика, не трогая реплики (D), или оставить под в трафике, оторвав его от контроллера (E). При одинаковых селекторах оба эффекта наступают одновременно и их легко перепутать.
3. **Сервису безразлично происхождение пода** — одиночный под, под из другого Deployment'а или из StatefulSet попадут в сервис на равных, лишь бы совпали лейблы и под был `Ready` (C).
4. **`kubectl scale`** — штатный способ добавлять и убирать поды: сервис подхватывает изменения сам, править Service не нужно.
5. **Управление лейблами — точечный инструмент, но с побочными эффектами**, о которых Deployment не сообщает: `kubectl get deploy` продолжает показывать `2/2` и когда под выведен из трафика, и когда рядом крутится неуправляемая сирота. Проверять реальный состав нужно через `kubectl get endpoints` / `get pods -l <селектор сервиса>`.
6. **`port` и `targetPort` — разные вещи:** первый принадлежит сервису, второй — контейнеру. В стенде они намеренно различаются (8080 → 80).
7. **Пустой Endpoints — не ошибка конфигурации с точки зрения API**, а самая частая причина «сервис не отвечает»: селектор с опечаткой создаётся без единого предупреждения (G).
8. Между появлением IP в `Endpoints` и реальным получением трафика есть небольшой **лаг kube-proxy** — сразу после добавления пода часть запросов ещё идёт мимо него (C).
