# BcContainerHelper's New-BcContainer only waits 120 seconds for the Docker service to come up
# before throwing "Docker service is not yet ready." On windows-latest runners, Docker Desktop
# occasionally takes longer than that to finish starting, which fails the job even though Docker
# would have been fine a little later. Waiting here first, with a much longer timeout, avoids
# racing against that fixed internal limit.
Write-Host "Waiting for Docker to be ready"

$timeoutAt = (Get-Date).AddMinutes(10)
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
    throw "Docker did not become ready within 10 minutes."
}

Write-Host "Docker is ready"
