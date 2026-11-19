# BcNuGetHelper

A self-hosted NuGet feed service for Business Central apps. Fork this repository and deploy it to your own Azure subscription directly from your fork — no separate deployment repository needed.

The service consists of:

- An **Azure Function** (.NET 10 isolated, Flex Consumption) hosting the endpoints
- A **Storage Account** where packages are stored in a NuGet-friendly folder structure
- A **User-Assigned Managed Identity** granting the function access to the storage account

## Endpoints

All apps are uploaded once and served through three read-only NuGet v3 feeds:

| Feed | Service index URL | Content |
|------|-------------------|---------|
| `apps` | `https://<functionapp>.azurewebsites.net/api/apps/index.json` | Full .app files |
| `runtime` | `https://<functionapp>.azurewebsites.net/api/runtime/index.json` | Runtime packages, compiled per supported Business Central version by a GitHub workflow |
| `symbols` | `https://<functionapp>.azurewebsites.net/api/symbols/index.json` | Symbols-only packages (created with altool during upload) |

Each feed implements the NuGet v3 resources needed by [BcContainerHelper](https://github.com/microsoft/navcontainerhelper)'s NuGet search functionality:

- **Service index** — `GET api/{feed}/index.json`
- **SearchQueryService** — `GET api/{feed}/query?q=<query>&skip=<n>&take=<n>`
- **PackageBaseAddress (flat container)** —
  - `GET api/{feed}/package/{id}/index.json` (version list)
  - `GET api/{feed}/package/{id}/{version}/{id}.{version}.nupkg` (download)
- **Direct .app download** — `GET api/{feed}/download/{id}/{version}` returns the raw `.app` for that flavor. `{version}` may be `latest`. These are stable, non-expiring URLs (anonymous for public feeds).
- **Logo** — `GET api/logo/{id}` (or `api/logo/{id}/{version}`) returns the app logo extracted from the `.app` on upload.
- **NuGet push** — `PUT api/{feed}/api/v2/package` stores a prebuilt `.nupkg` verbatim into the feed (standard NuGet push, requires a **write** or **readwrite** access key for that feed). This is how the runtime workflow publishes compiled packages; the upload endpoint below is the path that converts `.app` files into packages.

To publish Business Central apps, use the upload endpoint (it does the `.app` → package conversion):

- **Upload** — `POST api/upload` (requires a Microsoft Entra bearer token via the `Authorization: Bearer` header). Accepts a raw `.app` file body or `multipart/form-data` with one or more `.app` files (Business Central apps). Files posted under the `dependencies` form field (`.app` files or a `.zip`) are stored as the app's compilation **dependencies** — they're not published as packages, but are kept per app+version and passed to the runtime workflow so runtime packages can be (re)generated for new Business Central versions. Optional query parameters control runtime package generation for the uploaded app(s): `country` (default `w1`), `additionalCountries` (comma-separated), and `artifactType` (`sandbox` or `onprem`, default `sandbox`).
- **Remove** — `DELETE api/packages/{appId}` (requires a Microsoft Entra bearer token) removes every package for an app id across all feeds: the full app, the symbols package, and the runtime indirect + compiled packages. Pass `*` (or `all`) as the app id to remove every package. A `version` query parameter (default `*` = all versions) narrows deletion to a single app version, which also removes every compiled runtime package generated for that version. Also available as the [`Remove Packages`](.github/workflows/remove-packages.yml) workflow (dispatch with an app id and optional version; authenticates via OIDC).

Uploaded apps are processed with the [AL development tools](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-tool-package) (`altool`, bundled with the deployment): the manifest (id, name, publisher, version, dependencies) is extracted, a symbols-only package is created for the symbols feed, and everything is wrapped as NuGet packages with dependency information and stored under `{feed}/{packageId}/{version}/` in the `packages` blob container.

## Public and private feeds

Each feed is either **public** (anonymous read access) or **private** (requires an access key). Which feeds are public is controlled by the `PUBLIC_FEEDS` repository variable; all feeds are private by default.

Package **metadata** (service index, search, version lists, nuspec and logo) is served anonymously as soon as **at least one** feed is public \u2014 only the package/app **content** downloads (`.nupkg` files and the `api/{feed}/download/...` `.app` endpoint) remain gated per feed. If **no** feed is public, metadata also requires an access key, so a fully private deployment exposes nothing anonymously.

Access keys are managed through Entra-protected endpoints (also usable by allow-listed GitHub users via the [token management web app](#token-management-web-app)):

| Endpoint | Description |
|----------|-------------|
| `GET api/accesskeys` | List every access key |
| `GET api/accesskeys/{name}` | Get an access key (name, key, feeds, type, description, e-mail and expiry) |
| `POST api/accesskeys/{name}` | Create an access key. Body: `{ "feeds": ["apps", "runtime", "symbols"], "type": "read", "description": "who it is for", "email": "notify@example.com", "expiresInDays": 90 }`. `email` is **required** (used to notify when the key changes); `type` (`read`, `write` or `readwrite`, default `read`), `description` and `expiresInDays` are optional. The name is at most 64 characters (letters, digits, `.`, `-`, `_`), description at most 200 and e-mail at most 200. Returns the generated key |
| `POST api/accesskeys/{name}/revoke` | Revoke a key (expire it immediately, keeping the record) |
| `POST api/accesskeys/{name}/renew` | Renew a key. Optional body `{ "expiresInDays": 90 }`; omit for no expiry |
| `POST api/accesskeys/{name}/rotate` | Rotate a key: issue a new active key under the same name and keep the previous key value valid for a grace period. Body `{ "oldKeyValidDays": 7 }` |
| `POST api/accesskeys/rotate-all` | Rotate every active key (skips expired/revoked and ephemeral keys). Body `{ "oldKeyValidDays": 7 }` |
| `DELETE api/accesskeys/{name}` | Remove an access key permanently |
| `POST api/token` | Issue **short-lived** feed tokens (a `read` token for `apps` and a `readwrite` token for `runtime`). Used by the runtime workflow, which authenticates with a Microsoft Entra token obtained via GitHub OIDC — so no long-lived credential is passed at dispatch |

Each key has a **type**: `read` keys grant read access to their feeds, `write` keys can **push** packages (`PUT api/{feed}/api/v2/package`) to their feeds, and `readwrite` keys can do both. A `read` key can never push, so keys handed to consumers cannot publish. (The upload endpoint that converts `.app` files is separate and always requires a Microsoft Entra token.)

```powershell
$token = az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv
Invoke-RestMethod `
    -Method Post `
    -Uri "https://<functionapp>.azurewebsites.net/api/accesskeys/partner1" `
    -Headers @{ Authorization = "Bearer $token" } `
    -Body '{ "feeds": ["apps", "symbols"], "type": "read" }' `
    -ContentType "application/json"
```

Keys are stored in a private blob (`config/accesskeys.json`) that is managed exclusively by these endpoints — do not edit it manually. The registry is loaded into memory at startup and kept in memory for the lifetime of the function app.

When accessing a private feed, clients pass the key as basic auth password, `Authorization: Bearer` header, `X-NuGet-ApiKey` header, or `?token=` query parameter.

### Using the feeds with BcContainerHelper

```powershell
$feedUrl = "https://<functionapp>.azurewebsites.net/api/apps/index.json"
Get-BcNuGetPackage -nuGetServerUrl $feedUrl -packageName "<publisher>.<appname>" -select Exact
```

Or register as a trusted feed (use the access key as token for private feeds):

```powershell
$bcContainerHelperConfig.TrustedNuGetFeeds = @(
    @{ "Url" = "https://<functionapp>.azurewebsites.net/api/apps/index.json"; "Token" = "<access key>" }
)
```

### Uploading apps

```powershell
$token = az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv
Invoke-RestMethod `
    -Method Post `
    -Uri "https://<functionapp>.azurewebsites.net/api/upload" `
    -Headers @{ Authorization = "Bearer $token" } `
    -InFile ".\MyApp_1.0.0.0.app" `
    -ContentType "application/octet-stream"
```

## Deployment

Deployment runs entirely from your fork using GitHub Actions and [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/). The templates live in [`bicep/`](bicep). There is no Terraform state to manage: `az deployment` reconciles against the live resources in your subscription, applying only the differences on each run (ARM *incremental* mode). Removing a resource from a template does **not** delete it — delete such resources manually.

### 1. Fork this repository

### 2. Create a managed identity for GitHub OIDC

The deploy workflow authenticates with a **user-assigned managed identity** using GitHub OIDC federation — no app registration and no stored credentials. This identity (and the resource group) must exist before the workflow can run, so it is created once locally with your own credentials via [`bicep/bootstrap.bicep`](bicep/bootstrap.bicep). All roles are scoped to the deployment resource group only.

```powershell
$repo         = "<owner/repo>"                     # Owner and repo of BcNuGetHelper fork
$location     = "<azure location>"                 # e.g. westeurope
$baseName     = "<base name>"                      # e.g. nghfreddydk (3-17 lowercase letters/digits, globally unique)
$rg           = "$($baseName)-rg"                  # e.g. nghfreddydk-rg
$subscription = az account show --query id -o tsv  # subscription ID

# OIDC subjects. GitHub is rolling out a claim format that embeds account and repository IDs,
# so register both the classic and the ID-based subject.
$repoInfo         = Invoke-RestMethod "https://api.github.com/repos/$repo"
$subjectClassic   = "repo:$($repo):ref:refs/heads/main"
$subjectWithIds   = "repo:$($repoInfo.owner.login)@$($repoInfo.owner.id)/$($repoInfo.name)@$($repoInfo.id):ref:refs/heads/main"

# Verify the base name is available before creating anything
if ((az storage account check-name --name $baseName --query nameAvailable -o tsv) -ne "true") {
    throw "Storage account name '$baseName' is not available - choose another base name"
}
$body = '{"name": "' + $baseName + '-func", "type": "Microsoft.Web/sites"}'
if ((az rest --method post --url "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Web/checknameavailability?api-version=2023-12-01" --body $body --query nameAvailable -o tsv) -ne "true") {
    throw "Function app name '$($baseName)-func' is not available - choose another base name"
}

# Create the resource group, the deploy identity, its federated credentials and role assignments
$deploy = az deployment sub create `
    --location $location `
    --template-file bicep/bootstrap.bicep `
    --parameters baseName=$baseName location=$location resourceGroupName=$rg `
        githubSubjectClassic=$subjectClassic githubSubjectWithIds=$subjectWithIds `
    --query properties.outputs -o json | ConvertFrom-Json

# Configure the repository secrets and variables (requires gh auth login)
$tenantId = az account show --query tenantId -o tsv
gh secret set AZURE_CLIENT_ID --repo $repo --body $deploy.deployClientId.value
gh secret set AZURE_TENANT_ID --repo $repo --body $tenantId
gh secret set AZURE_SUBSCRIPTION_ID --repo $repo --body $subscription

gh variable set BASE_NAME --repo $repo --body $baseName
gh variable set AZURE_LOCATION --repo $repo --body $location
gh variable set RESOURCE_GROUP_NAME --repo $repo --body $rg
# Optional: feeds served without authentication
# gh variable set PUBLIC_FEEDS --repo $repo --body "apps,runtime,symbols"
# Optional: also allow extra client/application ids to call the admin endpoints
# (the deploy identity is always allowed; this appends to the allow-list)
# gh variable set ADMIN_CLIENT_ID --repo $repo --body "<client-id>"
# Optional: GitHub logins allowed to use the token-management web app
# gh variable set WEBAPPUSERS --repo $repo --body "octocat,another-user"
```

Roles granted to the deploy identity: **Contributor** (create resources), **Role Based Access Control Administrator** (create the role assignment for the function's managed identity) and **Storage Blob Data Contributor** (function content deployment to the deployments container).

> Two federated credentials are registered because GitHub is rolling out a new OIDC subject claim format that embeds account and repository IDs (`repo:owner@id/repo@id:...`). Registering both the classic and the ID-based subject makes login work either way. If login still fails with `AADSTS700213`, copy the exact "subject claim" shown in the failed *Azure login* step into a federated credential.

### 3. Configure repository settings

All settings are configured as repository **secrets** and **variables** (Settings → Secrets and variables → Actions). The script in step 2 sets them all via the [GitHub CLI](https://cli.github.com/); the tables below describe them for reference.

#### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `AZURE_CLIENT_ID` | Yes | Client id of the managed identity created above (`az identity show --name github-deploy --resource-group $rg --query clientId -o tsv`) |
| `AZURE_TENANT_ID` | Yes | Your Entra ID tenant id |
| `AZURE_SUBSCRIPTION_ID` | Yes | The Azure subscription to deploy to |
| `GH_APP_PRIVATE_KEY` | No | PEM private key of the GitHub App used to dispatch the runtime workflow (see [Runtime package generation](#runtime-package-generation)). Stored as a Function App setting |
| `SMTP_PASSWORD` | No | SMTP password for access-key change [e-mail notifications](#e-mail-notifications). The rest of the SMTP config is set as variables (below) |

#### Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BASE_NAME` | Yes | — | Base name for all Azure resources. Lowercase letters and digits only, 3–17 characters, globally unique (used for storage account names). Example: `mybcnuget` |
| `AZURE_LOCATION` | Yes | — | Azure region to deploy to |
| `RESOURCE_GROUP_NAME` | No | `<BASE_NAME>-rg` | Name of the resource group (must match the one created in step 2) |
| `PUBLIC_FEEDS` | No | (empty — all feeds private) | Comma-separated list of feeds served without authentication, e.g. `apps,runtime,symbols` |
| `FEED_BASE_URL` | No | `https://<BASE_NAME>-func.azurewebsites.net` | Custom domain of the function app (e.g. `https://feed.example.com`), used for the feed and download URLs shown on the [website](#website-github-pages). The domain must already be bound to the function app |
| `SMTP_HOST` | No | (empty — notifications off) | SMTP server host for access-key change [e-mail notifications](#e-mail-notifications) |
| `SMTP_PORT` | No | — | SMTP port (e.g. `587` for STARTTLS) |
| `SMTP_USERNAME` | No | — | SMTP username |
| `SMTP_FROM` | No | — | From address for notification e-mails (e.g. `nuget@example.com`) |
| `SMTP_FROM_NAME` | No | (the `SMTP_FROM` address) | Display name shown as the e-mail sender (e.g. `Contoso`) and used for the `{{sender}}` sign-off |
| `ADMIN_CLIENT_ID` | No | (deploy identity `AZURE_CLIENT_ID`) | Restricts the admin endpoints (upload, access keys, token, remove, regenerate) to specific client/application ids. The deploy workflow **always** locks these to the deploy identity, so only the OIDC workflow can call them. Set this variable to a comma-separated list of extra client ids to additionally allow other callers (the deploy identity stays allowed) |
| `GH_APP_CLIENT_ID` | No | (empty — runtime generation disabled) | Client id of the GitHub App used to dispatch the runtime workflow |
| `GH_APP_INSTALLATION_ID` | No | — | Installation id of that GitHub App on this repository |
| `WEBAPPUSERS` | No | (empty — web app disabled) | Comma-separated list of GitHub logins allowed to sign in to the [token-management web app](#token-management-web-app). When empty, no one can use the web app |

### 4. Deploy

Run the **Deploy** workflow manually (Actions → Deploy → Run workflow). The workflow:

1. Logs in to Azure using OIDC (no stored credentials)
2. Deploys `bicep/main.bicep` to the resource group (`az deployment group create`, incremental) to create/update all resources
3. Builds the .NET 10 function app and deploys it

### Resources created

| Resource | Name |
|----------|------|
| Resource group | `<RESOURCE_GROUP_NAME>` |
| Storage account (packages + deployments) | `<BASE_NAME>` |
| User-assigned managed identity | `<BASE_NAME>-id` |
| App Service plan (Flex Consumption) | `<BASE_NAME>-plan` |
| Function app | `<BASE_NAME>-func` |
| Application Insights + Log Analytics | `<BASE_NAME>-ai` / `<BASE_NAME>-log` |

## Token management web app

A browser-based app for managing feed access keys is served by the function app at
`https://<BASE_NAME>-func.azurewebsites.net/api/app/`. The **Deploy Function App** workflow prints
this link and a scannable QR code to its run summary once deployment succeeds.

Sign-in uses GitHub. Access is restricted to the logins listed in the `WEBAPPUSERS` repository
variable — everyone else is refused after signing in. Two sign-in methods are supported:

- **Sign in with GitHub** (device flow) — available when the runtime GitHub App is configured
  (`GH_APP_CLIENT_ID`) with **Device Flow** enabled (see [Runtime package generation](#runtime-package-generation)).
  The web app reuses that app's client id; the flow is proxied through the backend
  (`api/auth/device/code`, `api/auth/device/token`) so no client secret is needed.
- **Personal access token** — paste a GitHub token with the `read:user` scope. Always available as a
  fallback.

Once signed in, allowed users can:

- **Add** an access key with a name, a required contact e-mail (used to notify the recipient when the
  key changes), a description (who/what it is for), a set of feeds (`apps`, `runtime`, `symbols`, or
  all), an access level (`read`, `write`, `readwrite`) and an optional expiry.
- **Revoke** a key (expires it immediately but keeps the record).
- **Renew** a key. For a revoked or expiring key this extends (or clears) its expiry. For an **active**
  key the button is labelled **Rotate**: a new key value is issued immediately and the previous value
  keeps working for a grace period you choose (in days), so consumers can switch over without downtime.
  **Rotate all** does the same for every active key at once.
- **Remove** a key permanently.

The same operations are available on the [access key endpoints](#endpoints) using a Microsoft
Entra token, for automation.

### E-mail notifications

When SMTP is configured, the service e-mails the key's contact address on key changes:

- **Created**, **Revoked** and **Renewed** — always.
- **Rotated** — when an active key is renewed/rotated; the e-mail states how long the old key stays valid.
- **Deleted** — only if the key was still active. A key that was already revoked/expired doesn't send
  a second notice.

Notifications are enabled only when all SMTP settings are configured — the `SMTP_HOST`, `SMTP_PORT`,
`SMTP_USERNAME` and `SMTP_FROM` variables and the `SMTP_PASSWORD` secret. If any is missing, key
changes still work but no e-mail is sent. Sending uses STARTTLS, and e-mail failures are logged
without blocking the operation.

The messages come from the [`email-templates/`](email-templates) folder — one HTML file per event
([`created.html`](email-templates/created.html), [`revoked.html`](email-templates/revoked.html),
[`renewed.html`](email-templates/renewed.html), [`rotated.html`](email-templates/rotated.html),
[`deleted.html`](email-templates/deleted.html)). Each file's subject is taken from a leading
`<!-- subject: ... -->` comment and the rest is the HTML body. Bodies support the customer-facing
placeholders `{{feeds}}`, `{{feedurls}}` (feed names with their `index.json` links, used in
`created.html`/`rotated.html`), `{{type}}` (access level), `{{key}}` (the access key), `{{expires}}`,
`{{email}}`, `{{sender}}` (the sign-off name — `Smtp__FromName` if set, otherwise the `SMTP_FROM`
address) and, in `rotated.html`, `{{oldkeydays}}` (grace days the old key stays valid). Values are
HTML-encoded, and the internal key name and description are intentionally **not** available. Customize
the notifications by editing these files in your fork.

## Runtime package generation

Runtime packages contain the app compiled against a specific Business Central version, and one
must be produced for **every supported minor version** the app targets. That compilation needs a
Business Central container on a Windows build agent, which the function app cannot do itself.
Instead, after an app is uploaded the function app dispatches the
[`Generate Runtime NuGet Packages`](.github/workflows/generate-runtime-nuget.yml) workflow, which
compiles the runtime packages (via [BcContainerHelper](https://github.com/microsoft/navcontainerhelper))
and pushes them back to the `runtime` feed through the NuGet push endpoint.

The localizations and artifact type to compile for are **per app**, passed as query parameters on
the upload request (`country`, `additionalCountries`, `artifactType`) rather than as deployment
settings. The set of Business Central versions is determined automatically from the app's
application dependency (every supported minor version at or above it).

The dispatch only passes the **backend URL** (and tokenless download URLs) — no feed credential.
The workflow logs in to Azure with the existing deploy identity via **GitHub OIDC**, then calls
`POST api/token` to obtain **short-lived** feed tokens (read for `apps`, read/write for `runtime`).
So the credential that can push packages is never stored or passed at dispatch; it is minted per
run and expires. Because `api/token` is an admin endpoint, the deploy workflow locks the admin
endpoints to the deploy identity by default (`ADMIN_CLIENT_ID` defaults to `AZURE_CLIENT_ID`), so
only the OIDC workflow can request feed tokens. Override the `ADMIN_CLIENT_ID` variable to widen
that allow-list.

To dispatch a workflow securely — without a user-bound Personal Access Token — the function app
authenticates as a **GitHub App**. To enable runtime generation:

1. **Create a GitHub App** (Settings → Developer settings → GitHub Apps → New). Grant repository
   permissions **Actions: Read and write** (to dispatch the workflow) and **Metadata: Read-only**
   (mandatory). No other permissions are needed. Generate a **private key** (PEM) and note the
   **Client ID**.
2. **Install** the app on your fork and note the **Installation ID** (the number at the end of the
   installation settings URL).
3. Set the repository variables `GH_APP_CLIENT_ID` and `GH_APP_INSTALLATION_ID`, and the
   secret `GH_APP_PRIVATE_KEY` (see the tables above). The private key is stored as a Function App
   setting (`GitHubApp__PrivateKey`) — encrypted at rest by Azure, but readable by anyone with
   config-read access to the app.
4. No extra OIDC setup is needed — the workflow reuses the deploy identity and the existing
   `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` secrets. The admin endpoints are
   locked to that identity by default (see `ADMIN_CLIENT_ID` above), so the workflow can call
   `POST api/token` out of the box; only override `ADMIN_CLIENT_ID` if you need to allow other callers.
5. Make sure **Actions are enabled** on your fork (GitHub disables them on new forks by default),
   otherwise the dispatched workflow won't run.

When these settings are absent the upload still succeeds; only the runtime workflow dispatch is
skipped.

#### Reusing the app for web-app sign-in

The same GitHub App also powers the [token-management web app](#token-management-web-app) sign-in —
no separate OAuth App or setting is needed. To enable the **Sign in with GitHub** button there, open
the app (Settings → Developer settings → GitHub Apps → *your app* → General) and tick **Enable Device
Flow**, then save. The web app automatically uses the same `GH_APP_CLIENT_ID`. Signing in needs **no
extra permissions** — it only reads the user's login to check it against `WEBAPPUSERS`.

The device flow returns a GitHub *user access token*. If the app has **Expire user authorization
tokens** enabled (the default for new apps), that token lasts about 8 hours, after which web-app
users are returned to the sign-in screen and must authorize again. Turn that setting off if you want
longer-lived sessions. Personal-access-token sign-in always works regardless of this setting, so
enabling device flow is optional.

### Regenerating for new Business Central versions

Runtime packages are per BC minor version, so new versions ship over time. The stored `.app` and
its dependency artifact let the packages be regenerated without re-uploading. The
[`Regenerate Runtime Packages`](.github/workflows/regenerate-runtime.yml) workflow runs weekly (and
on demand); it authenticates via OIDC and calls `POST api/regenerate`, which re-dispatches the
runtime workflow for the stored apps. The runtime workflow only builds versions that are missing, so
re-running is cheap when nothing new has shipped. By default it targets the latest version of each
app; dispatch with `allVersions: true` (or `POST api/regenerate?allVersions=true`) to cover every
stored version.

## Local development

Requirements: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local), [Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite).

```powershell
cd BcNuGetHelper
func start
```

Without a `PackagesStorageAccountName` setting the app falls back to the local Azurite emulator (`UseDevelopmentStorage=true`).

## Website (GitHub Pages)

A static, brandable catalog website can be published to GitHub Pages. It lists every app that is available on a public feed and, per app, shows the logo, description and dependencies (from the latest version) plus a table of all versions with direct download links for each public feed flavor (Full app / Runtime / Symbols).

Because browser downloads only work for public feeds, the site lists apps only when at least one feed is public (`PUBLIC_FEEDS`). If no feed is public, only the branded front page is rendered. The build reads metadata anonymously from the public feeds — no credentials are used.

To enable it:

1. In your fork, go to **Settings → Pages** and set **Source** to **GitHub Actions**.
2. Set the `PUBLIC_FEEDS` variable to the feeds you want to expose (e.g. `apps,runtime,symbols`).
3. **Re-brand the site** by editing [`site/branding.json`](site/branding.json) (see below) so it shows your company instead of the defaults.
4. Run the **Deploy Pages** workflow (Actions → Deploy Pages → Run workflow).

### Company branding

Edit [`site/branding.json`](site/branding.json) (company name, tagline, colors, logo, favicon, footer, links) and drop your own files in [`site/assets/`](site/assets):

- `logo.svg` — header/app logo
- `favicon.svg` — browser icon
- `custom.css` — appended after the generated theme, so any rule you add wins

`logo` and `favicon` may also be absolute URLs (`https://…`), in which case they're used as-is instead of being loaded from `assets/`.

Set `"showNupkg": false` in [`site/branding.json`](site/branding.json) to hide the `.nupkg` download buttons and show only `.app` (default is `true`).

Instead of editing the file, you can set a repository **variable** named `BRANDING` to the raw branding JSON; when present it overrides [`site/branding.json`](site/branding.json). This is handy for keeping branding in repository settings rather than in the fork's source.

Build it locally to preview:

```powershell
./site/Build-Site.ps1 -BaseUrl "https://<functionapp>.azurewebsites.net" -PublicFeeds "apps,runtime,symbols"
# open ./_site/index.html
```

## Repository layout

```
.github/workflows/deploy.yml            Full deployment (Bicep + function app)
.github/workflows/deploy-function.yml   Function app only (manual trigger)
.github/workflows/deploy-pages.yml      Build & publish the catalog website to GitHub Pages
.github/workflows/generate-runtime-nuget.yml  Compile & publish runtime packages (dispatched on upload)
.github/workflows/retry-runtime.yml     Re-run failed runtime jobs on fresh runners (up to 3 attempts)
.github/workflows/regenerate-runtime.yml  Re-dispatch runtime generation for new BC versions (scheduled)
.github/workflows/remove-packages.yml   Remove packages for an app id (or all) from every feed
.github/workflows/test.yml              End-to-end tests against the deployed service
.github/actions/fetch-feed-tokens/      Composite action: OIDC login + short-lived feed tokens
.github/scripts/runtime/                Runtime-package generation scripts (BcContainerHelper)
bicep/                                  Bicep templates (bootstrap + main infrastructure)
BcNuGetHelper/                          Azure Function app (.NET 10 isolated)
webapp/                                 Token-management web app (React + Vite, served at /api/app)
email-templates/                        Notification e-mail templates (one HTML file per event)
site/                                   Static catalog website (generator + branding)
tests/                                  Test scripts
```
