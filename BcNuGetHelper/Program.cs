using Azure.Identity;
using Azure.Storage.Blobs;
using BcNuGetHelper.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Server.Kestrel.Core;

var builder = FunctionsApplication.CreateBuilder(args);
builder.Services.Configure<KestrelServerOptions>(o => o.Limits.MaxRequestBodySize = null);
builder.Services.Configure<FormOptions>(o => o.MultipartBodyLengthLimit = long.MaxValue);
builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services.AddSingleton(_ =>
{
    var accountName = Environment.GetEnvironmentVariable("PackagesStorageAccountName");
    if (!string.IsNullOrEmpty(accountName))
    {
        // Uses the user-assigned managed identity (AZURE_CLIENT_ID app setting)
        return new BlobServiceClient(
            new Uri($"https://{accountName}.blob.core.windows.net"),
            new DefaultAzureCredential());
    }

    var connectionString = Environment.GetEnvironmentVariable("PackagesStorageConnectionString")
        ?? "UseDevelopmentStorage=true";
    return new BlobServiceClient(connectionString);
});

builder.Services.AddSingleton<FeedStorage>();
builder.Services.AddHostedService<FeedStorageLoader>();
builder.Services.AddSingleton<AccessKeyStore>();
builder.Services.AddHostedService<AccessKeyStoreLoader>();
builder.Services.AddSingleton<AlTool>();
builder.Services.AddSingleton<AdminAuthenticator>();
builder.Services.AddHttpClient();
builder.Services.AddSingleton<GitHubAuthenticator>();
builder.Services.AddSingleton<GitHubWorkflowDispatcher>();
builder.Services.AddSingleton<RuntimeWorkflowLauncher>();
builder.Services.AddSingleton<SmtpEmailSender>();
builder.Services.AddSingleton<EmailTemplateProvider>();
builder.Services.AddSingleton<AccessKeyNotifier>();

builder.Build().Run();
