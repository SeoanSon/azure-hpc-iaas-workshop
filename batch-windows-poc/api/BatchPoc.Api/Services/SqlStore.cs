using Microsoft.Data.SqlClient;
using System.Data;
using Azure.Core;

namespace BatchPoc.Api.Services;

public sealed class SqlStore(TokenCredential credential, RuntimeOptions options)
{
    private const string SqlScope = "https://database.windows.net/.default";

    public async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(options.SqlConnectionString);
        var token = await credential.GetTokenAsync(
            new TokenRequestContext([SqlScope]), cancellationToken);
        connection.AccessToken = token.Token;
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    public static SqlCommand Command(SqlConnection connection, string sql, params (string, object?)[] parameters)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        command.CommandType = CommandType.Text;
        foreach (var (name, value) in parameters)
            command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command;
    }
}
