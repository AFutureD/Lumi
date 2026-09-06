# Notice

Lumi is licensed under the Apache License 2.0 (see `LICENSE`). It includes work derived from the third-party projects below; their notices are reproduced here as their licenses require.

## OpenUsage

The plan-usage feature (reading Claude Code's and Codex's saved sign-ins and mapping the providers' usage endpoints into rate-limit windows) is derived from **OpenUsage** by Robin Ebers — https://github.com/robinebers/openusage — commit `70dea9a8fa21ed205aa9ad625b416a1e7792d5a1` (2026-09-06).

Derived material, rewritten in Lumi's own structure:

- `Common/Sources/Core/PlanUsage/ClaudePlanUsage.swift` — credential-file shape, usage endpoint and headers, window / `limits[]` mapping, plan label (from `Providers/Claude/ClaudeAuthStore.swift`, `ClaudeUsageClient.swift`, `ClaudeUsageMapper.swift`, `DefaultAccountObserver.swift`).
- `Common/Sources/Core/PlanUsage/CodexPlanUsage.swift` — `auth.json` shape, JWT claims, usage endpoint and headers, window classification by duration, plan label (from `Providers/Codex/CodexAuthStore.swift`, `CodexUsageClient.swift`, `CodexUsageMapper.swift`, `Support/ProviderParse.swift`).
- `Common/Sources/Core/PlanUsage/PlanUsageJSON.swift` — JWT payload decoding, epoch seconds / milliseconds detection, title-casing.
- `CLI/Sources/DaemonRuntime/ClaudeKeychainCredentials.swift` — reading the `Claude Code-credentials` Keychain item through `/usr/bin/security`, the config-directory service-name suffix, hex output decoding (from `Providers/Claude/ClaudeAuthStore.swift`, `Providers/SystemClients.swift`).
- Test fixtures in `Common/Tests/CoreTests/PlanUsageTests.swift` adapted from `Tests/OpenUsageTests/ClaudeProviderTests.swift` and `CodexProviderTests.swift`.

OpenUsage is distributed under the MIT License:

```
MIT License

Copyright (c) 2026 Robin Ebers

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
