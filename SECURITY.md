# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's private reporting instead: **Security** tab → **Report a vulnerability**. Include steps to reproduce, the impact and the affected version. You should receive a response within 7 days.

## Good practice for users

- Use a dedicated app registration with **read-only** permissions for this tool.
- Use a short client-secret lifetime and rotate it. Restrict who can read `config.json` (NTFS permissions).
- Treat the `reports/` folder as sensitive: it contains device names, serial numbers, user names and object IDs.
- If a secret is ever exposed, delete it in Microsoft Entra immediately and create a new one.
