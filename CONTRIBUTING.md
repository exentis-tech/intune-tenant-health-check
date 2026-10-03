# Contributing

Thanks for helping improve this project.

## Ground rules

- **Never include real tenant data** in issues, pull requests, screenshots or test fixtures: no tenant IDs, app IDs, secrets, device names, serial numbers, user names or email addresses. Use obviously fake values (`contoso.example`, `LAPTOP-EXAMPLE01`).
- The tool is **read-only**. Pull requests must not add write, delete or other state-changing Graph calls.
- Keep it dependency-free: plain PowerShell (5.1 compatible) and a single self-contained HTML template.

## Development

1. Fork the repository and create a branch: `git checkout -b feature/short-description`
2. Put logic that does not call Graph in `lib/` as a pure function, and add Pester tests for it in `tests/`.
3. Run the checks the CI runs:
   ```powershell
   Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
   Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
   Invoke-Pester -Path .\tests
   Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
   ```
4. Run the script against a non-production tenant and open the generated report to check the result.
5. Update `README.md` and `CHANGELOG.md` if behaviour changes, then open a pull request.

## Style

- Compatible with **Windows PowerShell 5.1**: no `??`, `?.` or ternary operators. Keep `.ps1` files ASCII-only.
- 4-space indentation, `Verb-Noun` function names, `PascalCase` variables.
- Every Graph call goes through `Invoke-GraphRequest` / `Get-GraphCollection` so paging and throttling are handled.

## Code of conduct

Be respectful and constructive. Maintainers may remove comments or contributors that harass or discriminate.
