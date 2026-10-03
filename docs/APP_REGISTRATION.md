# Microsoft Entra app registration

Intune Tenant Health Check signs in to Microsoft Graph with **app-only (client credentials)** authentication and only reads data. You need one app registration. This takes about five minutes.

> Use a **dedicated, read-only** app registration for reporting tools. Don't reuse an app that has write permissions, such as the one used by the Intune Device Lifecycle Console.

## 1. Create the app

1. Sign in to the [Microsoft Entra admin center](https://entra.microsoft.com).
2. Go to **Identity > Applications > App registrations > New registration**.
3. Name it, for example `Intune reporting (read-only)`.
4. Supported account types: **Accounts in this organizational directory only**. Leave the redirect URI empty.
5. Select **Register**, then copy the **Application (client) ID** and **Directory (tenant) ID** from the Overview page.

## 2. Add Microsoft Graph application permissions

1. Open **API permissions > Add a permission > Microsoft Graph > Application permissions**.
2. Add:
   - `DeviceManagementServiceConfig.Read.All`
   - `DeviceManagementConfiguration.Read.All`
   - `DeviceManagementApps.Read.All`
   - `DeviceManagementManagedDevices.Read.All`
   - `Application.Read.All` (optional, for app registration credentials)
3. Select **Grant admin consent for <your tenant>**. Every permission should show a green check.

> `Application.Read.All` lets the tool read every app registration in the tenant (names and credential expiry dates, never secret values). Leave it out and set `IncludeAppRegistrationCredentials` to `false` if you prefer.

## 3. Create a client secret

1. Open **Certificates & secrets > Client secrets > New client secret**.
2. Choose a short expiry (90 or 180 days) and copy the secret **Value** (not the Secret ID). It is shown only once.

## 4. Fill in config.json

Run the script once. It creates `config.json` from `config.example.json` and stops. Fill in:

```json
{
  "TenantId": "00000000-0000-0000-0000-000000000000",
  "ApplicationId": "00000000-0000-0000-0000-000000000000",
  "ClientSecret": "your-secret-value"
}
```

`config.json` is listed in `.gitignore`, so it is never committed.

## Troubleshooting

| Error | Cause |
|---|---|
| `AADSTS7000215: Invalid client secret` | You copied the Secret ID instead of the Value, or the secret expired. |
| `AADSTS700016: Application not found` | Wrong `ApplicationId` or `TenantId`. |
| `Access denied` / HTTP 403 | A permission is missing or admin consent was not granted. |
