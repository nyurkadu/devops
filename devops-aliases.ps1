# =====================================================================
#  DevOps aliases  --  CloudLessons
#  File: C:\Users\avila\devops\CloudLessons\devops-aliases.ps1
#
#  Dot-sourced from $PROFILE, so every function below is available
#  in ANY folder (CloudLessons and all sub-folders included).
#
#  Type  aliase          to print the full list
#  Type  aliase docker   to filter the list
# =====================================================================

$global:DevOpsAliasFile = $PSCommandPath

# ---------------------------------------------------------------- DOCKER
function global:d          { docker @args }
function global:ds         { docker ps     --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' }
function global:dsa        { docker ps -a  --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' }
function global:di         { docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' }
function global:dl         { docker logs -f --tail 100 @args }
function global:dex        { param([Parameter(Mandatory)][string]$Container, [string]$Shell = 'sh') docker exec -it $Container $Shell }
function global:dstart     { docker start @args }
function global:dst        { docker stop  @args }
function global:drestart   { docker restart @args }
function global:drm        { docker rm -f @args }
function global:drmi       { docker rmi @args }
function global:dins       { docker inspect @args }
function global:dip        { param([Parameter(Mandatory)][string]$Container) docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $Container }
function global:dstats     { docker stats --no-stream }
function global:dnet       { docker network ls }
function global:dvol       { docker volume ls }
function global:dbuild     { docker build @args }
function global:drun       { docker run -it --rm @args }
function global:dpull      { docker pull @args }
function global:dpush      { docker push @args }
function global:dstopall   { docker ps -q | ForEach-Object { docker stop $_ } }
function global:drmall     { docker ps -aq | ForEach-Object { docker rm -f $_ } }
function global:dprune     { docker system prune -f }
function global:dprunea    { docker system prune -a --volumes -f }

# ------------------------------------------------------- DOCKER COMPOSE
function global:dc         { docker compose @args }
function global:dcu        { docker compose up -d @args }
function global:dcd        { docker compose down @args }
function global:dcl        { docker compose logs -f --tail 100 @args }
function global:dcps       { docker compose ps }
function global:dcb        { docker compose build @args }

# ------------------------------------------------------------ KUBERNETES
function global:ks         { kubectl @args }
function global:kg         { kubectl get @args }
function global:kgp        { kubectl get pods -o wide @args }
function global:kgs        { kubectl get svc @args }
function global:kgd        { kubectl get deploy @args }
function global:kgn        { kubectl get nodes -o wide @args }
function global:kga        { kubectl get all -A @args }
function global:kd         { kubectl describe @args }
function global:kl         { kubectl logs -f --tail 100 @args }
function global:kex        { param([Parameter(Mandatory)][string]$Pod, [string]$Shell = 'sh') kubectl exec -it $Pod -- $Shell }
function global:kaf        { kubectl apply -f @args }
function global:kdf        { kubectl delete -f @args }
function global:kdel       { kubectl delete @args }
function global:kctx       { if ($args) { kubectl config use-context @args } else { kubectl config get-contexts } }
function global:kns        { if ($args) { kubectl config set-context --current --namespace=$args[0] } else { kubectl get ns } }
function global:kcur       { kubectl config current-context }
function global:ktop       { kubectl top pods @args }

# -------------------------------------------------------------- MINIKUBE
function global:mk         { minikube @args }
function global:mkst       { minikube status }
function global:mkup       { minikube start @args }
function global:mkdown     { minikube stop }
function global:mkenv      { & minikube -p minikube docker-env --shell powershell | Invoke-Expression }

# ------------------------------------------------------------------- GIT
function global:gs         { git status -sb }
function global:glo        { git log --oneline --graph --decorate -20 }
function global:ga         { git add @args }
function global:gaa        { git add -A }
function global:gcom       { git commit -m @args }
function global:gpu        { git push @args }
function global:gpl        { git pull @args }
function global:gd         { git diff @args }
function global:gco        { git checkout @args }
function global:gb         { git branch @args }

# ------------------------------------------------------------ UNIX TOOLS
# grep is not a Windows command. Git for Windows ships a real GNU grep,
# so we call it directly; if Git is missing we fall back to Select-String.
$global:GitGrep = 'C:\Program Files\Git\usr\bin\grep.exe'
function global:grep {
    if (Test-Path $global:GitGrep) { $input | & $global:GitGrep @args }
    else                            { $input | Select-String @args }
}

# ------------------------------------------------------------ NAV / MISC
function global:cdl        { Set-Location 'C:\Users\avila\devops\CloudLessons' }
function global:reload {
    # Re-read the alias file itself: works in every host, including the
    # VS Code PowerShell extension where $PROFILE points to a missing file.
    . $global:DevOpsAliasFile
    if (Test-Path $PROFILE) { . $PROFILE }
    Write-Host "Aliases reloaded from $global:DevOpsAliasFile" -ForegroundColor Green
}
function global:eal        { code $global:DevOpsAliasFile }

# =====================================================================
#  The catalogue printed by  aliase
# =====================================================================
$global:DevOpsAliasList = @(
    @{ G='DOCKER';         N='d <args>';        D='docker <...>  - generic wrapper' }
    @{ G='DOCKER';         N='ds';              D='running containers (id / name / image / status / ports)' }
    @{ G='DOCKER';         N='dsa';             D='ALL containers, stopped ones included' }
    @{ G='DOCKER';         N='di';              D='local images (repo / tag / id / size)' }
    @{ G='DOCKER';         N='dl <c>';          D='follow container logs (last 100 lines)' }
    @{ G='DOCKER';         N='dex <c> [sh]';    D='shell inside container, default sh (dex web bash)' }
    @{ G='DOCKER';         N='dstart <c>';      D='start container' }
    @{ G='DOCKER';         N='dst <c>';         D='stop container' }
    @{ G='DOCKER';         N='drestart <c>';    D='restart container' }
    @{ G='DOCKER';         N='drm <c>';         D='remove container (force)' }
    @{ G='DOCKER';         N='drmi <img>';      D='remove image' }
    @{ G='DOCKER';         N='dins <c>';        D='docker inspect' }
    @{ G='DOCKER';         N='dip <c>';         D='container IP address' }
    @{ G='DOCKER';         N='dstats';          D='CPU / RAM per container (single snapshot)' }
    @{ G='DOCKER';         N='dnet';            D='network list' }
    @{ G='DOCKER';         N='dvol';            D='volume list' }
    @{ G='DOCKER';         N='dbuild <args>';   D='docker build   (dbuild -t app:1.0 .)' }
    @{ G='DOCKER';         N='drun <img>';      D='docker run -it --rm <image>' }
    @{ G='DOCKER';         N='dpull / dpush';   D='pull / push image' }
    @{ G='DOCKER';         N='dstopall';        D='stop every running container' }
    @{ G='DOCKER';         N='drmall';          D='remove every container (force)' }
    @{ G='DOCKER';         N='dprune';          D='clean dangling data' }
    @{ G='DOCKER';         N='dprunea';         D='deep clean: images + volumes (careful!)' }

    @{ G='DOCKER COMPOSE'; N='dc <args>';       D='docker compose <...>' }
    @{ G='DOCKER COMPOSE'; N='dcu';             D='compose up -d' }
    @{ G='DOCKER COMPOSE'; N='dcd';             D='compose down' }
    @{ G='DOCKER COMPOSE'; N='dcl';             D='compose logs -f' }
    @{ G='DOCKER COMPOSE'; N='dcps';            D='compose ps' }
    @{ G='DOCKER COMPOSE'; N='dcb';             D='compose build' }

    @{ G='KUBERNETES';     N='ks <args>';       D='kubectl <...>  - takes any parameters' }
    @{ G='KUBERNETES';     N='kg <args>';       D='kubectl get <...>' }
    @{ G='KUBERNETES';     N='kgp';             D='get pods -o wide' }
    @{ G='KUBERNETES';     N='kgs';             D='get svc' }
    @{ G='KUBERNETES';     N='kgd';             D='get deploy' }
    @{ G='KUBERNETES';     N='kgn';             D='get nodes -o wide' }
    @{ G='KUBERNETES';     N='kga';             D='get all -A' }
    @{ G='KUBERNETES';     N='kd <res> <n>';    D='kubectl describe' }
    @{ G='KUBERNETES';     N='kl <pod>';        D='follow pod logs' }
    @{ G='KUBERNETES';     N='kex <pod> [sh]';  D='shell inside pod' }
    @{ G='KUBERNETES';     N='kaf <file>';      D='apply -f' }
    @{ G='KUBERNETES';     N='kdf <file>';      D='delete -f' }
    @{ G='KUBERNETES';     N='kdel <args>';     D='kubectl delete' }
    @{ G='KUBERNETES';     N='kctx [name]';     D='no arg: list contexts / with arg: switch' }
    @{ G='KUBERNETES';     N='kns [name]';      D='no arg: list namespaces / with arg: set default' }
    @{ G='KUBERNETES';     N='kcur';            D='current context' }
    @{ G='KUBERNETES';     N='ktop';            D='kubectl top pods' }

    @{ G='MINIKUBE';       N='mk <args>';       D='minikube <...>' }
    @{ G='MINIKUBE';       N='mkst';            D='minikube status' }
    @{ G='MINIKUBE';       N='mkup';            D='minikube start' }
    @{ G='MINIKUBE';       N='mkdown';          D='minikube stop' }
    @{ G='MINIKUBE';       N='mkenv';           D='point local docker CLI at the minikube daemon' }

    @{ G='GIT';            N='gs';              D='git status -sb' }
    @{ G='GIT';            N='glo';             D='git log --oneline --graph -20' }
    @{ G='GIT';            N='ga / gaa';        D='git add <...>  /  git add -A' }
    @{ G='GIT';            N='gcom "msg"';      D='git commit -m' }
    @{ G='GIT';            N='gpu / gpl';       D='git push / git pull' }
    @{ G='GIT';            N='gd';              D='git diff' }
    @{ G='GIT';            N='gco <br>';        D='git checkout' }
    @{ G='GIT';            N='gb';              D='git branch' }

    @{ G='MISC';           N='grep <pattern>';  D='GNU grep from Git for Windows (kubectl get crd | grep gateway)' }
    @{ G='MISC';           N='cdl';             D='cd to CloudLessons root' }
    @{ G='MISC';           N='aliase [filter]'; D='this list (aliase docker / aliase kub)' }
    @{ G='MISC';           N='eal';             D='open this file in VS Code' }
    @{ G='MISC';           N='reload';          D='re-read the profile without restarting the shell' }
)

function global:aliase {
    param([string]$Filter)

    $items = $global:DevOpsAliasList
    if ($Filter) {
        $items = @($items | Where-Object {
            $_.G -like "*$Filter*" -or $_.N -like "*$Filter*" -or $_.D -like "*$Filter*"
        })
        if ($items.Count -eq 0) {
            Write-Host "  nothing matches '$Filter'" -ForegroundColor Yellow
            return
        }
    }

    $w = ($items | ForEach-Object { $_.N.Length } | Measure-Object -Maximum).Maximum

    Write-Host ''
    Write-Host '  DevOps aliases' -ForegroundColor White -NoNewline
    Write-Host "   ($global:DevOpsAliasFile)" -ForegroundColor DarkGray

    $last = ''
    foreach ($i in $items) {
        if ($i.G -ne $last) {
            Write-Host ''
            Write-Host ('  ' + $i.G) -ForegroundColor Cyan
            Write-Host ('  ' + ('-' * $i.G.Length)) -ForegroundColor DarkCyan
            $last = $i.G
        }
        Write-Host ('  ' + $i.N.PadRight($w)) -ForegroundColor Green -NoNewline
        Write-Host ('   ' + $i.D) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '  aliase <filter> = search   |   eal = edit file   |   reload = re-read profile' -ForegroundColor DarkGray
    Write-Host ''
}

Set-Alias -Scope Global aliases aliase
Set-Alias -Scope Global al      aliase
