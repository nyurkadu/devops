# 1. Сеть и CNI: включить CNI и убедиться, что Calico подключен

Задание: **включить CNI и убедиться, что Calico подключен.**

Среда: Windows 11, Minikube (драйвер `docker`), kubectl.

## Файлы манифестов

Все объекты лежат рядом с этим документом отдельными YAML-файлами — их можно применять напрямую, императивные команды в тексте оставлены как альтернатива.

**Рабочие нагрузки**

* [`01-web-deployment.yaml`](01-web-deployment.yaml) — Deployment `web`
  2 реплики nginx, принудительно разведённые по разным нодам.
* [`01-web-service.yaml`](01-web-service.yaml) — Service `web`
  ClusterIP перед деплойментом; получает адрес из service CIDR, а не pod CIDR.
* [`01-client-pod.yaml`](01-client-pod.yaml) — Pod `client`
  busybox для `wget` и `ping`, помечен `role=client`.
* [`01-dnsutils-pod.yaml`](01-dnsutils-pod.yaml) — Pod `dnsutils`
  agnhost для проверки DNS с корректным кодом возврата `nslookup`.

**Сетевые политики** (применяются только на время проверки)

* [`01-netpol-default-deny-ingress.yaml`](01-netpol-default-deny-ingress.yaml) — NetworkPolicy `default-deny-ingress`
  Запрет всего входящего трафика. Доказывает, что политики реально применяются.
* [`01-netpol-allow-client-to-web.yaml`](01-netpol-allow-client-to-web.yaml) — NetworkPolicy `allow-client-to-web`
  Точечное разрешение поверх deny-all: только с подов `role=client` и только на порт 80.

Развернуть всю лабораторию одной командой:

```powershell
kubectl apply -f 01-web-deployment.yaml -f 01-web-service.yaml -f 01-client-pod.yaml -f 01-dnsutils-pod.yaml
kubectl rollout status deployment/web --timeout=120s
kubectl wait --for=condition=Ready pod/client pod/dnsutils --timeout=120s
```

Это быстрый вариант «для повторного запуска». Разбор по шагам — зачем нужен каждый объект и что он даёт для задания — в **Шаге 4.0** ниже.

Политики применяются отдельно — они нужны только на время проверки (шаги 4.4 и 4.5).

---

## Теория: что такое CNI и зачем Calico

**CNI (Container Network Interface)** — стандарт (спецификация + набор плагинов), по которому kubelet просит внешний плагин настроить сеть контейнера. Kubernetes сам сеть **не реализует**, он только задаёт правила игры (модель сети):

* каждый под получает **свой уникальный IP** из pod CIDR;
* любой под может достучаться до любого другого пода **без NAT**;
* нода может достучаться до любого пода на любой ноде.

Реализует эти правила именно CNI-плагин. Когда kubelet создаёт под, он:

1. Создаёт сетевой namespace для sandbox-контейнера (`pause`).
2. Читает конфиг из `/etc/cni/net.d/*.conflist` — кто плагин.
3. Вызывает бинарь плагина из `/opt/cni/bin/` и передаёт ему namespace.
4. Плагин создаёт `veth`-пару, выдаёт IP через IPAM, прописывает маршруты — и возвращает результат kubelet'у.

Пока CNI не готов, нода имеет статус `NotReady` с причиной
`container runtime network not ready: NetworkReady=false ... cni plugin not initialized`,
а поды висят в `ContainerCreating`.

### Что даёт Calico

| Возможность                   | Стандартный CNI Minikube (kindnet/bridge)     | Calico                                                                |
| ----------------------------- | --------------------------------------------- | --------------------------------------------------------------------- |
| IP подам (IPAM)               | да                                            | да, со своими `IPPool`                                                |
| Маршрутизация между нодами    | простые маршруты / VXLAN                      | BGP или VXLAN/IPIP overlay                                            |
| **NetworkPolicy enforcement** | **нет** (политики создаются, но не действуют) | **да** (компонент Felix)                                              |
| CRD и расширения              | нет                                           | `GlobalNetworkPolicy`, `IPPool`, `HostEndpoint`, `FelixConfiguration` |

Ключевое для нашей домашки: **пункты 3 и 4 (namespaces + Network Policies) без Calico не заработают** — kindnet просто игнорирует объекты `NetworkPolicy`. Поэтому Calico включаем первым шагом.

### Компоненты Calico в кластере

| Компонент                         | Тип                                | Что делает                                                                                                                                               |
| --------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `calico-node`                     | DaemonSet (по поду на каждой ноде) | внутри: **Felix** (программирует iptables/nftables и маршруты), **BIRD** (BGP-демон, разносит маршруты между нодами), **confd** (генерирует конфиг BIRD) |
| `calico-kube-controllers`         | Deployment (1 реплика)             | синхронизирует объекты Kubernetes (Pod, Namespace, NetworkPolicy) с датастором Calico, чистит мусор                                                      |
| CNI-бинарь + `10-calico.conflist` | файлы на ноде                      | тот самый плагин, который вызывает kubelet                                                                                                               |

---

## Шаг 0. Проверка окружения

```powershell
minikube version
kubectl version --client
docker version --format '{{.Server.Version}}'
```

Смотрим, какие профили уже есть:

```powershell
minikube profile list
```

```
┌──────────┬────────┬─────────┬──────────────┬─────────┬─────────┬───────┬────────────────┬────────────────────┐
│ PROFILE  │ DRIVER │ RUNTIME │      IP      │ VERSION │ STATUS  │ NODES │ ACTIVE PROFILE │ ACTIVE KUBECONTEXT │
├──────────┼────────┼─────────┼──────────────┼─────────┼─────────┼───────┼────────────────┼────────────────────┤
│ minikube │ docker │ docker  │ 192.168.49.2 │ v1.35.1 │ Stopped │ 1     │ *              │ *                  │
└──────────┴────────┴─────────┴──────────────┴─────────┴─────────┴───────┴────────────────┴────────────────────┘
```

> **Важно:** CNI-плагин выбирается **при создании кластера** и на живом кластере флагом не переключается. Поэтому есть два пути:
> * **Путь A (рекомендуется):** создать **отдельный профиль** `calico` — старый кластер остаётся нетронутым.
> * **Путь B:** удалить текущий кластер (`minikube delete`) и поднять его заново с Calico.
>
> Дальше идём по пути A.

### Примечание: где какая консоль

Все команды в этом документе рассчитаны на **PowerShell 7+** — штатную консоль Windows. Ничего дополнительно ставить не нужно, `kubectl` и `minikube` работают из неё напрямую.

Одно исключение, о котором стоит знать заранее. Команды вида

```powershell
minikube ssh -p calico -- 'ls -l /etc/cni/net.d/'
```

запускаются **из PowerShell**, но то, что стоит после `--` в кавычках, выполняется **внутри ноды**. Нода minikube — это Linux-контейнер, поэтому там и только там встречаются `ls`, `cat`, `ip route`, `grep`. Заменить их на PowerShell-команды нельзя: внутри ноды PowerShell нет, а посмотреть файлы CNI можно исключительно оттуда.

Правило простое: **всё, что в кавычках после `--`, — это Linux; всё остальное — PowerShell.**

Для строки внутри кавычек предпочтительны одинарные кавычки — PowerShell не станет подставлять в неё свои переменные:

```powershell
minikube ssh -p calico -- 'ip route | grep 10.244'
```

---

## Шаг 1. Смотрим, какой CNI сейчас (для сравнения)

Запускаем старый профиль и смотрим системные поды:

```powershell
minikube start -p minikube
kubectl --context minikube get pods -n kube-system -o wide
```

```
NAME                               READY   STATUS    RESTARTS   AGE   IP             NODE
coredns-7d764666f9-6l9lp           1/1     Running   4          21d   10.244.0.112   minikube
etcd-minikube                      1/1     Running   4          21d   192.168.49.2   minikube
kube-apiserver-minikube            1/1     Running   4          21d   192.168.49.2   minikube
kube-controller-manager-minikube   1/1     Running   4          21d   192.168.49.2   minikube
kube-proxy-278lg                   1/1     Running   4          21d   192.168.49.2   minikube
kube-scheduler-minikube            1/1     Running   4          21d   192.168.49.2   minikube
storage-provisioner                1/1     Running   8          21d   192.168.49.2   minikube
```

> Сразу после `minikube start` первые секунды поды могут висеть в `Error` — они перезапускаются после подъёма apiserver. Это нормально, ждём и смотрим снова.
>
> Если `kubectl` в этот момент ругается `dial tcp 127.0.0.1:59923: connectex: No connection could be made` — kubeconfig указывает на **старый порт** остановленного кластера. Лечится:
>
> ```powershell
> minikube update-context -p minikube
> kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
> ```

Ищем конфиг CNI прямо на ноде:

```powershell
minikube ssh -p minikube -- 'ls -l /etc/cni/net.d/ && ls /opt/cni/bin/'
```

Фактический вывод:

```
total 12
-rw-r--r-- 1 root root 496 Aug  7 06:07 1-k8s.conflist
-rw-r--r-- 1 root root 469 Dec 24  2025 10-crio-bridge.conflist.disabled.mk_disabled
-rw-r--r-- 1 root root 639 Nov 13  2022 87-podman-bridge.conflist.mk_disabled
-rw-r--r-- 1 root root   0 Aug  7 06:06 cni.lock

LICENSE    bridge  firewall     ipvlan    portmap  static  vlan
README.md  dhcp    host-device  loopback  ptp      tap     vrf
bandwidth  dummy   host-local   macvlan   sbr      tuning
```

Разбор:

* `1-k8s.conflist` — **активный** конфиг, это встроенный плагин `bridge`;
* файлы с суффиксом `.mk_disabled` отключены самим minikube (конфиги CRI-O и Podman) — kubelet их не читает;
* `cni.lock` — служебный файл minikube нулевого размера, норма;
* в `/opt/cni/bin/` только стандартные плагины из `containernetworking/plugins` — **`calico` и `calico-ipam` отсутствуют**.

Смотрим содержимое активного конфига:

```powershell
minikube ssh -p minikube -- 'sudo cat /etc/cni/net.d/1-k8s.conflist'
```

```json
{
  "cniVersion": "0.4.0",
  "name": "bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "bridge",
      "addIf": "true",
      "isDefaultGateway": true,
      "forceAddress": false,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": { "type": "host-local", "subnet": "10.244.0.0/16" }
    },
    { "type": "portmap", "capabilities": { "portMappings": true } },
    { "type": "firewall" }
  ]
}
```

Ключевое отличие от Calico:

| Параметр                 | bridge (сейчас)                                  | calico (будет)                                               |
| ------------------------ | ------------------------------------------------ | ------------------------------------------------------------ |
| `type`                   | `bridge`                                         | `calico`                                                     |
| `ipam`                   | `host-local` — IP раздаёт локальная база на ноде | `calico-ipam` — IP раздаёт Calico через `IPPool`/`IPAMBlock` |
| секция `policy`          | **отсутствует** → NetworkPolicy не применяется   | `"policy": {"type": "k8s"}` → политики работают              |
| межнодовая маршрутизация | нет (однонодовый сценарий)                       | BGP/IPIP                                                     |

И проверяем, что подов Calico тут нет:

```powershell
kubectl --context minikube get pods -n kube-system | Select-String calico
```

```
(пусто)
```

**Вывод шага:** на профиле `minikube` работает CNI `bridge` без поддержки политик. Объекты `NetworkPolicy` тут создадутся, но трафик блокировать не будут — поэтому дальше поднимаем отдельный кластер с Calico.

---

## Шаг 2. Поднимаем кластер с Calico

```powershell
minikube start -p calico --driver=docker --nodes=2 --cni=calico --cpus=2 --memory=4096 --kubernetes-version=v1.33.1
```

Разбор флагов:

| Флаг                   | Зачем                                                                                     |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `-p calico`            | имя профиля — отдельный кластер, старый не трогаем                                        |
| `--driver=docker`      | ноды как docker-контейнеры                                                                |
| `--nodes=2`            | две ноды, чтобы увидеть **межнодовую** маршрутизацию Calico (для минимума хватит и одной) |
| `--cni=calico`         | minikube применяет манифест Calico сразу после `kubeadm init`                             |
| `--cpus`, `--memory`   | Calico требует заметно больше ресурсов, чем kindnet                                       |
| `--kubernetes-version` | фиксируем версию, чтобы результат воспроизводился                                         |

Что делает `--cni=calico` под капотом:

1. Передаёт kubeadm `--pod-network-cidr=10.244.0.0/16`.
2. Не ставит kindnet.
3. После инициализации применяет встроенный манифест Calico (`/var/tmp/minikube/cni.yaml` внутри ноды).

Переключаем контекст kubectl на новый кластер:

```powershell
kubectl config use-context calico
kubectl config current-context
```

---

## Шаг 3. Убеждаемся, что Calico подключен

Это ядро задания — проверяем **шестью независимыми способами**.

### 3.1. Поды Calico запущены

```powershell
kubectl get pods -n kube-system -o wide | Select-String calico
```

Ожидаем `calico-node-*` на **каждой** ноде и один `calico-kube-controllers-*`, все `Running`, readiness `1/1`:

```
calico-kube-controllers-9b54b4c6c-m4v86   1/1   Running   0   24m   10.244.15.193   calico
calico-node-8kglk                         1/1   Running   0   22m   192.168.58.3    calico-m02
calico-node-tqz4p                         1/1   Running   0   24m   192.168.58.2    calico
```

Обратите внимание: `calico-node` получает **IP ноды** (192.168.58.x) — это под с `hostNetwork: true`, он работает в сетевом namespace хоста, иначе не смог бы настраивать маршруты. А `calico-kube-controllers` — обычный под с IP из pod CIDR (10.244.15.193).

DaemonSet целиком:

```powershell
kubectl -n kube-system get daemonset calico-node
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s
```

```
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
calico-node   2         2         2       2            2           kubernetes.io/os=linux   24m
```

`DESIRED == READY` — плагин живёт на всех нодах.

### 3.2. Ноды перешли в Ready

```powershell
kubectl get nodes -o wide
```

```
NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP    OS-IMAGE                        CONTAINER-RUNTIME
calico       Ready    control-plane   24m   v1.33.1   192.168.58.2   Debian GNU/Linux 12 (bookworm)  docker://29.2.1
calico-m02   Ready    <none>          22m   v1.33.1   192.168.58.3   Debian GNU/Linux 12 (bookworm)  docker://29.2.1
```

> Подсеть нод здесь `192.168.58.0/24` — своя docker-сеть профиля `calico`, она не пересекается с сетью профиля `minikube` (`192.168.49.0/24`). Поэтому два кластера спокойно живут рядом.

`Ready` = kubelet достучался до CNI. Без плагина было бы `NotReady`. Убеждаемся, что причина снята:

```powershell
kubectl get nodes -o "jsonpath={range .items[*]}{.metadata.name}{'\t'}{.status.conditions[?(@.type=='Ready')].message}{'\n'}{end}"
```

```
calico       kubelet is posting ready status
calico-m02   kubelet is posting ready status
```

> **Про кавычки.** В JSONPath строковые литералы можно писать в **одинарных** кавычках: `{'\t'}` и `[?(@.type=='Ready')]`.
> Это важно на Windows: **Windows PowerShell 5.1** (синий `powershell.exe`) вырезает вложенные `"`
> до того, как их увидит `kubectl`, и вариант `-o jsonpath='…{"\t"}…@.type=="Ready"…'` падает с
> `error parsing jsonpath … unrecognized character in action: U+005C`
> (в тексте ошибки видно `{\t}` и `@.type==Ready` — уже без кавычек).
> Обратное экранирование `\"` чинит 5.1, но ломается в **PowerShell 7** (`pwsh`), где `\` доезжает до `kubectl` буквально.
> Форма выше — внешние `"`, внутренние `'` — работает без изменений и в 5.1, и в `pwsh`, и в bash.
> То же правило для `-o custom-columns=...`: `-o "custom-columns=NAME:.metadata.name,MSG:.status.conditions[?(@.type=='Ready')].message"`.

### 3.3. Конфиг CNI лежит на ноде

Самое прямое доказательство — файл, который читает kubelet:

```powershell
minikube ssh -p calico -- 'ls -l /etc/cni/net.d/'
```

```
total 16
-rw------- 1 root root  575 Aug 28 12:17 10-calico.conflist
-rw-r--r-- 1 root root  469 Dec 24  2025 10-crio-bridge.conflist.disabled.mk_disabled
-rw-r--r-- 1 root root  639 Nov 13  2022 87-podman-bridge.conflist.mk_disabled
-rw------- 1 root root 2804 Aug 28 12:18 calico-kubeconfig
-rw-r--r-- 1 root root    0 Aug 28 12:16 cni.lock
```

Сравните с Шагом 1: `1-k8s.conflist` (bridge) **исчез**, вместо него появились `10-calico.conflist` и `calico-kubeconfig` (учётные данные, с которыми CNI-плагин ходит в apiserver — права `600`). Файлы кладёт init-контейнер `install-cni` пода `calico-node`.

```powershell
minikube ssh -p calico -- 'sudo cat /etc/cni/net.d/10-calico.conflist'
```

```json
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "log_level": "info",
      "log_file_path": "/var/log/calico/cni/cni.log",
      "datastore_type": "kubernetes",
      "nodename": "calico",
      "mtu": 0,
      "ipam": {
          "type": "calico-ipam"
      },
      "policy": {
          "type": "k8s"
      },
      "kubernetes": {
          "kubeconfig": "/etc/cni/net.d/calico-kubeconfig"
      }
    },
    {
      "type": "portmap",
      "snat": true,
      "capabilities": {"portMappings": true}
    }
  ]
}
```

Что здесь важно:

* `"type": "calico"` — основной плагин;
* `"ipam": {"type": "calico-ipam"}` — IP подам выдаёт Calico, а не `host-local`;
* `"policy": {"type": "k8s"}` — **Calico применяет Kubernetes NetworkPolicy** (то, что нужно для п.4 домашки); именно этой секции нет у bridge из Шага 1;
* `"nodename": "calico"` — имя ноды, за которую отвечает этот экземпляр плагина (на второй ноде будет `calico-m02`);
* `"mtu": 0` — авто-определение MTU (Calico подбирает сам, с учётом overhead IPIP);
* `"log_file_path"` — куда плагин пишет лог, полезно при отладке `ContainerCreating`: `minikube ssh -p calico -- "sudo tail /var/log/calico/cni/cni.log"`;
* `portmap` — проброс `hostPort`.

И бинари плагина:

```powershell
minikube ssh -p calico -- 'ls /opt/cni/bin/ | grep -i calico'
```

```
calico
calico-ipam
```

Появились те самые бинари, которых не было в Шаге 1.

### 3.4. Установлены CRD и IP-пул Calico

```powershell
kubectl get crd | Select-String projectcalico
```

```
bgpconfigurations.crd.projectcalico.org                 2026-08-28T12:16:57Z
bgpfilters.crd.projectcalico.org                        2026-08-28T12:16:57Z
bgppeers.crd.projectcalico.org                          2026-08-28T12:16:57Z
blockaffinities.crd.projectcalico.org                   2026-08-28T12:16:57Z
caliconodestatuses.crd.projectcalico.org                2026-08-28T12:16:57Z
clusterinformations.crd.projectcalico.org               2026-08-28T12:16:57Z
felixconfigurations.crd.projectcalico.org               2026-08-28T12:16:57Z
globalnetworkpolicies.crd.projectcalico.org             2026-08-28T12:16:57Z
globalnetworksets.crd.projectcalico.org                 2026-08-28T12:16:57Z
hostendpoints.crd.projectcalico.org                     2026-08-28T12:16:57Z
ipamblocks.crd.projectcalico.org                        2026-08-28T12:16:57Z
ipamconfigs.crd.projectcalico.org                       2026-08-28T12:16:57Z
ipamhandles.crd.projectcalico.org                       2026-08-28T12:16:57Z
ippools.crd.projectcalico.org                           2026-08-28T12:16:57Z
ipreservations.crd.projectcalico.org                    2026-08-28T12:16:57Z
kubecontrollersconfigurations.crd.projectcalico.org     2026-08-28T12:16:57Z
networkpolicies.crd.projectcalico.org                   2026-08-28T12:16:57Z
networksets.crd.projectcalico.org                       2026-08-28T12:16:57Z
stagedglobalnetworkpolicies.crd.projectcalico.org       2026-08-28T12:16:57Z
stagedkubernetesnetworkpolicies.crd.projectcalico.org   2026-08-28T12:16:57Z
stagednetworkpolicies.crd.projectcalico.org             2026-08-28T12:16:58Z
tiers.crd.projectcalico.org                             2026-08-28T12:16:58Z
```

22 CRD — сам факт их наличия уже доказывает, что манифест Calico применён. Что пригодится дальше:

| CRD                                         | Зачем                                                                                     |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `ippools`                                   | диапазоны, из которых раздаются IP подам                                                  |
| `ipamblocks` / `blockaffinities`            | какой кусок пула закреплён за какой нодой                                                 |
| `networkpolicies` / `globalnetworkpolicies` | политики Calico (в дополнение к стандартным `networking.k8s.io`)                          |
| `felixconfigurations`                       | тюнинг движка политик (логи, MTU, режим iptables)                                         |
| `bgppeers` / `bgpconfigurations`            | ручная настройка BGP-пиринга                                                              |
| `staged*`                                   | «черновые» политики: считаются, но не применяются — удобно проверить правило до включения |

Смотрим пул адресов, из которого Calico раздаёт IP подам:

```powershell
kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr,IPIP:.spec.ipipMode,VXLAN:.spec.vxlanMode,NAT:.spec.natOutgoing
```

```
NAME                  CIDR            IPIP     VXLAN   NAT
default-ipv4-ippool   10.244.0.0/16   Always   Never   true
```

* `CIDR` — **pod CIDR** кластера, совпадает с `--pod-network-cidr`;
* `IPIP: Always` — трафик между нодами инкапсулируется в IP-in-IP (overlay);
* `natOutgoing: true` — трафик наружу маскарадится под IP ноды.

Дополнительно — блоки IPAM, выданные нодам (по /26 на ноду):

```powershell
kubectl get ipamblocks.crd.projectcalico.org -o custom-columns=BLOCK:.spec.cidr,NODE:.spec.affinity
```

```
BLOCK              NODE
10.244.15.192/26   host:calico
10.244.228.0/26    host:calico-m02
```

Каждой ноде выдан блок `/26` (64 адреса) из общего пула `10.244.0.0/16`. Именно поэтому под `web` на ноде `calico` получил `10.244.15.195`, а `client` на `calico-m02` — `10.244.228.2`. Блоки нарезаются по мере надобности, а не сразу.

### 3.5. Разница pod CIDR и service CIDR

```powershell
kubectl cluster-info dump | Select-String "cluster-cidr|service-cluster-ip-range" | Select-Object -First 2
```

```
                            "--service-cluster-ip-range=10.96.0.0/12",
                            "--cluster-cidr=10.244.0.0/16",
```

(вывод — куски JSON-манифестов apiserver и controller-manager, отсюда кавычки и отступы)

| Параметр                    | Pod CIDR                        | Service CIDR                                      |
| --------------------------- | ------------------------------- | ------------------------------------------------- |
| Диапазон                    | `10.244.0.0/16`                 | `10.96.0.0/12`                                    |
| Кто раздаёт                 | **CNI (Calico IPAM)**           | apiserver                                         |
| Что получает адрес          | реальный сетевой интерфейс пода | виртуальный ClusterIP                             |
| Есть ли интерфейс с этим IP | да (`eth0` внутри пода)         | **нет**, это правило в iptables/IPVS (kube-proxy) |
| Пингуется                   | да                              | нет (ping ClusterIP не отвечает — это нормально)  |

### 3.6. Статус демонов внутри calico-node (BIRD/Felix)

```powershell
$POD = kubectl -n kube-system get pods -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}'
kubectl -n kube-system exec $POD -- calico-node -bird-ready  ; "bird exit=$LASTEXITCODE"
kubectl -n kube-system exec $POD -- calico-node -felix-ready ; "felix exit=$LASTEXITCODE"
```

Фактический вывод:

```
Defaulted container "calico-node" out of: calico-node, upgrade-ipam (init), install-cni (init), ebpf-bootstrap (init)
2026-08-28 12:41:48.321 [INFO][5435] node/health.go 206: Number of node(s) with BGP peering established = 1
bird exit=0
Defaulted container "calico-node" out of: calico-node, upgrade-ipam (init), install-cni (init), ebpf-bootstrap (init)
felix exit=0
```

Разбор:

* `BGP peering established = 1` — эта нода установила BGP-сессию со второй нодой, маршруты к её подам получены;
* `bird exit=0` и `felix exit=0` — оба демона живы: BIRD раздаёт маршруты, Felix программирует правила политик;
* строка `Defaulted container ...` — не ошибка, а подсказка kubectl: в поде несколько контейнеров, выбран основной `calico-node`. Заодно видно init-контейнеры: `install-cni` (кладёт `10-calico.conflist` и бинари на ноду) и `upgrade-ipam`.

Логи, если что-то не так:

```powershell
kubectl -n kube-system logs -l k8s-app=calico-node --tail=50
kubectl -n kube-system logs deploy/calico-kube-controllers --tail=30
```

Маршруты, которые Calico прописал на ноде (`tunl0` — интерфейс IPIP, `cali*` — veth-концы подов):

```powershell
minikube ssh -p calico -- "ip route | grep -E 'tunl0|cali|10.244'"
minikube ssh -p calico -- "ip -br addr show | grep -E 'tunl0|cali'"
```

Фактический вывод (нода `calico`):

```
blackhole 10.244.15.192/26 proto bird
10.244.15.193 dev calif4ce55d026d scope link
10.244.15.194 dev cali731285958e0 scope link
10.244.15.195 dev cali4e1304ee4fe scope link
10.244.228.0/26 via 192.168.58.3 dev tunl0 proto bird onlink
```

Это вся сетевая картина Calico в пяти строках:

| Строка                                                         | Что означает                                                                                                                  |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `blackhole 10.244.15.192/26 proto bird`                        | «мой» блок IPAM; пакеты на ещё не выданные адреса блока отбрасываются сразу, а не гуляют по сети                              |
| `10.244.15.193/194/195 dev caliXXXX scope link`                | по маршруту **на каждый локальный под** через его `veth`-интерфейс `cali*` (это `calico-kube-controllers`, `coredns` и `web`) |
| `10.244.228.0/26 via 192.168.58.3 dev tunl0 proto bird onlink` | блок **второй ноды** доступен через IPIP-туннель `tunl0` на адрес ноды `192.168.58.3`                                         |
| `proto bird`                                                   | маршрут прописан демоном BIRD по BGP, а не руками и не kubelet'ом                                                             |

Отсюда же видно, почему `ping` между подами разных нод даёт `ttl=62`: пакет прошёл через два маршрутизатора (обе ноды).

---

## Шаг 4. Функциональная проверка: сеть реально работает

Шаги 1-3 доказали, что Calico **установлен**: файлы на месте, поды бегут, маршруты построены. Но установленный плагин и работающая сеть — не одно и то же. Задание требует «убедиться, что Calico подключен», а единственное честное доказательство подключения — что через него **ходит трафик** и **применяются политики**.

Для этого нужен стенд: кто-то, кто отвечает по сети, и кто-то, кто к нему обращается **изнутри кластера** (снаружи pod-to-pod не проверить — адреса `10.244.0.0/16` за пределами кластера не маршрутизируются).

### 4.0. Развёртывание лаборатории по шагам

Разворачиваем не «всё сразу», а по одному объекту — так видно, какую именно часть задания закрывает каждый.

| Шаг   | Объект            | Что закрывает в задании                                             |
| ----- | ----------------- | ------------------------------------------------------------------- |
| 4.0.1 | Deployment `web`  | цель для запросов; поды на разных нодах → проверка маршрутизации CNI |
| 4.0.2 | Service `web`     | service CIDR, kube-proxy, DNS-имя для CoreDNS                       |
| 4.0.3 | Pod `client`      | источник трафика внутри сети подов + метка для будущих политик      |
| 4.0.4 | Pod `dnsutils`    | однозначная проверка CoreDNS                                        |
| 4.0.5 | ожидание Ready    | отсекает ложные «сетевые» ошибки на неподнявшихся подах             |
| 4.0.6 | таблица раскладки | доказательство работы Calico IPAM ещё до тестов трафика             |

Итог этого блока — стенд, на котором дальше проверяется всё остальное: связность между нодами (4.1), сервисы (4.2), DNS (4.3) и, главное, реальное применение сетевых политик (4.4-4.5).

---

#### Шаг 4.0.1. Deployment `web` — цель для проверки связности

**Зачем:** нужен сервер, который отвечает по HTTP. Две реплики нужны не для отказоустойчивости, а чтобы **поды оказались на разных нодах**. Тест внутри одной ноды прошёл бы даже без Calico — там пакет не покидает хост. Настоящая проверка CNI начинается тогда, когда трафик идёт с ноды на ноду через IPIP-туннель, который построил Calico.

```powershell
kubectl apply -f 01-web-deployment.yaml
```

**Что происходит под капотом:** Deployment → ReplicaSet → 2 пода; для каждого пода kubelet зовёт CNI-плагин Calico, тот выдаёт IP из блока своей ноды и создаёт `veth`-интерфейс. То есть уже на этом шаге Calico делает работу — если бы плагин был сломан, поды застряли бы в `ContainerCreating`.

> **Почему в манифесте есть `topologySpreadConstraints`.** Без него планировщик спокойно ставит обе реплики на одну ноду — проверено, именно так и произошло при первом запуске. Тогда тест связности выходит внутринодовым и IPIP-туннель Calico вообще не участвует. Мягкий вариант `whenUnsatisfiable: ScheduleAnyway` планировщик тоже проигнорировал, поэтому в файле стоит жёсткий `DoNotSchedule`: при 2 репликах и 2 нодах это даёт ровно по одному поду на ноду.

---

#### Шаг 4.0.2. Service `web` — вторая адресация и kube-proxy

**Зачем:** проверить, что работает не только pod CIDR, но и **service CIDR**. Это прямо из теоретической части задания — «разница между CIDR pod и CIDR service». Сервис даёт виртуальный ClusterIP из `10.96.0.0/12`, за которым стоит правило kube-proxy, а не сетевой интерфейс. Заодно появляется DNS-имя `web.default.svc.cluster.local` — так подключается CoreDNS, ещё один пункт теории.

```powershell
kubectl apply -f 01-web-service.yaml
```

**Что проверим позже:** запрос по имени сервиса пройдёт цепочку DNS → ClusterIP → правило iptables → DNAT на IP пода → маршрут Calico. Если сломано любое звено — ответа не будет.

---

#### Шаг 4.0.3. Pod `client` — источник трафика внутри кластера

**Зачем:** нужен тот, кто отправляет запросы **из сети подов**. С хоста Windows или даже с самой ноды pod-to-pod связность не проверяется — нужен под, живущий в той же оверлейной сети.

```powershell
kubectl apply -f 01-client-pod.yaml
```

**Обратите внимание на метку `role=client`** в манифесте. Сейчас она ни на что не влияет, но именно по ней в шаге 4.5 сетевая политика будет отличать «свой» под от чужого. Метки — единственный способ, которым NetworkPolicy выбирает поды; IP-адреса в политиках не используются, потому что они меняются при каждом пересоздании.

---

#### Шаг 4.0.4. Pod `dnsutils` — честная проверка DNS

**Зачем:** отдельный под с нормальным `nslookup`. У busybox-версии есть известная особенность — она возвращает код ошибки даже при успешном резолве, и это путает при проверке. Чтобы вывод «работает / не работает» был однозначным, берём образ `agnhost`.

```powershell
kubectl apply -f 01-dnsutils-pod.yaml
```

Этот под тоже помечен `role=client` — в шаге 4.5 он покажет, что политика пускает **любой** под с нужной меткой, а не конкретно `client`.

---

#### Шаг 4.0.5. Дождаться готовности

**Зачем:** `kubectl apply` только записывает объекты в etcd и возвращает управление сразу. Поды в этот момент ещё качают образы. Если сразу перейти к проверкам, `kubectl exec` упадёт с «container not running», и вы будете искать проблему в сети там, где её нет.

```powershell
kubectl rollout status deployment/web --timeout=120s
kubectl wait --for=condition=Ready pod/client pod/dnsutils --timeout=120s
```

Эти команды блокируют терминал, пока всё не поднимется, и падают с ненулевым кодом по таймауту — то есть останавливают вас на реальной проблеме (например, `ImagePullBackOff`), а не дают получить непонятный отказ двумя шагами позже.

---

#### Шаг 4.0.6. Проверить раскладку — первое доказательство работы IPAM

**Зачем:** до всяких `wget` таблица размещения уже отвечает на два вопроса задания: работает ли IPAM Calico (адреса из pod CIDR, каждый из блока своей ноды) и будет ли следующий тест межнодовым (реплики на разных нодах).

```powershell
kubectl get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
```

```
POD                    IP              NODE
client                 10.244.228.6    calico-m02
dnsutils               10.244.228.7    calico-m02
web-6c6b8cb6d8-gmkt4   10.244.15.196   calico
web-6c6b8cb6d8-jhxhx   10.244.228.9    calico-m02
```

Всё как ожидалось: адреса из pod CIDR `10.244.0.0/16`, причём каждый под получил IP **из блока своей ноды** (`10.244.15.192/26` для `calico`, `10.244.228.0/26` для `calico-m02`). Реплики `web` разъехались по разным нодам — значит следующий тест будет действительно межнодовым.

> IP подов меняются при каждом пересоздании — в своих командах подставляйте актуальные из этой таблицы, а не из примеров ниже.

#### Императивный вариант того же самого

Быстрее набрать руками, но результат нельзя положить в git и повторить один в один — поэтому в работе используем манифесты, а это оставляем для справки:

```powershell
kubectl create deployment web --image=nginx:1.25 --replicas=2
kubectl expose deployment web --port=80
kubectl run client --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never -- pause
```

Чего здесь не хватает по сравнению с манифестами: `topologySpreadConstraints` (реплики могут сесть на одну ноду и сломать смысл теста) и метки `role=client` (её придётся добавлять отдельно через `--labels`, иначе политика из 4.5 не сработает).

### 4.1. Под → под напрямую (pod-to-pod, в т.ч. между нодами)

```powershell
$WEB_IP = kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}'
kubectl exec client -- wget -qO- --timeout=5 "http://$WEB_IP" | Select-Object -First 5
kubectl exec client -- ping -c 3 $WEB_IP
```

Фактический вывод (`client` на `calico-m02` → `web` на `calico`, то есть **через ноду**):

```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

```
64 bytes from 10.244.15.196: seq=2 ttl=62 time=0.195 ms

--- 10.244.15.196 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 0.141/0.199/0.261 ms
```

Ответ nginx и 0% потерь = Calico построил маршрут между подами разных нод. `ttl=62` (а не 64) подтверждает, что пакет прошёл через IPIP-туннель и два хопа.

> Если `$WEB_IP` подставился IP реплики **на той же ноде**, что и `client`, тест получится внутринодовым. Чтобы проверить именно межнодовый случай, возьмите IP явно из таблицы выше — реплики, которая живёт на другой ноде.

### 4.2. Под → Service (проверяем kube-proxy)

```powershell
kubectl exec client -- wget -qO- --timeout=5 http://web.default.svc.cluster.local | Select-Object -First 5
```

```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

Тут сработала уже другая цепочка: DNS-имя → ClusterIP `10.96.171.115` → правило kube-proxy в iptables → DNAT на IP одного из подов → маршрут Calico. То есть проверены обе адресации сразу — service CIDR и pod CIDR.

### 4.3. DNS (CoreDNS)

```powershell
kubectl exec client -- nslookup kubernetes.default
kubectl exec client -- nslookup web
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get svc kube-dns
```

```
Name:	web.default.svc.cluster.local
Address: 10.96.171.115

command terminated with exit code 1
```

Имя разрешилось в ClusterIP сервиса — DNS работает.

> `command terminated with exit code 1` здесь **не ошибка кластера**, а известная особенность `nslookup` из busybox: он возвращает ненулевой код, если не смог обратно разрезолвить адрес DNS-сервера (`10.96.0.10`). Строки `Name:`/`Address:` есть — значит запрос отработал.

Чтобы не путаться с кодом возврата, берём образ с нормальным `nslookup`:

```powershell
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/agnhost:2.39 --restart=Never -- pause
kubectl wait --for=condition=Ready pod/dnsutils --timeout=90s
kubectl exec dnsutils -- nslookup web.default.svc.cluster.local
```

```
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	web.default.svc.cluster.local
Address: 10.96.171.115
```

Код возврата `0`, виден и сам DNS-сервер `10.96.0.10` — это ClusterIP сервиса `kube-dns`.

> **Внимание к аргументу:** именно `-- pause`, а не `-- sleep 3600`. У образа `agnhost` entrypoint — его собственный бинарь с набором подкоманд, и `sleep` среди них нет. С `sleep 3600` под сразу падает:
>
> ```
> kubectl logs dnsutils
> Error: unknown command "sleep" for "app"
>
> kubectl exec dnsutils -- nslookup web
> error: cannot exec into a container in a completed pod; current phase is Failed
> ```
>
> Это общее правило: аргументы после `--` в `kubectl run` подставляются **не в shell, а в ENTRYPOINT образа**. У `busybox` entrypoint — `sh`, поэтому `sleep 3600` там работает; у `agnhost` — нет. Диагностика всегда одна: `kubectl logs <pod>` и `kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].state.terminated}'`.

Цепочка резолвинга: под → `/etc/resolv.conf` с `nameserver 10.96.0.10` → ClusterIP сервиса `kube-dns` → под CoreDNS → ответ. Проверить сам CoreDNS:

```powershell
kubectl exec client -- cat /etc/resolv.conf
kubectl -n kube-system get svc kube-dns
```

### 4.4. Главное доказательство: NetworkPolicy действительно применяется

Это отличает Calico от дефолтного плагина. Вешаем deny-all на namespace и проверяем, что трафик пропал:

```powershell
kubectl apply -f 01-netpol-default-deny-ingress.yaml
```

Содержимое файла [`01-netpol-default-deny-ingress.yaml`](01-netpol-default-deny-ingress.yaml):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}          # {} = все поды в namespace
  policyTypes:
    - Ingress              # запрещаем только входящий трафик
```

Тот же объект можно применить и без файла — через here-string `@'...'@`. Закрывающий `'@` обязан стоять **в начале строки, без отступа**, иначе PowerShell выдаст ошибку разбора:

```powershell
@'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
'@ | kubectl apply -f -
```

```
networkpolicy.networking.k8s.io/default-deny-ingress created
```

Повторяем тот же запрос, что успешно работал в 4.1:

```powershell
kubectl exec client -- wget -qO- --timeout=5 "http://$WEB_IP"
if ($LASTEXITCODE -ne 0) { "ЗАБЛОКИРОВАНО — Calico применяет политики" }
```

```
wget: download timed out
command terminated with exit code 1
ЗАБЛОКИРОВАНО — Calico применяет политики
```

**Это и есть главное доказательство.** Ровно тот же запрос: минуту назад отдавал страницу nginx, а после применения политики — таймаут. Значит `NetworkPolicy` не просто создалась как объект в etcd, а **реально превратилась в правила фильтрации** на нодах (их программирует Felix из `calico-node`).

На кластере из Шага 1 (CNI `bridge`) та же политика создалась бы с тем же сообщением `created`, но запрос всё равно прошёл бы — плагин её просто игнорирует. Отсюда типичная ловушка: «политику применил, а она не работает» почти всегда означает CNI без поддержки policy.

Разбор параметров политики:

| Поле                     | Значение                           | Что делает                                                                                       |
| ------------------------ | ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `podSelector: {}`        | пустой селектор                    | политика применяется **ко всем подам** namespace; если указать `matchLabels`, попадут только они |
| `policyTypes: [Ingress]` | только входящий                    | исходящий трафик не ограничен — под может ходить наружу, но к нему прийти нельзя                 |
| нет секции `ingress:`    | нет ни одного разрешающего правила | значит разрешено **ничего** — это и есть deny-all                                                |
| `namespace: default`     | —                                  | политика действует только в своём namespace, соседние не затрагивает                             |

Логика, которую важно запомнить: пока на под не наведена **ни одна** политика — разрешено всё. Как только появилась хотя бы одна, под переходит в режим «запрещено всё, кроме явно разрешённого» указанным типом трафика. Правила только разрешают; правил «запретить» в Kubernetes NetworkPolicy нет.

Убираем политику, чтобы не мешала дальнейшим пунктам домашки:

```powershell
kubectl delete -f 01-netpol-default-deny-ingress.yaml
kubectl exec client -- wget -qO- --timeout=5 "http://$WEB_IP" | Select-Object -First 3
```

```
networkpolicy.networking.k8s.io "default-deny-ingress" deleted from default namespace
<!DOCTYPE html>
<html>
<head>
```

Связность вернулась мгновенно — Felix снял правила сразу после удаления объекта.

### 4.5. Точечное разрешение: политики складываются

Deny-all показал, что enforcement работает. Теперь проверим вторую половину модели — что политики **суммируются по логике OR**: трафик разрешён, если его разрешает хотя бы одна из них.

Оставляем deny-all и добавляем поверх точечное разрешение [`01-netpol-allow-client-to-web.yaml`](01-netpol-allow-client-to-web.yaml):

```yaml
spec:
  podSelector:              # кого защищаем
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:      # кому разрешаем
            matchLabels:
              role: client
      ports:                # что именно разрешаем
        - protocol: TCP
          port: 80
```

Три уровня селекторов, которые важно не перепутать:

| Где                          | Значение       | Отвечает за                                       |
| ---------------------------- | -------------- | ------------------------------------------------- |
| `spec.podSelector`           | `app: web`     | **к кому** применяется политика — защищаемые поды |
| `ingress.from[].podSelector` | `role: client` | **кому** разрешён доступ — источники трафика      |
| `ingress.ports[]`            | `TCP/80`       | **что** разрешено; без этой секции — все порты    |

Проверяем на трёх подах: `client` и `dnsutils` имеют метку `role=client`, а временный `stranger` — нет.

```powershell
kubectl apply -f 01-netpol-default-deny-ingress.yaml -f 01-netpol-allow-client-to-web.yaml

kubectl exec client   -- wget -qO- --timeout=5 http://web | Select-Object -First 2
kubectl exec dnsutils -- wget -qO- --timeout=5 http://web | Select-Object -First 2

kubectl run stranger --image=busybox:1.36 --restart=Never --labels=run=stranger -- sleep 300
kubectl wait --for=condition=Ready pod/stranger --timeout=90s
kubectl exec stranger -- wget -qO- --timeout=5 http://web | Select-Object -First 2
```

Фактический результат:

```
-- client (role=client) --
<!DOCTYPE html>
<html>
-- dnsutils (role=client) --
<!DOCTYPE html>
<html>
-- stranger (без метки) --
wget: download timed out
command terminated with exit code 1
```

Итог: deny-all продолжает действовать, но для подов с меткой `role=client` пробита дырка на порт 80. Под без метки по-прежнему отрезан. Это ровно тот механизм, который понадобится в задании 4 домашки — управление доступом между конкретными подами.

Убираем всё за собой:

```powershell
kubectl delete -f 01-netpol-allow-client-to-web.yaml -f 01-netpol-default-deny-ingress.yaml
kubectl delete pod stranger
```

---

## Шаг 5. Сводная проверка одной командой

```powershell
"=== CNI conflist ==="; minikube ssh -p calico -- 'ls /etc/cni/net.d/'
"=== calico pods ===";  kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
"=== controllers ===";  kubectl -n kube-system get deploy calico-kube-controllers
"=== ippool ===";       kubectl get ippools.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,CIDR:.spec.cidr
"=== nodes ===";        kubectl get nodes -o wide
```

В PowerShell строка сама по себе выводится на экран, поэтому `echo` не нужен, а `;` разделяет команды в одной строке.

### Чек-лист «Calico подключен» — результат

| #  | Проверка                                                                        | Факт |
| -- | ------------------------------------------------------------------------------- | ---- |
| 1  | `10-calico.conflist` в `/etc/cni/net.d/`, `1-k8s.conflist` (bridge) исчез       | ✅    |
| 2  | `/opt/cni/bin/calico` и `calico-ipam` на месте                                  | ✅    |
| 3  | DaemonSet `calico-node` — DESIRED 2 / READY 2, поды `1/1 Running`               | ✅    |
| 4  | Deployment `calico-kube-controllers` — `1/1 Running`                            | ✅    |
| 5  | Обе ноды `Ready` (`calico`, `calico-m02`, v1.33.1)                              | ✅    |
| 6  | 22 CRD `*.crd.projectcalico.org`, есть `default-ipv4-ippool 10.244.0.0/16`      | ✅    |
| 7  | Блоки IPAM выданы нодам: `10.244.15.192/26` и `10.244.228.0/26`                 | ✅    |
| 8  | BGP-сессия установлена (`BGP peering established = 1`), `bird`/`felix` exit=0   | ✅    |
| 9  | Маршрут к подам второй ноды через `tunl0` (IPIP), `proto bird`                  | ✅    |
| 10 | Под-под связность между нодами: nginx отвечает, ping 0% loss, `ttl=62`          | ✅    |
| 11 | Под → Service по DNS-имени (`10.96.171.115`) работает                           | ✅    |
| 12 | `NetworkPolicy` deny-all **реально блокирует** трафик (`download timed out`)    | ✅    |
| 13 | Точечная политика `allow-client-to-web` пускает `role=client` и режет остальных | ✅    |
| 14 | Все объекты воспроизводятся из YAML-манифестов рядом с документом               | ✅    |

---

## Troubleshooting

| Симптом                                         | Причина                             | Что делать                                                                                                                                                                                          |
| ----------------------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ноды `NotReady`, `cni plugin not initialized`   | манифест Calico не применился       | `kubectl -n kube-system get pods`, `minikube logs -p calico`, переприменить: `minikube ssh -p calico -- "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /var/tmp/minikube/cni.yaml"` |
| Поды висят в `ContainerCreating`                | `calico-node` не готов / нет образа | `kubectl describe pod <pod>`, `kubectl -n kube-system logs -l k8s-app=calico-node`                                                                                                                  |
| `calico-node` `0/1 Running`, readiness падает   | BIRD не установил BGP-сессии        | `kubectl -n kube-system exec <calico-node> -- calico-node -bird-ready`, проверить автодетект IP: `kubectl -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD=interface=eth0`             |
| Связность есть внутри ноды, но нет между нодами | не поднялся IPIP/VXLAN туннель      | `minikube ssh -- ip route`, проверить `tunl0`; посмотреть `ipipMode` в IPPool                                                                                                                       |
| Обрывы больших пакетов, curl висит на TLS       | неверный MTU                        | `kubectl -n kube-system get cm calico-config -o yaml`, выставить `veth_mtu` (для IPIP обычно 1440)                                                                                                  |
| `NetworkPolicy` не работает                     | кластер поднят не с Calico          | `ls /etc/cni/net.d/` — там kindnet; пересоздать кластер с `--cni=calico`                                                                                                                            |
| `kubeconfig: Misconfigured` в `minikube status` | kubectl смотрит на старый порт      | `minikube update-context -p <profile>`                                                                                                                                                              |

---

## Шаг 6. Уборка / переключение обратно

```powershell
# удалить объекты лаборатории (кластер остаётся)
kubectl delete -f 01-netpol-allow-client-to-web.yaml -f 01-netpol-default-deny-ingress.yaml --ignore-not-found
kubectl delete -f 01-web-deployment.yaml -f 01-web-service.yaml -f 01-client-pod.yaml -f 01-dnsutils-pod.yaml --ignore-not-found

# вернуться на старый кластер
kubectl config use-context minikube

# остановить calico-кластер (сохранив его)
minikube stop -p calico

# или полностью удалить
minikube delete -p calico

# список контекстов
kubectl config get-contexts
```

---

## Шпаргалка команд

```powershell
# создание кластера с CNI Calico
minikube start -p calico --driver=docker --nodes=2 --cni=calico --cpus=2 --memory=4096

# проверка компонентов
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
kubectl -n kube-system get ds calico-node
kubectl -n kube-system get deploy calico-kube-controllers
kubectl get crd | Select-String projectcalico
kubectl get ippools.crd.projectcalico.org

# проверка на ноде (в кавычках — Linux-команды, выполняются внутри ноды)
minikube ssh -p calico -- 'ls -l /etc/cni/net.d/'
minikube ssh -p calico -- 'sudo cat /etc/cni/net.d/10-calico.conflist'
minikube ssh -p calico -- 'ls /opt/cni/bin/'
minikube ssh -p calico -- 'ip route | grep 10.244'

# CIDR'ы
kubectl cluster-info dump | Select-String "cluster-cidr|service-cluster-ip-range"

# развернуть лабораторию из манифестов
kubectl apply -f 01-web-deployment.yaml -f 01-web-service.yaml -f 01-client-pod.yaml -f 01-dnsutils-pod.yaml

# политики (только на время проверки)
kubectl apply  -f 01-netpol-default-deny-ingress.yaml
kubectl apply  -f 01-netpol-allow-client-to-web.yaml
kubectl delete -f 01-netpol-allow-client-to-web.yaml -f 01-netpol-default-deny-ingress.yaml

# функциональная проверка
kubectl get pods -o custom-columns=POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName
kubectl exec client -- wget -qO- http://<POD_IP>
kubectl exec client -- nslookup kubernetes.default

# логи
kubectl -n kube-system logs -l k8s-app=calico-node --tail=50
minikube logs -p calico
```

---

## Итог

CNI включён через флаг `--cni=calico` при создании кластера — на живом кластере плагин не меняется, поэтому был поднят отдельный профиль `calico` (2 ноды, Kubernetes v1.33.1), а исходный профиль `minikube` остался нетронутым.

Подключение Calico подтверждено на трёх независимых уровнях:

1. **Файлы на ноде** — `10-calico.conflist` с `"ipam": calico-ipam` и `"policy": {"type": "k8s"}` вместо прежнего `1-k8s.conflist` (bridge + host-local, без секции policy); бинари `calico` и `calico-ipam` в `/opt/cni/bin/`.
2. **Объекты Kubernetes** — DaemonSet `calico-node` 2/2 на обеих нодах, `calico-kube-controllers` 1/1, 22 CRD `*.crd.projectcalico.org`, пул `default-ipv4-ippool 10.244.0.0/16` с IPIP, блоки `/26` закреплены за нодами.
3. **Поведение сети** — поды получили IP из pod CIDR каждый из блока своей ноды; связность между подами **разных нод** идёт через IPIP-туннель `tunl0` по маршрутам `proto bird`; BGP-сессия между нодами установлена; deny-all `NetworkPolicy` реально обрывает трафик и восстанавливает его после удаления.

Последний пункт — обязательное условие для заданий 3 и 4 домашней работы: на CNI без поддержки policy (`bridge`, kindnet) объекты `NetworkPolicy` создаются, но не действуют.
