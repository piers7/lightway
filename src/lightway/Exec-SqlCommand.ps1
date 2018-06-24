param(
    $serverInstance,
    $databaseName,
    $commandText,
    [hashtable]$commandParams = @{},
    [pscredential] $credentials,
    $providerName,   # specify a registered .net driver name, eg System.Sql.SqlClient
    $oleDbDriverName, # use SQLOLEDB or OraOLEDB.Oracle etc..
    [switch] $execScalar
)

if ($providerName){
    $factory = [System.Data.Common.DbProviderFactories]::GetFactory($providerName)
    $builder = $factory.CreateConnectionStringBuilder()
}elseif($oleDbDriverName){
    $factory = [System.Data.Common.DbProviderFactories]::GetFactory('System.Data.OleDb')
    $builder = $factory.CreateConnectionStringBuilder()
    [void] $builder.Add("Provider", $oleDbDriverName)
}else{
    $factory = [System.Data.Common.DbProviderFactories]::GetFactory('System.Data.SqlClient')
    $builder = $factory.CreateConnectionStringBuilder()
}
[void] $builder.Add("Data Source", $serverInstance)
if ($databaseName) { [void] $builder.Add("Initial Catalog", $databaseName) }

if($credentials){
    $username = $credentials.UserName
    $password = $credentials.GetNetworkCredential().Password
    [void] $builder.Add("User Id", $username)
    [void] $builder.Add("Password", $password)
}else{
    [void] $builder.Add("Integrated Security", "SSPI")
}

$connectionString = $builder.ToString()
Write-Verbose $connectionString

$conn = $factory.CreateConnection()
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
    if($execScalar){
        $command.ExecuteScalar();
    }else{
        $command.ExecuteNonQuery();
    }
}finally{
    [void] $conn.Close();
}

