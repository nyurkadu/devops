# 3. Стратегии обновления в деплойменте

Задание: **Настроить и опробовать разные стратегии обновления в деплойменте.**

Продолжение работы с деплойментом `nginx-deploy` из [01_deployment_rollout.md](01_deployment_rollout.md) и [02_revisions_rollback.md](02_revisions_rollback.md).

`spec.strategy` в Deployment поддерживает два типа:

- **`RollingUpdate`** (по умолчанию) — постепенная замена подов, управляется `maxUnavailable` и `maxSurge`.
- **`Recreate`** — все старые поды удаляются, и только потом создаются новые (гарантированный простой).

Чтобы увидеть разницу вживую, для каждой стратегии запускался `kubectl set image` с параллельным опросом `kubectl get pods` каждые 0.5 секунды.

Стартовое состояние: `nginx-deploy`, 3 реплики, образ `nginx:1.26`, стратегия по умолчанию:

```bash
kubectl get deployment nginx-deploy -o jsonpath='{.spec.strategy}'
```

```
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

---

## Стратегия 1: `Recreate`

Все поды старой версии убиваются, и только после этого создаются новые — между ними неизбежен простой (0 доступных реплик).

### Настройка

```bash
kubectl patch deployment nginx-deploy -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}'
```

```
deployment.apps/nginx-deploy patched
```

```bash
kubectl get deployment nginx-deploy -o jsonpath='{.spec.strategy}'
```

```
{"type":"Recreate"}
```

### Ролаут под наблюдением (образ 1.26 → 1.25)

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.25
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="Recreate strategy: 1.26 -> 1.25" --overwrite
```

Параллельный снимок `kubectl get pods -l app=nginx-deploy` каждые 0.5с (сокращено, полные строки состояния):

```
[15:21:31] q4v22 Running | t47wk Running | vhgff Running                     ← 3 старых пода работают
[15:21:33] q4v22 Terminating | t47wk Terminating | vhgff Terminating         ← ВСЕ старые поды одновременно начали останавливаться
[15:21:34] (только 2 старых Completed, новых ещё нет)                       ← окно простоя: 0 готовых подов
[15:21:34] c7hzf ContainerCreating | hmf57 ContainerCreating | slhj7 ContainerCreating   ← все 3 новых пода стартуют одновременно
[15:21:37] slhj7 Running (1/1)
[15:21:38] c7hzf Running | hmf57 Running | slhj7 Running                     ← все 3 новых пода готовы
```

```bash
kubectl rollout status deployment/nginx-deploy --timeout=60s
```

```
deployment "nginx-deploy" successfully rolled out
```

**Наблюдение:** между `[15:21:34]` (все старые Terminating/Completed) и появлением новых подов было полное отсутствие готовых реплик — классический простой (downtime), характерный для `Recreate`. Все 3 старых пода уходят разом и все 3 новых поднимаются разом — никакого overlap.

---

## Стратегия 2: `RollingUpdate` c `maxUnavailable=0, maxSurge=1`

Zero-downtime вариант: деплоймент никогда не опускается ниже желаемого числа реплик, но временно может превысить его на 1 (surge).

### Настройка

```bash
kubectl patch deployment nginx-deploy -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":0,"maxSurge":1}}}}'
```

```
deployment.apps/nginx-deploy patched
```

```bash
kubectl get deployment nginx-deploy -o jsonpath='{.spec.strategy}'
```

```
{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"}
```

### Ролаут под наблюдением (образ 1.25 → 1.26)

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.26
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="RollingUpdate maxSurge=1 maxUnavailable=0: 1.25 -> 1.26" --overwrite
```

Снимки состояния:

```
[15:22:07] c7hzf Running | hmf57 Running | slhj7 Running                                  ← 3 старых пода (базовая линия)
[15:22:09] c7hzf Running | hmf57 Running | slhj7 Running | zxvdq ContainerCreating         ← 4-й под (surge), старые ещё не тронуты
[15:22:11] c7hzf Running | hmf57 Terminating | slhj7 Running | 2htsq Pending | zxvdq Running  ← только теперь начал уходить 1-й старый
[15:22:12] c7hzf Running | hmf57 Completed | slhj7 Running | 2htsq ContainerCreating | zxvdq Running
[15:22:14] c7hzf Terminating | slhj7 Running | 2htsq Running | 7zfj5 ContainerCreating | zxvdq Running   ← снова 4 пода, второй старый уходит
[15:22:16] slhj7 Terminating | 2htsq Running | 7zfj5 Running | zxvdq Running               ← последний старый под уходит
[15:22:17] 2htsq Running | 7zfj5 Running | zxvdq Running                                   ← 3 новых пода, готово
```

```bash
kubectl rollout status deployment/nginx-deploy --timeout=60s
```

```
deployment "nginx-deploy" successfully rolled out
```

**Наблюдение:** количество подов кратковременно росло до **4** (3 старых + 1 новый) прежде, чем начинал останавливаться хоть один старый под. Доступность никогда не опускалась ниже 3 (желаемого числа) — именно это гарантирует `maxUnavailable=0`. `maxSurge=1` разрешает ровно один "лишний" под сверху на время замены.

---

## Стратегия 3: `RollingUpdate` c `maxUnavailable=1, maxSurge=0`

Экономный вариант без лишних подов: сначала освобождается место (удаляется старый под), и только потом создаётся новый. Общее число подов никогда не превышает желаемое, но доступность временно падает.

### Настройка

```bash
kubectl patch deployment nginx-deploy -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":1,"maxSurge":0}}}}'
```

```
deployment.apps/nginx-deploy patched
```

```bash
kubectl get deployment nginx-deploy -o jsonpath='{.spec.strategy}'
```

```
{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}
```

### Ролаут под наблюдением (образ 1.26 → 1.27)

```bash
kubectl set image deployment/nginx-deploy nginx=nginx:1.27
kubectl annotate deployment/nginx-deploy kubernetes.io/change-cause="RollingUpdate maxSurge=0 maxUnavailable=1: 1.26 -> 1.27" --overwrite
```

Снимки состояния:

```
[15:22:41] 2htsq Running | 7zfj5 Running | zxvdq Running                                    ← 3 старых пода (базовая линия)
[15:22:43] 2htsq Running | 7zfj5 Terminating | zxvdq Running | j5sf8 ContainerCreating       ← сначала уходит старый, только потом создаётся новый
[15:22:44] 2htsq Running | zxvdq Running | j5sf8 ContainerCreating                           ← только 2 пода реально доступны — временное падение ёмкости
[15:22:45] 2htsq Running | zxvdq Terminating | j5sf8 Running | c9fjc ContainerCreating       ← новый под готов → можно убирать следующий старый
[15:22:47] 2htsq Terminating | c9fjc Running | j5sf8 Running | 8qm4h ContainerCreating       ← последний старый под уходит
[15:22:50] 8qm4h Running | c9fjc Running | j5sf8 Running                                     ← 3 новых пода, готово
```

```bash
kubectl rollout status deployment/nginx-deploy --timeout=60s
```

```
deployment "nginx-deploy" successfully rolled out
```

**Наблюдение:** общее число подов в любой момент **не превышало 3** (никакого surge) — новый под создавался только после того, как предыдущий старый действительно начал завершаться. При этом на короткое время (`[15:22:44]`) реально готовых (`Running`, 1/1) было **только 2 пода** — доступность временно снижена, зато не расходуются дополнительные ресурсы кластера сверх нормы.

---

## Проверка истории после всех экспериментов

```bash
kubectl rollout history deployment/nginx-deploy
```

```
deployment.apps/nginx-deploy
REVISION  CHANGE-CAUSE
5         update nginx 1.27 -> 1.28
7         Recreate strategy: 1.26 -> 1.25
8         RollingUpdate maxSurge=1 maxUnavailable=0: 1.25 -> 1.26
9         RollingUpdate maxSurge=0 maxUnavailable=1: 1.26 -> 1.27
```

```bash
kubectl get deployment nginx-deploy -o wide
```

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES       SELECTOR
nginx-deploy   3/3     3            3           18m   nginx        nginx:1.27   app=nginx-deploy
```

---

## Итоговое сравнение

| Стратегия | Простой (downtime) | Пиковое число подов | Мин. доступных подов | Когда применять |
|---|---|---|---|---|
| `Recreate` | Да, гарантирован | 3 (старые и новые не сосуществуют) | 0 | Приложения, которые не переносят одновременную работу двух версий (несовместимые схемы БД, эксклюзивные блокировки, лицензии на 1 инстанс) |
| `RollingUpdate` `maxSurge=1, maxUnavailable=0` | Нет | 4 (3 + 1 surge) | 3 (все) | Прод-нагрузка, где важна 100% доступность и есть запас ресурсов под лишний под |
| `RollingUpdate` `maxSurge=0, maxUnavailable=1` | Частичный (снижение ёмкости) | 3 (без surge) | 2 | Кластер с жёстким лимитом ресурсов/квот, где нельзя даже временно превышать число реплик |
| `RollingUpdate` `25%/25%` (default) | Частичный, но мягче | ~4 (при 3 репликах округление вверх) | ~2-3 | Разумный компромисс по умолчанию для большинства приложений |

**Выводы:**
1. `Recreate` — единственная стратегия, гарантирующая, что старая и новая версия **никогда не работают одновременно**, но ценой полного простоя на время замены.
2. `maxSurge` и `maxUnavailable` в `RollingUpdate` — это два независимых рычага: `maxSurge` определяет, насколько можно **превысить** желаемое число реплик, `maxUnavailable` — насколько можно **опуститься ниже** него.
3. `maxUnavailable=0` обеспечивает zero-downtime ролаут, но требует свободных ресурсов в кластере под лишние (surge) поды.
4. `maxSurge=0` экономит ресурсы (никогда не создаёт лишних подов), но платит за это временным снижением доступности/ёмкости во время ролаута.
5. Оба значения можно задавать как в абсолютных числах, так и в процентах (`"25%"`) — при дробном результате Kubernetes округляет по разным правилам для каждого параметра (`maxSurge` — вверх, `maxUnavailable` — вниз), что при default 25%/25% и 3 репликах даёт практически поведение как у наших ручных сценариев.
