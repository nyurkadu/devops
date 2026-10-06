# Анатомия кластера — манифесты

Декларативный комплект к лекции урока 020. Каждый файл заменяет одну или
несколько императивных команд из оригинала и содержит подробную документацию
в комментариях: что объект делает, что происходит физически, чем это можно
проверить и какой командой запускается.

## Порядок применения

```powershell
# 0. Кластер и namespace
minikube start -p calico --cni=calico --nodes=2
kubectl config use-context calico
kubectl apply -f k8s-anatomy/00-namespace.yaml
kubectl config set-context --current --namespace=lab

# 1. Поды: один контейнер в спеке -> два на ноде
kubectl apply -f k8s-anatomy/10-pod-web.yaml
kubectl apply -f k8s-anatomy/11-pod-duo.yaml

# 2. ReplicaSet отдельно, чтобы увидеть слой под Deployment
kubectl apply -f k8s-anatomy/20-replicaset-bare.yaml

# 3. Deployment и его жизненный цикл
kubectl apply -f k8s-anatomy/30-deployment-shop.yaml
kubectl patch deployment shop --patch-file k8s-anatomy/patches/31-patch-replicas.yaml
kubectl patch deployment shop --patch-file k8s-anatomy/patches/32-patch-image-v2.yaml

# 4. Service
kubectl apply -f k8s-anatomy/40-service-shop-clusterip.yaml
kubectl apply -f k8s-anatomy/41-service-shop-nodeport.yaml

# 5. Под-клиент для проверок
kubectl apply -f k8s-anatomy/80-pod-probe.yaml

# 6. Правила четырёх видов
kubectl apply -f k8s-anatomy/50-rbac-pod-reader.yaml
kubectl apply -f k8s-anatomy/60-networkpolicy-deny-all.yaml
kubectl apply -f k8s-anatomy/61-networkpolicy-allow-probe.yaml
minikube addons enable ingress -p calico
kubectl apply -f k8s-anatomy/70-ingress-shop.yaml
```

## Состав

| Файл | Объект | Что заменяет |
|---|---|---|
| `00-namespace.yaml` | Namespace | `kubectl create namespace lab` |
| `10-pod-web.yaml` | Pod | `kubectl run web --image=nginx:alpine --port=80` |
| `11-pod-duo.yaml` | Pod (2 контейнера) | эквивалента нет — `kubectl run` так не умеет |
| `20-replicaset-bare.yaml` | ReplicaSet | эквивалента нет — `kubectl create` так не умеет |
| `30-deployment-shop.yaml` | Deployment | `kubectl create deployment shop --replicas=3` |
| `patches/31-patch-replicas.yaml` | patch | `kubectl scale deployment shop --replicas=6` |
| `patches/32-patch-image-v2.yaml` | patch | `kubectl set image deployment/shop nginx=…` |
| `40-service-shop-clusterip.yaml` | Service | `kubectl expose deployment shop --port=80` |
| `41-service-shop-nodeport.yaml` | Service | `kubectl patch svc shop-svc … type NodePort` |
| `50-rbac-pod-reader.yaml` | SA + Role + RoleBinding | три команды `kubectl create` |
| `60-networkpolicy-deny-all.yaml` | NetworkPolicy | эквивалента нет |
| `61-networkpolicy-allow-probe.yaml` | NetworkPolicy | эквивалента нет |
| `70-ingress-shop.yaml` | Ingress | `kubectl create ingress shop-ing --rule=…` |
| `80-pod-probe.yaml` | Pod | `kubectl run t1 --rm -it --image=busybox` |

## Уборка

```powershell
kubectl config set-context --current --namespace=default
kubectl delete namespace lab
minikube stop -p calico
```

## Проверка перед применением

```powershell
# синтаксис и схема, без обращения к кластеру
kubectl apply --dry-run=client -f k8s-anatomy/

# что реально изменится в кластере
kubectl diff -f k8s-anatomy/30-deployment-shop.yaml
```

Файлы в `patches/` — не полные манифесты, а strategic merge patch.
Через `kubectl apply` они не применяются, только через `kubectl patch --patch-file`.
Поэтому они вынесены в подкаталог: `kubectl apply -f k8s-anatomy/` не рекурсивен
и их не увидит.
