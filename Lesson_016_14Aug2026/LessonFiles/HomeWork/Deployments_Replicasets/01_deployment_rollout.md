# 1. Деплоймент и ролаут новой версии

Задание: **Запустить деплоймент и выполнить ролаут новой версии.**

Среда: Minikube (Kubernetes), Windows 11, kubectl.

---

## Шаг 0. Проверка кластера

```bash
minikube status
```

Кластер был остановлен, поэтому запущен заново:

```bash
minikube start
```

```
* minikube v1.38.1 on Microsoft Windows 11 Home 25H2
* Using the docker driver based on existing profile
* Starting "minikube" primary control-plane node in "minikube" cluster
* Pulling base image v0.0.50 ...
* Verifying Kubernetes components...
  - Using image gcr.io/k8s-minikube/storage-provisioner:v5
* Enabled addons: default-storageclass, storage-provisioner
* Done! kubectl is now configured to use "minikube" cluster and "default" namespace by default
```

---

## Шаг 1. Создание деплоймента (версия 1)

Создаём деплоймент `nginx-deploy` на образе `nginx:1.25` с тремя репликами:

```bash
kubectl create deployment nginx-deploy --image=nginx:1.25 --replicas=3
```

```
deployment.apps/nginx-deploy created
```

Ждём завершения раскатки:

```bash
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
Waiting for deployment "nginx-deploy" rollout to finish: 0 of 3 updated replicas are available...
Waiting for deployment "nginx-deploy" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "nginx-deploy" rollout to finish: 2 of 3 updated replicas are available...
deployment "nginx-deploy" successfully rolled out
```

### Проверка состояния (версия 1)

```bash
kubectl get deployment nginx-deploy -o wide
```

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
nginx-deploy   3/3     3            3           28s   nginx        nginx:1.25   app=nginx-deploy
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6dff5b5d69   3         3         3       29s
```

```bash
kubectl get pods -l app=nginx-deploy -o wide
```

```
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-deploy-6dff5b5d69-8bksb   1/1     Running   0          31s   10.244.0.19   minikube   <none>           <none>
nginx-deploy-6dff5b5d69-cp85m   1/1     Running   0          31s   10.244.0.20   minikube   <none>           <none>
nginx-deploy-6dff5b5d69-j29qn   1/1     Running   0          31s   10.244.0.21   minikube   <none>           <none>
```

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
1         <none>
```

**Наблюдение:** создан один ReplicaSet `nginx-deploy-6dff5b5d69`, соответствующий revision 1 (образ `nginx:1.25`). CHANGE-CAUSE пустой, т.к. запись причины не была включена при создании.

---

## Шаг 2. Ролаут новой версии (версия 2)

Меняем образ контейнера на `nginx:1.26` — это запускает rolling update:

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.26
```

```
deployment.apps/nginx-deploy image updated
```

Добавляем аннотацию причины изменения (чтобы она попала в историю ролаутов):

```bash
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="update nginx 1.25 -> 1.26"
```

```
deployment.apps/nginx-deploy annotated
```

Следим за ходом ролаута:

```bash
kubectl rollout status deployment/nginx-deploy --timeout=90s
```

```
Waiting for deployment "nginx-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "nginx-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "nginx-deploy" successfully rolled out
```

### Проверка состояния (версия 2)

```bash
kubectl get deployment nginx-deploy -o wide
```

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
nginx-deploy   3/3     3            3           68s   nginx        nginx:1.26   app=nginx-deploy
```

```bash
kubectl get rs -l app=nginx-deploy
```

```
NAME                      DESIRED   CURRENT   READY   AGE
nginx-deploy-6dff5b5d69   0         0         0       70s
nginx-deploy-7fc4cd9448   3         3         3       29s
```

```bash
kubectl get pods -l app=nginx-deploy -o wide
```

```
NAME                            READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
nginx-deploy-7fc4cd9448-698wq   1/1     Running   0          13s   10.244.0.24   minikube   <none>           <none>
nginx-deploy-7fc4cd9448-kskcz   1/1     Running   0          31s   10.244.0.22   minikube   <none>           <none>
nginx-deploy-7fc4cd9448-nmmvq   1/1     Running   0          15s   10.244.0.23   minikube   <none>           <none>
```

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
kubectl rollout history deployment/nginx-deploy --revision=2
```

```
deployment.apps/nginx-deploy with revision #2
Pod Template:
  Labels:       app=nginx-deploy
        pod-template-hash=7fc4cd9448
  Annotations:  kubernetes.io/change-cause: update nginx 1.25 -> 1.26
  Containers:
   nginx:
    Image:      nginx:1.26
    Port:       <none>
    Host Port:  <none>
    Environment:        <none>
    Mounts:     <none>
  Volumes:      <none>
  Node-Selectors:       <none>
  Tolerations:  <none>
```

---

## Итог

| Что | Значение |
|---|---|
| Deployment | `nginx-deploy` |
| Стартовый образ | `nginx:1.25` (revision 1) |
| Новый образ после ролаута | `nginx:1.26` (revision 2) |
| Стратегия обновления | по умолчанию — `RollingUpdate` |
| Старый ReplicaSet | `nginx-deploy-6dff5b5d69` — масштабирован до 0, но сохранён в истории |
| Новый ReplicaSet | `nginx-deploy-7fc4cd9448` — держит все 3 работающих пода |
| История ролаутов | 2 ревизии, `CHANGE-CAUSE` записан через аннотацию |

**Выводы:**
- Каждое изменение шаблона пода (`spec.template`) в Deployment создаёт **новый ReplicaSet** и повышает номер ревизии.
- Старый ReplicaSet не удаляется — он масштабируется до 0 реплик и остаётся в истории (используется для будущих откатов, `kubectl rollout undo`).
- Название ReplicaSet содержит хэш от шаблона пода (`pod-template-hash`), поэтому при откате на старую версию будет переиспользован тот же ReplicaSet, а не создан новый.
- `kubectl rollout status` блокируется до полного завершения rolling update — удобно для скриптов CI/CD.
- Аннотация `kubernetes.io/change-cause` — единственный способ получить осмысленную историю в `kubectl rollout history` (без неё колонка CHANGE-CAUSE пустая).
