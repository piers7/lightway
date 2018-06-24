[CmdLetBinding()]
param(
    $serverInstance = "(localdb)\MSSQLLocalDB",
    $toVersion
)

$projectFolders = @(
    "$psScriptRoot\SampleSSDTProject"
)

try{
    foreach($projectDir in $projectFolders){
        $projectPath = Get-ChildItem -Path:$projectDir *.sqlproj | Select-Object -First:1 -ExpandProperty:FullName
        $migrationsDir = Join-Path $projectDir "migrations"
        $projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath)
        $databaseName = "Lightway_$projectName"

        Write-Host "Deploy database $databaseName"
        & $psScriptRoot\lightway\Deploy-Database.ps1 -serverInstance:$serverInstance -databaseName:$databaseName -migrationsDir:$migrationsDir -toVersion:$toVersion -allowCreate

    }
}catch{
    Write-Host $error[0].ScriptStackTrace
    throw
}