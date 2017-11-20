param(
    $serverInstance,
    $databaseName,
    $commandText,
    [pscredential] $credentials,
    $providerName = "SQLOLEDB" # or OraOLEDB.Oracle etc...
)

$connectionStringParts = @{
    "Data Source" = $serverInstance
    "Provider" = $providerName
}
if($databaseName){ [void] $connectionStringParts.Add("Initial Catalog", $databaseName) }

if($credentials){
    $username = $credentials.UserName
    $password = $credentials.GetNetworkCredential().Password
    [void] $connectionStringParts.Add("User Id", $username)
    [void] $connectionStringParts.Add("Password", $password)
}else{
    [void] $connectionStringParts.Add("Integrated Security", "SSPI")
}

$conn = new-object system.data.oledb.oledbconnection
$connectionString = ($connectionStringParts.GetEnumerator() | % { "{0}={1}" -f $_.Key,$_.Value }) -join ";"

$conn.ConnectionString = $connectionString
[void] $conn.Open()
try{
    $command = $conn.CreateCommand();
    $command.CommandText = $commandText;
    if($commandParams){
        foreach($item in $commandParams.GetEnumerator()){
            $commandParam = $command.CreateParameter()
            $commandParam.ParameterName = $item.Name;
            $commandParam.Value = $item.Value;
            [void] $command.Parameters.Add($commandParam)
        }
    }
    Write-Verbose "Execute '$commandText'"
    $command.ExecuteNonQuery();
}finally{
    [void] $conn.Close();
}

