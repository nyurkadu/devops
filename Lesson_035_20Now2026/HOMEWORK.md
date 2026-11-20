# Домашнее задание 1 (GitOps): hellogo под управлением Argo CD

## Ситуация
подключили Argo CD к репозиторию : он менял файл в git, и через пару
минут менялся ваш кластер. Теперь источник правды — **ваш** репозиторий. Вы один раз описываете
приложение, а дальше не трогаете кластер руками: меняете файл, делаете push, и Argo CD сам приводит
кластер к тому, что записано в git. Откат — тоже коммит.

## Что понадобится

- minikube с Argo CD, установленным на занятии (команды — в [README](README.md) рядом). Argo CD
  стоит в namespace `argo-cd`, интерфейс — http://localhost:8080 через port-forward из README.
- Ваш репозиторий на GitHub. Пока **публичный**: приватные репозитории разберём на занятии.
- `kubectl` и `git`; для продвинутого задания — `helm`. Всё это уже стоит с прошлых занятий, а
  сама работа идёт в интерфейсе Argo CD.

После каждого шага есть **проверка**. Не переходите дальше, пока она не проходит.

## Базовое задание

Здесь нет ничего сверх того, что мы делали на занятии, — только репозиторий теперь ваш.

1. **Положите манифесты в свой репозиторий.** Создайте каталог `gitops/hellogo-app/` и в нём три
   файла: `deployment.yaml`, `service.yaml`, `secret.yaml`. За основу возьмите файлы из
   [`gitops/hellogo-app`](hellogo-app) этого репозитория. Образ — ваш `hellogo` из блока CI/CD
   или `ghcr.io/borisovcloud/devops2079/hellogo:latest`. Если ваш образ в ghcr приватный, под
   его не скачает (`ImagePullBackOff`) — тогда возьмите второй. В `secret.yaml` впишите в
   `username` своё имя. Закоммитьте и запушьте.

   > Строка в `secret.yaml` — учебная, это не настоящий секрет. Настоящие секреты в git в
   > открытом виде не кладут (вспомните SOPS из блока Helm); к секретам в GitOps мы ещё вернёмся.

   **Проверка:** файлы видны на GitHub по пути `gitops/hellogo-app/`.

2. **Создайте приложение в Argo CD.** Кнопка **+ NEW APP**:
   - **Application Name** `hellogo`, **Project Name** `default`;
   - **Sync Policy** `Automatic`, отметьте **Prune Resources** и **Self Heal**;
   - **Sync Options** — отметьте **Auto-Create Namespace**;
   - **Repository URL** — адрес вашего репозитория, **Revision** `HEAD`, **Path** `gitops/hellogo-app`;
   - **Cluster URL** `https://kubernetes.default.svc`, **Namespace** `hellogo`;
   - **CREATE**.

   **Проверка:** плитка `hellogo` — **Synced** и **Healthy**. Внутри видно дерево: Deployment,
   ReplicaSet, поды, Service, Secret.

3. **Откройте приложение в браузере.**
   ```bash
   kubectl -n hellogo port-forward service/hello-service 8081:80
   ```
   **Проверка:** http://localhost:8081 показывает приветствие с вашим именем (порт 8080 занят Argo CD).

4. **Измените приложение через git — и только через git.** В `deployment.yaml` поменяйте число
   реплик, в `secret.yaml` — имя. Закоммитьте оба изменения **одним коммитом**, запушьте и
   **засеките время**. `kubectl` не трогайте.

   **Проверка:** в интерфейсе появился новый коммит, число подов изменилось. Ждать придётся до
   трёх минут: Argo CD сам ходит в git по расписанию. Кнопка **REFRESH** заставляет его сходить
   прямо сейчас. Приветствие на странице само не поменяется: приложение читает переменную при
   старте пода. Единственное исключение из «`kubectl` не трогайте» — перезапуск подов:
   `kubectl -n hellogo rollout restart deployment/hello-deployment`. Манифест он не меняет, и
   Argo CD его не откатывает.

5. **Сломайте руками и посмотрите, что будет.**
   ```bash
   kubectl -n hellogo scale deployment/hello-deployment --replicas=5
   kubectl -n hellogo get deployment -w          # число реплик вернётся к тому, что в git; затем Ctrl+C
   kubectl -n hellogo delete deployment hello-deployment
   kubectl -n hellogo get deployment,pods        # Deployment снова на месте
   ```
   Теперь в интерфейсе откройте **DETAILS** приложения и выключите **Self Heal**. Удалите
   Deployment ещё раз.

   **Проверка:** без Self Heal Deployment не вернулся, приложение стало **OutOfSync**. Включите
   Self Heal обратно — всё восстановилось само.

6. **Удалите объект через git.** Добавьте в каталог `configmap.yaml`:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: hello-config
   data:
     note: "меня скоро удалят"
   ```
   Запушьте, дождитесь, пока ConfigMap появится в дереве. Затем удалите файл из репозитория и
   запушьте ещё раз.

   **Проверка:** ConfigMap исчез из кластера. За это отвечает **Prune Resources**.

7. **Откатитесь коммитом.**
   ```bash
   git log --oneline -5                 # найдите коммит из шага 4
   git revert <sha> --no-edit && git push
   ```
   **Проверка:** число реплик вернулось к прежнему, как только Argo CD увидел коммит; имя на
   странице — после того же `rollout restart`, что в шаге 4. Откройте **HISTORY AND ROLLBACK** —
   там по строке на каждую синхронизацию.

## Продвинутое задание (по желанию)

8. **Приложение Argo CD — тоже файл.** Посмотрите, что вы создали через форму:
   ```bash
   kubectl -n argo-cd get application hellogo -o yaml
   ```
   Запишите то же самое в `gitops/argocd/hellogo.yaml` (каталог `argocd/` не входит в `Path`
   приложения, поэтому сам Argo CD его не применяет):
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: hellogo
     namespace: argo-cd              # Application живёт рядом с Argo CD, а не рядом с приложением
   spec:
     project: default
     source:                         # где правда
       repoURL: https://github.com/<вы>/<репозиторий>.git
       targetRevision: HEAD
       path: gitops/hellogo-app
     destination:                    # куда
       server: https://kubernetes.default.svc
       namespace: hellogo
     syncPolicy:                     # кто применяет и что делать с ручными правками
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```
   Удалите приложение в интерфейсе (**DELETE**), дождитесь, пока плитка исчезнет, и создайте его
   заново из файла: `kubectl apply -f gitops/argocd/hellogo.yaml`.

   **Проверка:** плитка `hellogo` снова **Synced** и **Healthy**, хотя форму вы не открывали.

9. **То же приложение — Helm-чартом.** Сделайте чарт `gitops/hellogo-chart/` с теми же тремя
   объектами. В `values.yaml` вынесите число реплик, имя для приветствия и порт сервиса.
   Рядом с `values.yaml` положите `values-dev.yaml` (одна реплика). Создайте приложение
   `hellogo-dev`: скопируйте файл из шага 8 в `gitops/argocd/hellogo-dev.yaml`, поменяйте имя,
   `path: gitops/hellogo-chart`, namespace `hellogo-dev` и добавьте в `source`:
   ```yaml
       helm:
         valueFiles:
           - values-dev.yaml         # путь считается от каталога чарта
   ```
   Запушьте чарт и примените файл: `kubectl apply -f gitops/argocd/hellogo-dev.yaml`.

   **Проверка:** `hellogo-dev` — **Synced** и **Healthy**; `helm list -A` его **не** показывает.

10. **Две среды из одного чарта.** Добавьте `values-prod.yaml` (три реплики, другое имя) и второе
    приложение `hellogo-prod` в namespace `hellogo-prod`: файл `gitops/argocd/hellogo-prod.yaml`,
    в нём `values-prod.yaml`. Запушьте и примените его через `kubectl apply -f`.

    **Проверка:** в интерфейсе два приложения из одного чарта: в dev один под, в prod три.

## Что сдать

1. Ссылку на репозиторий.
2. Два скриншота: дерево приложения в Argo CD (Synced, Healthy) и страницу с вашим приветствием.
3. Короткие ответы:
   - Сколько вы ждали на шаге 4 и почему? Что делает REFRESH?
   - Что произошло с `kubectl scale` на шаге 5 при включённом Self Heal и что — при выключенном?
   - Чем `git revert` на шаге 7 отличается от кнопки Rollback в интерфейсе? (На занятии вы
     видели: перед откатом она выключает Auto-Sync.) Какая из двух историй — в git или в
     Argo CD — отвечает на вопрос «кто и зачем это поменял»?
   - (продвинутое) Почему `helm list -A` не показывает `hellogo-dev`, хотя чарт установлен?

## Уборка

Стенд локальный, удалять не обязательно. Начисто: удалите приложения в интерфейсе (**DELETE**),
затем `kubectl delete namespace hellogo hellogo-dev hellogo-prod --ignore-not-found` —
namespace, созданный Argo CD, переживает удаление приложения.

**Документация:** [Automated sync policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/) ·
[Application specification](https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/) ·
[Helm as a source](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)