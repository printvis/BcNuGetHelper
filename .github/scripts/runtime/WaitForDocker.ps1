# BcContainerHelper's New-BcContainer only waits 120 seconds for the Docker service to come up
# before throwing "Docker service is not yet ready." On windows-latest runners, Docker Desktop
# occasionally takes longer than that to finish starting, which fails the job even though Docker
# would have been fine a little later. Waiting here first, with a much longer timeout, avoids
# racing against that fixed internal limit.
#
# The timeout (in minutes) can be overridden via the DOCKER_WAIT repository variable. If it is
# empty, missing, or not a valid positive integer, it falls back to 10 minutes.
$defaultDockerWaitMinutes = 10
$dockerWaitMinutes = $defaultDockerWaitMinutes
$rawDockerWait = "$env:DOCKER_WAIT".Trim()
if ($rawDockerWait -ne '') {
    $parsedMinutes = 0
    if ([int]::TryParse($rawDockerWait, [ref] $parsedMinutes) -and $parsedMinutes -gt 0) {
        $dockerWaitMinutes = $parsedMinutes
    }
    else {
        Write-Host "DOCKER_WAIT value '$rawDockerWait' is not a valid positive integer, using default of $defaultDockerWaitMinutes minutes"
    }
}

Write-Host "Waiting for Docker to be ready (timeout: $dockerWaitMinutes minute(s))"

$timeoutAt = (Get-Date).AddMinutes($dockerWaitMinutes)
$dockerReady = $false
while ((Get-Date) -lt $timeoutAt) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        $dockerReady = $true
        break
    }
    Write-Host "Docker is not ready yet, waiting..."
    Start-Sleep -Seconds 5
}

if (-not $dockerReady) {
    throw "Docker did not become ready within $dockerWaitMinutes minute(s)."
}

Write-Host "Docker is ready"
