# Теоретический трактат: Minikube, Ingress, Namespace, Service и NetworkPolicy

> Конспект к домашнему заданию Lesson 020. Разбор по слоям — от «железа» до правил фильтрации.
> Ключевые грабли, о которые спотыкаются все, отмечены отдельно.

---

## 1. Инфраструктура: Minikube + Ingress addon

**Minikube** — это один узел Kubernetes, запущенный внутри VM или Docker-контейнера на твоей машине. Он «настоящий»: там есть kube-apiserver, etcd, scheduler, kubelet, CNI-плагин. Отличие от прода — узел один, и облачных интеграций (LoadBalancer, EBS-диски) нет, вместо них — эмуляции.

```bash
minikube start --cni=calico
minikube addons enable ingress
```

**Что такое addon.** Это не фича Minikube, а просто заранее подготовленный набор манифестов, который Minikube применяет за тебя. `ingress` разворачивает **ingress-nginx controller** — обычный Deployment с nginx внутри, живущий в namespace `ingress-nginx`. Он слушает порты 80/443 **прямо на IP узла** (hostPort/hostNetwork), поэтому доступен снаружи по `minikube ip`.

> ⚠️ **Грабли №1.** Дефолтный CNI в Minikube (`kindnet`/`bridge`) **не умеет NetworkPolicy**. Он молча проигнорирует твои правила: `kubectl get netpol` покажет объекты, а трафик будет ходить как ни в чём не бывало, и ты будешь думать, что политика «не работает». NetworkPolicy — это **спецификация**, а исполняет её CNI. Нужен Calico или Cilium. Поэтому `--cni=calico` **при первом старте** кластера (на существующий кластер это уже не накатится — проще `minikube delete` и заново).

---

## 2. Окружение: Namespace

Namespace — это **логическая единица изоляции имён и политик**, но **не сетевой периметр**. Что он даёт:

| Даёт | Не даёт |
|---|---|
| Уникальность имён (`web` в двух ns — разные объекты) | Изоляцию сети (по умолчанию под из ns A свободно ходит в ns B) |
| Область действия RBAC, ResourceQuota, LimitRange | Изоляцию ресурсов CPU/RAM сам по себе |
| Область действия NetworkPolicy | Изоляцию нод |
| Массовое удаление: `kubectl delete ns app` сносит всё внутри | |

```bash
kubectl create namespace shop
kubectl config set-context --current --namespace=shop   # чтобы не писать -n везде
```

**Важно для домашки:** NetworkPolicy — объект, **привязанный к namespace**. Она отбирает поды только внутри своего ns. Поэтому все Deployment-ы, Service-ы, Ingress и политики кладём в один ns.

---

## 3. Приложение: Pod → Deployment → Service

### Слои абстракции

- **Pod** — минимальная единица, один или несколько контейнеров с общим IP и сетевым стеком. Смертен: IP меняется при каждом перезапуске.
- **Deployment** — контроллер, который держит N реплик и умеет катить обновления. Поды создаём **через него**, не руками.
- **Service** — стабильная точка входа. Получает вечный `ClusterIP` и DNS-имя `<svc>.<ns>.svc.cluster.local`. Внутри себя ведёт список живых Pod IP (Endpoints/EndpointSlice) и балансирует по ним.

### Связь идёт через labels, а не через имена

Это главный концепт всей темы:

```
Service.spec.selector      ──match──►  Pod.metadata.labels
NetworkPolicy.podSelector  ──match──►  Pod.metadata.labels
```

Service **не знает** о Deployment. Он знает только «дай мне все поды с меткой `app: backend` в моём namespace». Ровно тот же механизм у NetworkPolicy. Отсюда правило: **метки на подах — это API безопасности**, относись к ним серьёзно.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels: { app: backend }
  template:
    metadata:
      labels: { app: backend }        # ← сюда целятся и Service, и NetworkPolicy
    spec:
      containers:
        - name: backend
          image: hashicorp/http-echo
          args: ["-text=hello from backend", "-listen=:8080"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: shop
spec:
  type: ClusterIP                     # ← только внутри кластера
  selector: { app: backend }
  ports:
    - port: 80                        # порт Service
      targetPort: 8080                # порт в контейнере
```

### Типы Service — почему именно ClusterIP

| Тип | Кто достучится | Уместно тут? |
|---|---|---|
| `ClusterIP` | только поды кластера | ✅ и фронт, и бэк |
| `NodePort` | любой, кто знает IP ноды и порт 30000+ | ❌ дыра наружу |
| `LoadBalancer` | весь интернет | ❌ |

Фронтенд тоже делаем **ClusterIP** — наружу его выставит Ingress, а не Service. Если сделать фронт NodePort, появится второй, неконтролируемый вход в приложение.

---

## 4. Маршрутизация: Ingress

### Две сущности, которые путают

- **Ingress** (объект) — декларация: «хост `shop.local`, путь `/` → Service `frontend:80`». Сам по себе это просто запись в etcd, она ничего не маршрутизирует.
- **Ingress Controller** (под) — программа (nginx), которая читает все Ingress-объекты через API и **переписывает свой nginx.conf**. Вот она и гоняет трафик.

Нет контроллера → Ingress-объект есть, но `ADDRESS` пустой и ничего не работает.

### Зачем он, если есть Service

Ingress — это L7 (HTTP): умеет роутинг по хосту и пути, TLS-терминацию, один внешний IP на десятки сервисов. Service — L4 (TCP/UDP). Практически: Ingress даёт **единственную входную дверь**, что и требуется в задании.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
  namespace: shop
spec:
  ingressClassName: nginx
  rules:
    - host: shop.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend        # ← упомянут ТОЛЬКО фронтенд
                port: { number: 80 }
```

«Доступ снаружи исключительно на фронтенд» достигается **отсутствием** правила для backend.

Проверка: `minikube ip` → добавить в `C:\Windows\System32\drivers\etc\hosts` строку `<ip> shop.local` → `curl http://shop.local`.

### Важный нюанс трафика

Ingress-controller живёт в **чужом namespace** (`ingress-nginx`) и обращается к твоему фронтенду **напрямую по Pod IP**, минуя ClusterIP Service. Это критично для следующего раздела: правило «пускать к фронту» нужно писать про namespace `ingress-nginx`, а не про Service.

---

## 5. NetworkPolicy: изоляция

### Модель, которую надо принять как аксиому

1. **По умолчанию сеть плоская.** Любой под может обратиться к любому поду в любом namespace. Kubernetes — не файрвол «из коробки».
2. **Политика — это whitelist.** Как только на под навелась *хотя бы одна* политика с `Ingress` в `policyTypes` — весь входящий трафик к нему запрещён, кроме явно разрешённого. То же отдельно для `Egress`.
3. **Политики складываются (OR).** Нет приоритетов, нет `deny`-правил. Две политики на один под = объединение разрешений. Запретить что-то, добавив правило, невозможно — запрещают, **не разрешая**.
4. **Ingress и Egress независимы.** Правило на входящий трафик к бэкенду ничего не говорит об исходящем из бэкенда.

### Ключевой момент: политики stateful

Это то, что чаще всего ломает голову в третьем пункте задания.

> Запретить бэкенду ходить к фронтенду — и при этом фронтенд продолжает получать **ответы** от бэкенда на свои запросы.

Противоречия нет. NetworkPolicy работает поверх conntrack и фильтрует **установление соединения**, а не отдельные пакеты. Разрешив frontend → backend, ты автоматически разрешил обратные пакеты этой же TCP-сессии. Egress-запрет на бэкенде блокирует только **новые соединения, инициированные бэкендом**.

```
frontend ──[новое соединение]──►  backend      ✅ разрешено Ingress-политикой
frontend ◄──[ответ в той же сессии]── backend  ✅ автоматически (conntrack)
frontend ◄──[новое соединение]──── backend     ❌ заблокировано Egress-политикой
```

### Манифесты

**a) База: запретить всё в namespace** (`podSelector: {}` = все поды)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all, namespace: shop }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

**b) Фронтенд принимает только от ingress-controller** — закрывает прямой внешний доступ ко всему, что не фронт:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-ingress-to-frontend, namespace: shop }
spec:
  podSelector:
    matchLabels: { app: frontend }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
```

> ⚠️ **Грабли №2.** `namespaceSelector` матчится по меткам namespace, а не по имени. Метка `kubernetes.io/metadata.name` ставится автоматически (K8s ≥ 1.22) — на неё и опираемся. Проверить: `kubectl get ns ingress-nginx --show-labels`.

**c) Бэкенд принимает только от фронтенда** — это одновременно и «разрешить фронт→бэк», и «заблокировать внешний доступ к бэку»: внешний трафик физически приходит от ingress-controller, а тот под селектор `app: frontend` не попадает.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-frontend-to-backend, namespace: shop }
spec:
  podSelector:
    matchLabels: { app: backend }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { app: frontend }
      ports:
        - protocol: TCP
          port: 8080          # ← порт КОНТЕЙНЕРА (targetPort), не порт Service
```

> ⚠️ **Грабли №3.** В `ports` пишется порт пода. Service со своим `port: 80` — это kube-proxy/DNAT, к моменту фильтрации адрес уже переписан на `podIP:8080`.

**d) Фронтенду разрешаем ходить к бэкенду и в DNS:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: frontend-egress, namespace: shop }
spec:
  podSelector:
    matchLabels: { app: frontend }
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels: { app: backend }
      ports: [{ protocol: TCP, port: 8080 }]
    - to:                                   # DNS — обязательно
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
```

> ⚠️ **Грабли №4 — самые частые.** Как только на поде появляется любая Egress-политика, он теряет доступ к CoreDNS. Симптом: `curl: could not resolve host backend`, при этом `curl <podIP>:8080` работает. Правило для DNS нужно добавлять в **каждую** Egress-политику.
>
> Ещё: в блоке `to:` два элемента `- namespaceSelector` и `- podSelector` (с дефисами) — это **ИЛИ**, а `namespaceSelector` + `podSelector` под одним дефисом — **И** («под с такой меткой в таком ns»). Разница в одном дефисе меняет смысл правила радикально.

**e) Бэкенду — егресс только в DNS.** Пункт «запретить обратный трафик бэк→фронт» уже выполнен политикой `default-deny-all` (она включила Egress для всех подов ns, а разрешения для бэкенда мы не выдавали). Отдельная политика нужна только чтобы вернуть ему DNS:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: backend-egress-dns, namespace: shop }
spec:
  podSelector: { matchLabels: { app: backend } }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```

### Как проверять

```bash
curl http://shop.local                                                                  # ✅ фронт снаружи
kubectl exec -n shop deploy/frontend -- wget -qO- backend                               # ✅ фронт → бэк
kubectl exec -n shop deploy/backend  -- wget -qO- --timeout=3 frontend                  # ❌ timeout
kubectl run t --image=busybox -n default --rm -it -- wget -qO- --timeout=3 backend.shop # ❌ timeout
```

> Отличай **timeout** (пакет дропнут политикой — то, что нужно) от **connection refused** (пакет дошёл, но никто не слушает — политика не сработала, ищи ошибку в CNI или селекторах).

---

## Сводка «почему это работает»

| Требование | Чем достигается |
|---|---|
| Снаружи только фронт | Ingress упоминает лишь `frontend` + все Service = ClusterIP + Ingress-политика на фронте пускает только `ingress-nginx` |
| Фронт → бэк | Явный `ingress.from.podSelector: app=frontend` на бэкенде |
| Внешний доступ к бэку закрыт | `default-deny-all` + отсутствие правила для `ingress-nginx` у бэкенда |
| Бэк ⇸ фронт | `default-deny-all` включил Egress на бэкенде, разрешений не выдано; ответы на запросы фронта живы благодаря conntrack |
