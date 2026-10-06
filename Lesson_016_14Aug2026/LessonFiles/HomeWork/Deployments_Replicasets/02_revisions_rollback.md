# 2. Ревизии и откаты (rollback)

Задание: **Поиграться с ревизиями (пооткатываться на разные версии и посмотреть поведение репликасетов и истории).**

Продолжение работы с деплойментом `nginx-deploy`, созданным в [01_deployment_rollout.md](01_deployment_rollout.md).

Состояние на старте этого шага:

- Revision 1 → `nginx:1.25` (change-cause: `<none>`)
- Revision 2 → `nginx:1.26` (change-cause: `update nginx 1.25 -> 1.26`), деплоймент сейчас на этой версии

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
1         <none>
2         update nginx 1.25 -> 1.26
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6dff5b5d69   0         0         0       9m31s
nginx-deploy-7fc4cd9448   3         3         3       8m50s
```

---

## Шаг 1. Простой откат на предыдущую ревизию (`rollout undo`)

```bash
kubectl rollout undo deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy rolled back
```

```bash
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
Waiting for deployment "nginx-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

### Проверка

```bash
kubectl get deployment nginx-deploy -o wide
```

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE     CONTAINERS   IMAGES       SELECTOR
nginx-deploy   3/3     3            3           9m52s   nginx        nginx:1.25   app=nginx-deploy
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6dff5b5d69   3         3         3       9m54s
nginx-deploy-7fc4cd9448   0         0         0       9m13s
```

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
2         update nginx 1.25 -> 1.26
3         <none>
```

```bash
kubectl get pods -l app=nginx-deploy -o wide
```

```
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-deploy-6dff5b5d69-clms5   1/1     Running   0          19s   10.244.0.25   minikube   <none>           <none>
nginx-deploy-6dff5b5d69-sbnqw   1/1     Running   0          15s   10.244.0.27   minikube   <none>           <none>
nginx-deploy-6dff5b5d69-vkdfm   1/1     Running   0          17s   10.244.0.26   minikube   <none>           <none>
```

**Ключевое наблюдение:** ревизия 1 (`nginx:1.25`) исчезла из истории, а вместо неё появилась **новая** ревизия 3 с тем же содержимым (change-cause пустой, т.к. при создании исходного деплоймента причина не записывалась). При этом физически переиспользован **тот же самый ReplicaSet** `nginx-deploy-6dff5b5d69` — Kubernetes сопоставляет ReplicaSet по хэшу шаблона пода (`pod-template-hash`), а не по номеру ревизии. Номера ревизий монотонно растут и никогда не переиспользуются, даже при откате.

---

## Шаг 2. Накопление ещё нескольких ревизий

Чтобы было из чего выбирать при откате на конкретную ревизию, сделаны ещё два обновления:

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.27
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="update nginx 1.25 -> 1.27" --overwrite
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
deployment.apps/nginx-deploy image updated
deployment.apps/nginx-deploy annotated
...
deployment "nginx-deploy" successfully rolled out
```

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.28
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="update nginx 1.27 -> 1.28" --overwrite
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
deployment.apps/nginx-deploy image updated
deployment.apps/nginx-deploy annotated
...
deployment "nginx-deploy" successfully rolled out
```

### История и ReplicaSet-ы после накопления ревизий

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
2         update nginx 1.25 -> 1.26
3         <none>
4         update nginx 1.25 -> 1.27
5         update nginx 1.27 -> 1.28
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-5cc5c77d55   0         0         0       55s
nginx-deploy-6dff5b5d69   0         0         0       11m
nginx-deploy-7fc4cd9448   0         0         0       10m
nginx-deploy-96d545bb6    3         3         3       26s
```

**Наблюдение:** Kubernetes хранит по одному ReplicaSet на каждый уникальный шаблон пода (лимит задаётся `spec.revisionHistoryLimit`, по умолчанию 10). Все старые ReplicaSet-ы остаются в кластере со `DESIRED=0`, но не удаляются — именно они используются при последующих откатах.

---

## Шаг 3. Откат на конкретную ревизию (`--to-revision`)

Откатываемся не на предыдущую, а на конкретную ревизию 2 (`nginx:1.26`):

```bash
kubectl rollout undo deployment/nginx-deploy --to-revision=2
```

```
deployment.apps/nginx-deploy rolled back
```

```bash
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
Waiting for deployment "nginx-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

### Проверка

```bash
kubectl get deployment nginx-deploy -o wide
```

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
nginx-deploy   3/3     3            3           11m   nginx        nginx:1.26   app=nginx-deploy
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-5cc5c77d55   0         0         0       74s
nginx-deploy-6dff5b5d69   0         0         0       11m
nginx-deploy-7fc4cd9448   3         3         3       10m
nginx-deploy-96d545bb6    0         0         0       45s
```

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
3         <none>
4         update nginx 1.25 -> 1.27
5         update nginx 1.27 -> 1.28
6         update nginx 1.25 -> 1.26
```

```bash
kubectl get pods -l app=nginx-deploy -o wide
```

```
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-deploy-7fc4cd9448-q4v22   1/1     Running   0          15s   10.244.0.35   minikube   <none>           <none>
nginx-deploy-7fc4cd9448-t47wk   1/1     Running   0          17s   10.244.0.34   minikube   <none>           <none>
nginx-deploy-7fc4cd9448-vhgff   1/1     Running   0          13s   10.244.0.36   minikube   <none>           <none>
```

**Наблюдение:** ревизия 2 исчезла из истории (как и revision 1 ранее), а её содержимое переехало под номер 6 (следующий свободный номер). ReplicaSet `nginx-deploy-7fc4cd9448` (тот же, что обслуживал `nginx:1.26` изначально) был просто заново масштабирован с 0 до 3 — новый ReplicaSet не создавался, потому что хэш шаблона совпал.

```bash
kubectl rollout history deployment/nginx-deploy --revision=6
```

```
deployment.apps/nginx-deploy with revision #6
Pod Template:
  Labels:	app=nginx-deploy
	pod-template-hash=7fc4cd9448
  Annotations:	kubernetes.io/change-cause: update nginx 1.25 -> 1.26
  Containers:
   nginx:
    Image:	nginx:1.26
    ...
```

---

## Шаг 4. Поведение через события Deployment (`kubectl describe`)

```bash
kubectl describe deployment nginx-deploy
```

Фрагмент секции `Events`, показывающий постепенное (rolling) масштабирование ReplicaSet-ов туда-сюда при каждом откате/обновлении:

```
OldReplicaSets:  nginx-deploy-6dff5b5d69 (0/0 replicas created), nginx-deploy-5cc5c77d55 (0/0 replicas created), nginx-deploy-96d545bb6 (0/0 replicas created)
NewReplicaSet:   nginx-deploy-7fc4cd9448 (3/3 replicas created)
Events:
  Type    Reason             Age                  From                   Message
  ----    ------             ----                 ----                   -------
  Normal  ScalingReplicaSet  11m                  deployment-controller  Scaled up replica set nginx-deploy-6dff5b5d69 from 0 to 3
  Normal  ScalingReplicaSet  10m                  deployment-controller  Scaled up replica set nginx-deploy-7fc4cd9448 from 0 to 1
  Normal  ScalingReplicaSet  10m                  deployment-controller  Scaled up replica set nginx-deploy-7fc4cd9448 from 1 to 2
  Normal  ScalingReplicaSet  10m                  deployment-controller  Scaled down replica set nginx-deploy-6dff5b5d69 from 2 to 1
  Normal  ScalingReplicaSet  10m                  deployment-controller  Scaled up replica set nginx-deploy-7fc4cd9448 from 2 to 3
  Normal  ScalingReplicaSet  112s                 deployment-controller  Scaled up replica set nginx-deploy-6dff5b5d69 from 0 to 1
  Normal  ScalingReplicaSet  110s                 deployment-controller  Scaled down replica set nginx-deploy-7fc4cd9448 from 3 to 2
  Normal  ScalingReplicaSet  66s (x2 over 10m)    deployment-controller  Scaled down replica set nginx-deploy-6dff5b5d69 from 3 to 2
  Normal  ScalingReplicaSet  62s (x2 over 10m)    deployment-controller  Scaled down replica set nginx-deploy-6dff5b5d69 from 1 to 0
  Normal  ScalingReplicaSet  23s (x16 over 110s)  deployment-controller  (combined from similar events): Scaled down replica set nginx-deploy-96d545bb6 from 3 to 2
```

**Наблюдение:** каждый rollout/rollback — это не мгновенная замена, а покадровая (rolling) операция: старый ReplicaSet скейлится вниз, новый — вверх, шаг за шагом, с сохранением `maxUnavailable`/`maxSurge` (по умолчанию 25%/25%). Именно поэтому во время обновления кратковременно видно как старые, так и новые поды.

---

## Итог

| Ревизия | Образ | Change-Cause | Куда делась |
|---|---|---|---|
| 1 | nginx:1.25 | `<none>` | заменена ревизией 3 после `undo` |
| 2 | nginx:1.26 | update 1.25→1.26 | заменена ревизией 6 после `undo --to-revision=2` |
| 3 | nginx:1.25 | `<none>` | текущая история (после отката 1) |
| 4 | nginx:1.27 | update 1.25→1.27 | в истории |
| 5 | nginx:1.28 | update 1.27→1.28 | в истории |
| 6 | nginx:1.26 | update 1.25→1.26 | **текущее состояние деплоймента** |

**Выводы:**
1. Номера ревизий **никогда не переиспользуются** — и `rollout undo`, и `rollout undo --to-revision=N` создают новую (следующую по счёту) ревизию с содержимым старой; сама старая ревизия из истории пропадает.
2. При этом объект **ReplicaSet переиспользуется**, если его `pod-template-hash` совпадает с целевым шаблоном — новый ReplicaSet не создаётся, только меняется `replicas: 0 → N` у старого и `N → 0` у текущего.
3. Старые ReplicaSet-ы (с `DESIRED=0`) не удаляются автоматически — они являются "материалом" для будущих откатов, ограничены `spec.revisionHistoryLimit` (по умолчанию 10).
4. И обновление, и откат выполняются как **rolling update**: постепенное изменение количества реплик у старого и нового RS, а не мгновенная замена — это видно в `Events` через `kubectl describe deployment`.
5. `CHANGE-CAUSE` в истории берётся исключительно из аннотации `kubernetes.io/change-cause` на деплойменте на момент создания ревизии — без неё колонка пустая, что затрудняет диагностику "что и когда откатили".
