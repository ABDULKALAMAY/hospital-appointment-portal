param(
    [ValidateSet('Deploy','Verify','Rollback')][string]$Action,
    [string]$Image='', [string]$Release=''
)
$ErrorActionPreference='Stop'
$statePath=Join-Path $PSScriptRoot '.release-state.json'
function Kube {
    $arguments=$args
    $saved=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try { $out=& kubectl @arguments 2>&1; $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$saved }
    $text=($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "kubectl $($arguments -join ' ') failed:`n$text" }
    return $text
}
function Check-Service($expected) {
    $exe=(Get-Command kubectl).Source
    $forward=Start-Process -FilePath $exe -ArgumentList @('port-forward','service/hospital-service','18064:80','--address=127.0.0.1') -WindowStyle Hidden -PassThru -RedirectStandardOutput '.release-forward.out' -RedirectStandardError '.release-forward.err'
    try {
        $page=$null
        for($i=0;$i -lt 25;$i++) {
            try { $page=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18064/' -TimeoutSec 2; break }
            catch { Start-Sleep -Seconds 1 }
        }
        if(!$page -or $page.StatusCode -ne 200 -or !$page.Content.Contains('CareConnect')) { throw 'Live application HTTP check failed.' }
        $version=(Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18064/release.txt').Content.Trim()
        $health=(Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:18064/health.html').Content.Trim()
        if($expected -and $version -ne $expected) { throw "Expected $expected; received $version" }
        if($health -ne 'OK') { throw 'Live application is unhealthy.' }
        Write-Host "PASS: live hospital Service HTTP 200; release=$version; health=$health"
    } finally { if(!$forward.HasExited) { Stop-Process -Id $forward.Id -Force } }
}
if($Action -eq 'Deploy') {
    $old=Kube get deployment hospital-portal --ignore-not-found=true -o json
    $revision=''; $previousImage=''
    if($old.Trim()) {
        $d=$old | ConvertFrom-Json
        if($d.status.readyReplicas -ne 3) { throw 'Existing stable release must have 3 ready Pods.' }
        $revision=$d.metadata.annotations.'deployment.kubernetes.io/revision'
        $previousImage=$d.spec.template.spec.containers[0].image
    }
    @{PreviousRevision=$revision;PreviousImage=$previousImage;Release=$Release;Image=$Image} | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
    (Get-Content "$PSScriptRoot/deployment.yaml" -Raw).Replace('IMAGE_PLACEHOLDER',$Image) | Set-Content '.release-deployment.yaml' -Encoding UTF8
    Write-Host "DEPLOYING $Image; previous stable image=$previousImage"
    Write-Host (Kube apply -f '.release-deployment.yaml')
    Write-Host (Kube rollout status deployment/hospital-portal --timeout=90s)
    exit 0
}
if(!(Test-Path $statePath)) { Write-Host 'No deployment attempted; no rollback required.'; exit 0 }
$state=Get-Content $statePath -Raw | ConvertFrom-Json
if($Action -eq 'Rollback') {
    Write-Host 'FAILED RELEASE DIAGNOSTICS'
    Write-Host (Kube get pods -l app=hospital-portal -o wide)
    Write-Host (Kube get events --field-selector type=Warning --sort-by=.lastTimestamp)
    if(!$state.PreviousRevision) { throw 'No previous stable revision is available.' }
    Write-Host (Kube rollout undo deployment/hospital-portal "--to-revision=$($state.PreviousRevision)")
    Write-Host (Kube rollout status deployment/hospital-portal --timeout=120s)
    $expected=($state.PreviousImage -split ':')[-1]
    Check-Service $expected
    Write-Host "ROLLBACK SUCCESS: restored $($state.PreviousImage)"
} else {
    $pods=((Kube get pods -l app=hospital-portal -o json) | ConvertFrom-Json).items
    $ready=@($pods | Where-Object { !$_.metadata.deletionTimestamp -and $_.status.phase -eq 'Running' -and @($_.status.containerStatuses | Where-Object { !$_.ready }).Count -eq 0 })
    if($ready.Count -ne 3) { throw "Expected 3 ready Pods; found $($ready.Count)" }
    foreach($pod in $ready) {
        $name=$pod.metadata.name
        $page=Kube exec $name '--' wget -qO- http://127.0.0.1/
        foreach($text in @('CareConnect','Doctor Profiles','Appointment Slots')) { if(!$page.Contains($text)) { throw "Missing content: $text" } }
        if((Kube exec $name '--' wget -qO- http://127.0.0.1/release.txt).Trim() -ne $state.Release) { throw "Wrong release on $name" }
        if((Kube exec $name '--' wget -qO- http://127.0.0.1/health.html).Trim() -ne 'OK') { throw "Health failed on $name" }
        Write-Host "PASS: $name; HTTP, hospital content, release and health"
    }
    Check-Service $state.Release
}
Write-Host (Kube get deployment hospital-portal)
Write-Host (Kube get pods -l app=hospital-portal)
Write-Host (Kube get service hospital-service -o wide)
