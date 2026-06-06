# Tests

Pester suites:

- `cucp.Fast.Tests.ps1` - fast smoke tests for parser health and safe read-only wrapper surface.
- `cucp.Tests.ps1` - broader regression coverage.

Run from the repository root:

```powershell
Invoke-Pester .\tests\cucp.Fast.Tests.ps1
Invoke-Pester .\tests\cucp.Tests.ps1
```
