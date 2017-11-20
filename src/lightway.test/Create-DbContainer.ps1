param(
    $imageName = "microsoft/mssql-server-linux:2017-latest",
	$containerName = "lightwayDb",
	$saPassword = "ABcdefg!@#12",

	[switch] $updateImage
)

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)

pushd $scriptDir
try{
	if($updateImage){
		docker pull $imageName
		if ($LASTEXITCODE -gt 0) { throw "Pull failed (make sure you configured your proxy!)" }
	}

	# docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=abcdefg!@#$12" -p 1401:1433 --name test -d microsoft/mssql-server-linux:2017-latest

	docker create -p 1401:1433 -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=$saPassword" --name $containerName $imageName
	if ($LASTEXITCODE -gt 0) { throw "Create failed" }

}finally{
    popd
}