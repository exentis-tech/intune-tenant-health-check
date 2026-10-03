## Summary

## Checklist
- [ ] Pester tests pass (`Invoke-Pester -Path .\tests`) and new logic has tests
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` passes
- [ ] Works on Windows PowerShell 5.1
- [ ] Still read-only (no write or delete Graph calls)
- [ ] Tested against a non-production tenant
- [ ] No real tenant data, secrets or identifiers in code, fixtures or screenshots
- [ ] README / CHANGELOG updated if behaviour changed
