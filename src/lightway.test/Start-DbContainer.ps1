param(
	$containerName = "lightwayDb"
)

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)

pushd $scriptDir
try{
	docker start $containerName
	if ($LASTEXITCODE -gt 0) { 
		docker logs $containerName
		throw "Start failed. Check the log output above for (potentially) more details" 
	}

}finally{
    popd
}