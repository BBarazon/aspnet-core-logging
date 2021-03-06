# Runs a Docker container hosting the database to be targeted by the integration tests and periodically 
# checks for a given amount of tries whether the database is ready to accept incoming connections by
# searching a particulart text fragment inside the container log files

Param (
    # Represents the name of the Docker image to use for provisioning the database 
    # to be targeted by the integration tests.
    $DockerImageName,

    # Represents the tag associated with the Docker image to use for provisioning the database 
    # to be targeted by the integration tests.
    $DockerImageTag,

    # Represents the name of the Docker container to check whether is running.
    $ContainerName,

    # Represents the mapping between the Docker host port and container port used for exposing 
    # the service running inside the container to the outside world.
    # Supported values: 
    #   - host_port:container_port/network_protocol, e.g. 1234:9876/tcp, which means the host port is static
    #   - host_port:container_port, e.g. 1234:9876, which means the host port is static
    #   - container_port/network_protocol, e.g. 9876/tcp, which means the host port will be dynamically allocated
    #   - container_port, e.g. 9876, which means the host port will be dynamically allocated
    $PortMapping,

    # Represents the name of the build variable to store the Docker host port mapped to the container port.
    $DockerHostPortBuildVariableName,

    # Represents the environment variables used when running the Docker container.
    # Example: -e "key1=value1" -e "key2=value2".
    $ContainerEnvironmentVariables,

    # Represents the string which occurs inside the container log signaling that 
    # the database is ready to accept incoming connections.
    $ContainerLogPatternForDatabaseReady,

    # Represents the number of milliseconds to wait before checking again whether 
    # the given container is running.
    $SleepingTimeInMillis = 250,

    # The maximum amount of retries before giving up and considering that the given 
    # Docker container is not running.
    $MaxNumberOfTries = 120
)

$ErrorActionPreference = 'Continue'

Write-Output "Pulling Docker image ${DockerImageName}:${DockerImageTag} ..."
# Success stream is redirected to null to ensure the output of the Docker command below is not printed to console
docker image pull ${DockerImageName}:${DockerImageTag} 1>$null
Write-Output "Docker image ${DockerImageName}:${DockerImageTag} has been pulled`n"

Write-Output "Starting Docker container '$ContainerName' ..."
Invoke-Expression -Command "docker container run --name $ContainerName --detach --publish ${PortMapping} $ContainerEnvironmentVariables ${DockerImageName}:${DockerImageTag}" 1>$null
Write-Output "Docker container '$ContainerName' has been started"

$numberOfTries = 0
$isDatabaseReady = $false

do {
    Start-Sleep -Milliseconds $sleepingTimeInMillis

    # Redirect error stream to success one and set $ErrorActionPreference = 'Continue' to ensure "docker logs" command does not trick Azure DevOps into
    # thinking that this script has failed; this avoids the error: "##[error]PowerShell wrote one or more lines to the standard error stream." which
    # is reported by Azure DevOps even if the database has reached its ready state.
    $isDatabaseReady = docker logs --tail 50 $ContainerName 2>&1 | Select-String -Pattern $ContainerLogPatternForDatabaseReady -SimpleMatch -Quiet

    if ($isDatabaseReady -eq $true) {
        Write-Output "`n`nDatabase running inside container ""$ContainerName"" is ready to accept incoming connections"
        $dockerContainerPort = $PortMapping

        if ($PortMapping -like '*:*') {
            $dockerContainerPort = $PortMapping -split ':' | Select-Object -Skip 1
        }
        
        $dockerHostPort = docker port $ContainerName $dockerContainerPort
        $dockerHostPort = $dockerHostPort -split ':' | Select-Object -Skip 1
        Write-Output "##vso[task.setvariable variable=$DockerHostPortBuildVariableName]$dockerHostPort"
        exit 0
    }

    $progressMessage = "`n${numberOfTries}: Container ""$ContainerName"" isn't running yet"

    if ($numberOfTries -lt $maxNumberOfTries - 1) {
        $progressMessage += "; will check again in $sleepingTimeInMillis milliseconds"
    }
        
    Write-Output $progressMessage
    $numberOfTries++
}
until ($numberOfTries -eq $maxNumberOfTries)

# Instruct Azure DevOps to consider the current task as failed.
# See more about logging commands here: https://github.com/microsoft/azure-pipelines-tasks/blob/master/docs/authoring/commands.md.
Write-Output "##vso[task.LogIssue type=error;]Container $ContainerName is still not running after checking for $numberOfTries times; will stop here"
Write-Output "##vso[task.complete result=Failed;]"
exit 1