# ⭐ Задание со звёздочкой: свой Go-приложение из GHCR в Minikube

Цель: взять готовый Docker-образ своего Go-приложения, собранный и опубликованный в GitHub Container Registry (GHCR) через GitHub Actions, запустить его в Minikube, пробросить порт, открыть страницу в браузере и зайти внутрь Pod'а через `kubectl exec`.

Пошаговая инструкция ниже написана так, чтобы её можно было повторить самостоятельно с нуля.

---

## Шаг 0. Откуда взялся образ

Приложение и workflow лежат в отдельном репозитории `nyurkadu/nyurkadu` (в этом воркспейсе — папка `Lesson_012_24Jul2026/LessonFiles/ClassWork/nyurkadu`). Из него важны три файла:

**`main.go`** — простой HTTP-сервер на Go, который на любой запрос отвечает текущим временем:
```go
func handler(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	fmt.Fprintf(w, "Ваше текущее время: %s\n", now.Format("2006-01-02 15:04:05"))
	fmt.Fprintf(w, "UTC: %s\n", now.UTC().Format("2006-01-02 15:04:05"))
}

func main() {
	http.HandleFunc("/", handler)
	log.Println("Server listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```
Слушает порт **8080** внутри контейнера.

**`Dockerfile`** — multi-stage сборка (компиляция в `golang:1.22-alpine`, запуск в лёгком `alpine:latest`):
```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY main.go .
RUN go build -o hello main.go

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/hello .
EXPOSE 8080
CMD ["./hello"]
```

**`.github/workflows/docker-publish.yml`** — GitHub Actions workflow, который при пуше в `master` собирает образ и пушит его в GHCR:
```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}
...
      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push multi-platform image
        uses: docker/build-push-action@v7
        with:
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
```

> Комментарий: `IMAGE_NAME: ${{ github.repository }}` — это переменная GitHub Actions, которая автоматически подставляет `owner/repo` текущего репозитория (здесь — `nyurkadu/nyurkadu`). Поэтому итоговый образ называется `ghcr.io/nyurkadu/nyurkadu`. Тег `master` берётся из `docker/metadata-action`, который по умолчанию тегирует образ именем ветки, из которой собран пуш.

**Как найти имя образа в своём проекте**: посмотреть на `env.REGISTRY` + `env.IMAGE_NAME` в workflow-файле — обычно это `ghcr.io/<github-username>/<repo-name>`. Тег смотрите на вкладке репозитория **Packages** (`https://github.com/<user>/<repo>/pkgs/container/<repo>`) — там же видно, публичный образ или приватный.

---

## Шаг 1. Проверить, что образ доступен

```bash
docker pull ghcr.io/nyurkadu/nyurkadu:master
```

Вывод:
```
master: Pulling from nyurkadu/nyurkadu
7b70804d43f0: Download complete
Digest: sha256:5e57ce49729c39a878773e0e50bcbf00230e7a12922f9464009991732a6a8f66
Status: Downloaded newer image for ghcr.io/nyurkadu/nyurkadu:master
ghcr.io/nyurkadu/nyurkadu:master
```

> Комментарий: этот шаг **не обязателен** для развёртывания в Minikube — kubelet внутри кластера сам умеет тянуть образ напрямую из реестра по имени, указанному в манифесте Pod'а. Но он полезен, чтобы заранее убедиться, что образ существует, публичный (не требует `imagePullSecrets`) и корректно называется — до того, как разбираться, почему Pod не стартует.
>
> Если бы пакет был приватным, понадобился бы `kubectl create secret docker-registry` с GitHub Personal Access Token (scope `read:packages`) и ссылка на этот secret в Pod'е через `imagePullSecrets`.

---

## Шаг 2. Манифест Pod'а

Файл `goapp-pod.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: goapp
  labels:
    app: goapp
spec:
  containers:
  - name: goapp
    image: ghcr.io/nyurkadu/nyurkadu:master
    ports:
    - containerPort: 8080
```

> Комментарий: `containerPort: 8080` — это не проброс порта наружу, а просто документирование того, какой порт слушает приложение внутри контейнера (соответствует `EXPOSE 8080` в Dockerfile и `ListenAndServe(":8080")` в коде). Реальный доступ снаружи кластера всё равно организуется через `kubectl port-forward` или `Service` — сам по себе `containerPort` доступ не открывает.

---

## Шаг 3. Запустить Pod

```bash
kubectl apply -f goapp-pod.yaml
```

Вывод:
```
pod/goapp created
```

Проверка статуса:

```bash
kubectl get pod goapp -o wide
```

Вывод:
```
NAME    READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
goapp   1/1     Running   0          59s   10.244.0.13   minikube   <none>           <none>
```

События (`kubectl describe pod goapp`, раздел Events):
```
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  19s   default-scheduler  Successfully assigned default/goapp to minikube
  Normal  Pulling    18s   kubelet            Pulling image "ghcr.io/nyurkadu/nyurkadu:master"
  Normal  Pulled     14s   kubelet            Successfully pulled image "ghcr.io/nyurkadu/nyurkadu:master" in 3.77s
  Normal  Created    14s   kubelet            Container created
  Normal  Started    14s   kubelet            Container started
```

> Комментарий: обратите внимание на событие `Pulling` — это подтверждение того, что kubelet внутри Minikube сам обратился к `ghcr.io` и скачал образ, без участия локального Docker Desktop. Именно поэтому шаг 1 (`docker pull` на хосте) был не обязателен.

Проверка логов приложения:

```bash
kubectl logs goapp
```

Вывод:
```
2026/08/12 15:28:24 Server listening on :8080
```

---

## Шаг 4. Пробросить порт и открыть в браузере

По умолчанию Pod недоступен снаружи кластера — нужен `kubectl port-forward`, чтобы прокинуть локальный порт машины на порт 8080 внутри Pod'а.

```bash
kubectl port-forward pod/goapp 8889:8080
```

> Комментарий: формат `<локальный-порт>:<порт-в-Pod'е>`. Порт 8889 выбран, чтобы не конфликтовать с уже запущенным ранее пробросом для nginx (`8888`) и с портом 8080, который на этой машине оказался занят другим процессом Windows. При повторении у себя можно смело использовать `8080:8080`, если порт свободен.
>
> Команда **блокирующая** — она держит терминал открытым, пока проброс активен (останавливается через Ctrl+C). Если нужно, чтобы проброс продолжал работать в фоне после закрытия терминала — запускайте её как фоновый/detached-процесс (например, через `nohup ... &` в Linux/macOS или `Start-Process` в PowerShell на Windows).

Проверка, что проброс работает:

```bash
curl http://localhost:8889
```

Вывод:
```
Ваше текущее время: 2026-08-12 15:29:02
UTC: 2026-08-12 15:29:02
```

Открытие в браузере — просто перейдите по адресу:
```
http://localhost:8889
```

В браузере отобразится тот же текст с текущим временем сервера (в двух часовых поясах).

---

## Шаг 5. Зайти внутрь Pod'а через `kubectl exec`

Целевая команда (интерактивная сессия, выполняется в обычном терминале):
```bash
kubectl exec -it goapp -- /bin/sh
```

Внутри контейнера можно, например, проверить:
```sh
hostname                      # goapp
whoami                        # root
cat /etc/os-release            # Alpine Linux 3.24.1
ls -la /app                    # бинарник hello — единственный файл в образе
wget -qO- http://localhost:8080   # curl внутри контейнера, т.к. curl не установлен в alpine по умолчанию
```

Фактический вывод (команда выполнялась неинтерактивно, `kubectl exec goapp -- /bin/sh -c "..."`, т.к. окружению нужен настоящий TTY для `-it`):
```
goapp
root
NAME="Alpine Linux"
ID=alpine
VERSION_ID=3.24.1
total 6852
drwxr-xr-x    1 root     root          4096 Jul 24 11:08 .
drwxr-xr-x    1 root     root          4096 Aug 12 15:28 ..
-rwxr-xr-x    1 root     root       7004211 Jul 24 11:08 hello
Ваше текущее время: 2026-08-12 15:29:13
UTC: 2026-08-12 15:29:13
```

> Комментарий: образ собран на базе `alpine:latest` — в нём нет `bash` (только `/bin/sh`) и нет `curl` (используется `wget` из busybox). Это типично для минимальных production-образов — меньше размер, меньше поверхность атаки. Если внутри контейнера нужен полноценный `bash`/`curl` для отладки — их пришлось бы добавлять в Dockerfile (`RUN apk add --no-cache curl bash`), но для боевого образа это обычно не нужно.

---

## Итог: как повторить с нуля (шпаргалка)

1. Найти имя своего образа: `ghcr.io/<user>/<repo>:<tag>` — из `.github/workflows/*.yml` (поля `REGISTRY`/`IMAGE_NAME`) или со страницы `github.com/<user>/<repo>/pkgs/container/<repo>`.
2. (Опционально) `docker pull ghcr.io/<user>/<repo>:<tag>` — убедиться, что образ существует и публичный.
3. Написать `Pod`-манифест с этим `image:` и портом приложения в `containerPort`.
4. `kubectl apply -f <файл>.yaml` → `kubectl get pod <имя> -o wide` → `kubectl logs <имя>` — убедиться, что Pod поднялся и приложение стартовало.
5. `kubectl port-forward pod/<имя> <локальный-порт>:<порт-в-контейнере>` → открыть `http://localhost:<локальный-порт>` в браузере.
6. `kubectl exec -it <имя> -- /bin/sh` (или `-- bash`, если он есть в образе) — зайти внутрь и посмотреть файловую систему, окружение, проверить, что процесс слушает нужный порт.
