# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-03

### Added
- First release.
- Apple checks: MDM push certificate, ADE (ABM/ASM) tokens, VPP tokens.
- Android check: Managed Google Play binding and app sync.
- Connector checks: Mobile Threat Defense, NDES certificate connectors, Windows Autopilot sync.
- Tenant settings: subscription state, default compliance for devices with no policy, compliance validity period.
- App registration secret and certificate expiry with replacement-aware severity.
- Policy hygiene: unassigned profiles, settings catalog policies, compliance policies and apps; duplicate policy names.
- Device posture by platform, inactive devices and Windows 10 end of support.
- Interactive HTML report, JSON output and `-FailOn` exit codes for scheduled runs.
- Pester tests and CI on Windows PowerShell 5.1 and PowerShell 7.
