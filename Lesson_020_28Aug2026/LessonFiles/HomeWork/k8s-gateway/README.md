# Lesson 020 (доп. задание) — Gateway API вместо Ingress

> Задача: повторить прошлое ДЗ (namespace, frontend + backend за Service,
> доступ снаружи только к фронтенду, NetworkPolicy), но точку входа сделать
> не через `Ingress`, а через **Gateway API**.
> Документация: https://kubernetes.io/docs/concepts/services-networking/gateway/

Манифесты лежат рядом и пронумерованы — `kubectl apply -f .` применяет их
по алфавиту, поэтому Namespace создаётся раньше всего, что в него кладётся,
а политики — последними.

| Файл | Что делает | Изменился vs Ingress? |
|---|---|---|
| `00-namespace.yaml` | namespace `shop` | нет |
| `10-backend.yaml` | Deployment `backend` (http-echo:8080) + ClusterIP Service `backend:80` | нет |
| `11-frontend.yaml` | ConfigMap nginx + Deployment `frontend` + ClusterIP Service `frontend:80` | нет |
| `20-gatewayclass.yaml` | **GatewayClass** `envoy` → контроллер Envoy Gateway | новый (вместо `ingressClassName`) |
| `21-gateway.yaml` | **Gateway** `shop-gateway`: слушатель HTTP :80 | новый (аналога в Ingress не было) |
| `22-httproute.yaml` | **HTTPRoute** `shop.local/*` → Service `frontend` | новый (вместо `Ingress`) |
| `30-netpol-default-deny.yaml` | запретить весь Ingress и Egress в namespace | нет |
| `31-netpol-frontend.yaml` | вход во фронт только от подов Envoy-прокси; выход только в backend + DNS | **да** — другой namespace/метки источника |
| `32-netpol-backend.yaml` | вход в бэк только от `app=frontend`; выход только DNS | нет (только комментарий) |

---

## 1. Теория: что такое Gateway API и чем он отличается от Ingress

### Проблемы Ingress, которые решает Gateway API

* **Один объект на всё.** В Ingress хост, пути, TLS и бэкенды — в одном ресурсе,
  который правит разработчик. Кто владеет самим балансировщиком — непонятно.
* **Аннотации.** Всё, чего нет в спеке (rewrite, таймауты, canary, header-routing),
  делается через `nginx.ingress.kubernetes.io/...` — непереносимо между контроллерами.
* **Только HTTP/HTTPS.** TCP/UDP/gRPC — опять аннотации или свои CRD.

### Ролевая модель Gateway API

Gateway API — это набор **CRD** (add-on, в ядре Kubernetes их нет), разбитый по ролям:

| Ресурс | Кто владеет | Аналог в Ingress | Область |
|---|---|---|---|
| `GatewayClass` | админ кластера / провайдер | `IngressClass` | cluster-scoped |
| `Gateway` | админ кластера / платформенная команда | ~ сам Deployment ingress-controller | namespaced |
| `HTTPRoute` (`GRPCRoute`, `TCPRoute`...) | разработчик приложения | `spec.rules` в `Ingress` | namespaced |

Ключевое отличие: **`Gateway` — это заявка на инфраструктуру.** Создал объект `Gateway` —
контроллер поднял под него реальный прокси (Deployment + Service). Удалил — прокси пропал.
В мире Ingress контроллер ставился один раз руками и был «где-то там».

```
                 GatewayClass (envoy)          <- "кто обслуживает" (controllerName)
                        ▲
                        │ gatewayClassName
                 Gateway shop-gateway          <- "слушай :80 HTTP" -> контроллер поднимает Envoy-под
                        ▲
                        │ parentRefs
                 HTTPRoute shop-route          <- "shop.local/* -> Service frontend:80"
                        │ backendRefs
                        ▼
                 Service frontend  ->  Pod frontend  ->  Service backend -> Pod backend
```

### Сопоставление полей Ingress → Gateway API

| Ingress | Gateway API |
|---|---|
| `spec.ingressClassName: nginx` | `Gateway.spec.gatewayClassName: envoy` |
| `rules[].host: shop.local` | `HTTPRoute.spec.hostnames: [shop.local]` (или `Gateway.listeners[].hostname`) |
| `paths[].path: /` + `pathType: Prefix` | `rules[].matches[].path: {type: PathPrefix, value: /}` |
| `backend.service.name/port` | `rules[].backendRefs[].name/port` |
| под контроллера в ns `ingress-nginx` | под прокси в ns `envoy-gateway-system` |

### Почему Envoy Gateway

Ingress-контроллер из аддона minikube (`ingress-nginx`) Gateway API **не реализует**.
Нужен другой контроллер. Взят [Envoy Gateway](https://gateway.envoyproxy.io): ставится
одним `kubectl apply` без Helm, сам приносит CRD Gateway API, референсная реализация
от той же команды, что делает Envoy. Альтернативы: NGINX Gateway Fabric, Istio, Cilium, Kong.

---

## 2. Кластер

CNI по умолчанию в Minikube **не исполняет NetworkPolicy** — нужен Calico, и задать его
можно только при создании кластера. Аддон `ingress` в этот раз **не включаем**.

```bash
minikube delete
minikube start --cni=calico

# дождаться Calico
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
```

### Установить Envoy Gateway (контроллер + CRD Gateway API)

```bash
# --server-side обязателен: CRD Gateway API слишком большие для client-side apply
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.9.1/install.yaml

# дождаться контроллера
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

Проверить, что CRD появились (в install.yaml вшита Gateway API v1.6.1):

```bash
kubectl get crd | grep gateway.networking.k8s.io
# gatewayclasses / gateways / httproutes / grpcroutes / referencegrants ...
kubectl api-resources --api-group=gateway.networking.k8s.io
```

> `install.yaml` ставит **и CRD Gateway API, и сам контроллер**. Если бы CRD уже были
> в кластере (например, их ставит облачный провайдер) — ставили бы только контроллер.
> Отдельно «чистые» CRD ставятся так:
> `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml`

---

## 3. Развернуть

```bash
kubectl apply -f .
kubectl -n shop rollout status deploy/backend
kubectl -n shop rollout status deploy/frontend
kubectl -n shop get pods,svc,gateway,httproute,netpol
```

Что должно быть в выводе:

```bash
kubectl get gatewayclass
# NAME    CONTROLLER                                     ACCEPTED   AGE
# envoy   gateway.envoyproxy.io/gatewayclass-controller  True       ...

kubectl -n shop get gateway
# NAME           CLASS   ADDRESS   PROGRAMMED   AGE
# shop-gateway   envoy             False        ...

kubectl -n shop get gateway shop-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
# Accepted=True (Accepted)
# Programmed=False (AddressNotAssigned)   <- НЕ ошибка, см. ниже
```

> **`PROGRAMMED=False` с причиной `AddressNotAssigned` в Minikube — норма.** Envoy Gateway
> считает Gateway полностью запрограммированным только когда у его LoadBalancer-сервиса
> появился внешний адрес. В Minikube `EXTERNAL-IP` висит в `<pending>`, пока не запущен
> `minikube tunnel` (способ B в п.4). Сам прокси при этом уже поднят и трафик обслуживает,
> что видно по слушателю: `describe gateway` → `Listeners: http` → `Programmed=True`,
> `AttachedRoutes: 1`. После `minikube tunnel` колонки `ADDRESS` и `PROGRAMMED` заполнятся.
> Если же причина другая (например, `Pending`/`NoResources`) — смотри п.6.

```bash
kubectl -n shop get httproute
# NAME         HOSTNAMES        AGE
# shop-route   ["shop.local"]   ...
```

**Главное, что нужно увидеть: контроллер поднял прокси под наш Gateway.**
В отличие от Ingress, где nginx-controller существовал независимо от ваших правил:

```bash
kubectl -n envoy-gateway-system get pods,svc --show-labels
# envoy-shop-shop-gateway-xxxx   <- Deployment + Service (type LoadBalancer),
#                                   метки gateway.envoyproxy.io/owning-gateway-name=shop-gateway
#                                         gateway.envoyproxy.io/owning-gateway-namespace=shop
```

Эти метки и используются в `31-netpol-frontend.yaml`, чтобы разрешить вход во фронтенд
только этому прокси. Если имена меток в вашей версии отличаются — поправьте политику.

### Читать статусы (в Ingress такого не было)

У каждого ресурса Gateway API есть подробный `status.conditions`. Это первое место,
куда смотреть, если что-то не работает:

```bash
kubectl -n shop describe gateway shop-gateway     # Accepted / Programmed, Listeners -> AttachedRoutes: 1
kubectl -n shop describe httproute shop-route     # Parents -> Accepted=True, ResolvedRefs=True
```

* `Accepted=False` у HTTPRoute — Gateway не принял маршрут (не тот namespace, не совпал hostname с listener).
* `ResolvedRefs=False` — backendRef указывает на несуществующий Service/порт.
* `AttachedRoutes: 0` у listener — ни один маршрут к нему не прицепился.

---

## 4. Доступ снаружи

Прокси выставлен Service'ом типа `LoadBalancer`. В Minikube внешний IP сам по себе
не появится. Два способа:

### Способ A — port-forward (просто, без прав администратора)

```bash
# найти Service прокси по меткам владельца
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-namespace=shop,gateway.envoyproxy.io/owning-gateway-name=shop-gateway

# пробросить порт 80 сервиса на localhost:8080 (держать окно открытым)
kubectl -n envoy-gateway-system port-forward svc/<имя-сервиса-из-вывода> 8080:80
```

Дальше все проверки делаются с заголовком `Host: shop.local`, потому что HTTPRoute
матчит по hostname:

```bash
curl -H "Host: shop.local" http://localhost:8080/
```

> В PowerShell `curl` — это алиас `Invoke-WebRequest`. Используйте `curl.exe`.
> Команды в этом файле даны в одну строку намеренно: перенос через обратный слэш в конце строки
> работает только в bash. В PowerShell он становится лишним аргументом, и kubectl отвечает
> `error: name cannot be provided when a selector is specified`. Перенос строки в PowerShell — обратная кавычка.

### Способ B — minikube tunnel + hosts (ближе к «настоящему» LoadBalancer)

В отдельном окне **от администратора**:

```powershell
minikube tunnel
```

Через несколько секунд у Service прокси появится `EXTERNAL-IP` (на docker-драйвере в Windows
это `127.0.0.1`), а у Gateway заполнится колонка `ADDRESS`:

```bash
kubectl -n shop get gateway shop-gateway
kubectl -n shop get gateway shop-gateway -o jsonpath='{.status.addresses[0].value}'
```

Прописать hosts (PowerShell от администратора):

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "`n127.0.0.1 shop.local"
```

Тогда `curl http://shop.local/` работает без заголовка. Ниже команды даны для способа A;
для способа B замените `-H "Host: shop.local" http://localhost:8080` на `http://shop.local`.

---

## 5. Проверки

```bash
# ✅ фронтенд доступен снаружи через Gateway
curl -H "Host: shop.local" http://localhost:8080/
# FRONTEND OK. Try /api to reach the backend.

# ✅ фронтенд ходит к бэкенду (proxy_pass через ClusterIP Service backend)
curl -H "Host: shop.local" http://localhost:8080/api
# HELLO FROM BACKEND

# ✅ то же самое изнутри пода фронтенда
kubectl -n shop exec deploy/frontend -- wget -qO- http://backend/

# ❌ снаружи к бэкенду хода нет:
#    1) чужой hostname не матчится ни одним HTTPRoute -> 404 от Envoy
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: backend.local" http://localhost:8080/
#    2) Service backend вообще не упомянут ни в одном backendRefs
kubectl -n shop get httproute -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.rules[*].backendRefs[*].name}{"\n"}{end}'
# shop-route: frontend

# ❌ под из другого namespace не достучится до бэкенда (должен быть timeout)
kubectl run probe --rm -it --image=busybox:1.36 --restart=Never -n default -- wget -qO- --timeout=3 http://backend.shop.svc.cluster.local/

# ❌ бэкенд не может инициировать соединение к фронтенду (должен быть timeout).
#    hashicorp/http-echo без shell, поэтому имитируем бэкенд отладочным подом с его меткой:
kubectl run backend-probe -n shop --rm -it --image=busybox:1.36 --restart=Never --labels app=backend -- wget -qO- --timeout=3 http://frontend/
```

> **Как читать результат:** `timeout` / зависание = пакет дропнут политикой, всё работает
> правильно. `connection refused` = пакет дошёл, политика НЕ сработала — проверь Calico
> (`kubectl -n kube-system get pods | grep calico`) и совпадение меток в селекторах.

### Эксперимент со звёздочкой: NetworkPolicy как вторая линия обороны

Что будет, если разработчик «случайно» опубликует бэкенд через HTTPRoute?
Создайте файл `oops-backend.yaml` (в `kubectl apply -f .` его не включать):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: oops-backend
  namespace: shop
spec:
  parentRefs: [{name: shop-gateway}]
  hostnames: [backend.local]
  rules:
    - backendRefs: [{name: backend, port: 80}]
```

```bash
kubectl apply -f oops-backend.yaml
kubectl -n shop describe httproute oops-backend      # Accepted=True, ResolvedRefs=True — Envoy маршрут принял

curl -s -o /dev/null -w '%{http_code}\n' -H "Host: backend.local" http://localhost:8080/
# ожидаем 503/504 (upstream timeout): маршрут есть, но политика allow-frontend-to-backend
# пускает в бэкенд только поды app=frontend, а Envoy-прокси под этот селектор не попадает.
# Уровень маршрутизации и уровень сети независимы, и второй страхует первый.

kubectl delete -f oops-backend.yaml
```

---

## 6. Отладка: типовые проблемы

| Симптом | Причина | Что делать |
|---|---|---|
| `kubectl apply` ругается `metadata.annotations: Too long` | CRD применены без `--server-side` | добавить `--server-side` |
| GatewayClass `ACCEPTED=False` | `controllerName` не совпадает с контроллером | сверить с `kubectl -n envoy-gateway-system logs deploy/envoy-gateway` |
| Gateway `PROGRAMMED=False`, причина `AddressNotAssigned`, под прокси есть | нет внешнего IP у LoadBalancer (норма для Minikube) | ничего: работать через port-forward, либо запустить `minikube tunnel` |
| Gateway `PROGRAMMED=False`, пода прокси нет | контроллер не поднялся / GatewayClass не принят | `kubectl -n envoy-gateway-system get pods`, `describe gateway` |
| HTTPRoute `Accepted=False` | Gateway в другом namespace при `allowedRoutes.from: Same` | положить маршрут рядом с Gateway или сменить `allowedRoutes` |
| `curl` даёт 404 | не передан `Host: shop.local` | `-H "Host: shop.local"` или hosts + tunnel |
| `curl` даёт 503/504, `/` не открывается | NetworkPolicy не пускает прокси во фронтенд | сверить метки подов прокси с `31-netpol-frontend.yaml` |
| `/api` даёт 502 | frontend не может резолвить/достучаться до backend | проверить DNS-правило в `frontend-egress`, логи `deploy/frontend` |

---

## 7. Убрать за собой

```bash
kubectl delete -f .            # удалит и Gateway -> контроллер снесёт под прокси
kubectl -n envoy-gateway-system get pods   # прокси-пода shop-gateway больше нет
# при желании — снести и контроллер с CRD:
kubectl delete -f https://github.com/envoyproxy/gateway/releases/download/v1.9.1/install.yaml
```

---

## 8. Что записать в выводы (для сдачи)

1. Ingress = один ресурс на всё; Gateway API = три ресурса по ролям (`GatewayClass` →
   `Gateway` → `HTTPRoute`), причём `Gateway` **создаёт** инфраструктуру, а не описывает существующую.
2. Правила маршрутизации переехали из `Ingress.spec.rules` в `HTTPRoute` практически 1:1,
   но без аннотаций: hostname, path-match, backendRefs — стандартные поля, одинаковые у всех контроллеров.
3. `ingress-nginx` Gateway API не поддерживает — контроллер пришлось поменять на Envoy Gateway.
4. NetworkPolicy почти не изменились: поменялся только **источник** входящего трафика во фронтенд
   (namespace `envoy-gateway-system` + метки подов прокси вместо namespace `ingress-nginx`).
   Изоляция бэкенда, DNS-правила и запрет обратного трафика — те же.
5. Бэкенд закрыт снаружи дважды: его нет в `backendRefs` (уровень маршрутизации) и его
   не пускает NetworkPolicy (уровень сети). Эксперимент из п.5 показывает, что второе
   работает даже когда первое нарушено.
