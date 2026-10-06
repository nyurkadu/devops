# Lesson 020 — Ingress + NetworkPolicy

> Оформленная версия этого же текста — `README.html` рядом. Файлы — пара:
> правишь один, правь и второй.

Манифесты пронумерованы: `kubectl apply -f .` применяет файлы в алфавитном порядке,
поэтому Namespace создаётся раньше всего, что в него кладётся, а политики —
последними, когда поды уже описаны.

| Файл | Что делает |
|---|---|
| `00-namespace.yaml` | namespace `shop` |
| `10-backend.yaml` | Deployment `backend` (http-echo:8080) + ClusterIP Service `backend:80` |
| `11-frontend.yaml` | ConfigMap с nginx.conf + Deployment `frontend` + ClusterIP Service `frontend:80` |
| `20-ingress.yaml` | Ingress `shop.local` → Service `frontend` (backend не упомянут) |
| `30-netpol-default-deny.yaml` | запретить весь Ingress и Egress в namespace |
| `31-netpol-frontend.yaml` | вход во фронт только из `ingress-nginx`; выход только в backend + DNS |
| `32-netpol-backend.yaml` | вход в бэк только от `app=frontend`; выход только в DNS |

## 0. Кластер

CNI по умолчанию в Minikube **не исполняет NetworkPolicy** — правила создадутся,
но трафик фильтроваться не будет. Нужен Calico, и задать его можно только при
создании кластера:

```bash
minikube delete
minikube start --cni=calico
minikube addons enable ingress

# дождаться готовности
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
```

→ обе команды должны дойти до `successfully rolled out` прежде, чем применять манифесты.
Флаг `--cni` на живой кластер не накатывается: если кластер уже поднят без Calico —
только пересоздавать.

## 1. Развернуть

```bash
kubectl apply -f .
kubectl -n shop rollout status deploy/backend
kubectl -n shop rollout status deploy/frontend
kubectl -n shop get pods,svc,ingress,netpol
```

## 2. Прописать hosts

```bash
minikube ip     # например 192.168.49.2
```

Windows (PowerShell от администратора):

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "`n$(minikube ip) shop.local"
```

Linux/macOS: `echo "$(minikube ip) shop.local" | sudo tee -a /etc/hosts`

## 3. Проверки

```bash
# ✅ фронтенд доступен снаружи через Ingress
curl http://shop.local/

# ✅ фронтенд ходит к бэкенду (проксирование через ClusterIP Service)
curl http://shop.local/api

# ✅ то же самое изнутри пода
kubectl -n shop exec deploy/frontend -- wget -qO- http://backend/

# ❌ снаружи к бэкенду хода нет — Ingress о нём не знает
curl -s -o /dev/null -w '%{http_code}\n' http://shop.local/backend    # 404 от nginx-controller

# ❌ под из другого namespace не достучится до бэкенда (должен быть timeout)
kubectl run probe --rm -it --image=busybox:1.36 --restart=Never -n default -- \
  wget -qO- --timeout=3 http://backend.shop.svc.cluster.local/

# ❌ бэкенд не может инициировать соединение к фронтенду (должен быть timeout)
kubectl -n shop exec deploy/backend -- wget -qO- --timeout=3 http://frontend/
```

`hashicorp/http-echo` — образ без shell и без wget. Если последняя команда падает
с `executable file not found`, проверяй запрет обратного трафика отладочным подом
с меткой фронта наоборот — подом с меткой бэка:

```bash
kubectl run backend-probe -n shop --rm -it --image=busybox:1.36 --restart=Never \
  --labels app=backend -- wget -qO- --timeout=3 http://frontend/
# ожидаем timeout: политика backend-egress-dns-only разрешает только DNS
```

> **Как читать результат:** `timeout` / зависание = пакет дропнут политикой, всё
> работает правильно. `connection refused` = пакет дошёл до узла назначения,
> политика НЕ сработала — проверь CNI (`kubectl -n kube-system get pods | grep calico`)
> и совпадение меток в селекторах.

## 4. Убрать за собой

```bash
kubectl delete -f .
```
