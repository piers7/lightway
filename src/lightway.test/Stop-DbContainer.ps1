param(
	$containerName = "lightwayDb"
)

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)

pushd $scriptDir
try{
	docker start $containerName
	if ($LASTEXITCODE -gt 0) { 
		throw "Stop failed" 
	}

}finally{
    popd
}