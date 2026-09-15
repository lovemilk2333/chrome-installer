# Chrome/Chromium Version Manager

Download, run and manage isolated Chrome and Chromium installations by version.

## Requirements

| Platform | Dependencies |
|----------|-------------|
| Linux/macOS (bash) | `curl`, `jq`, `unzip` |
| Windows (PowerShell) | None (uses built-in cmdlets) |

## Usage

```bash
# Linux / macOS
./install-chrome.sh <command> [options]

# Windows (PowerShell)
.\install-chrome.ps1 <command> [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `list local [chrome\|chromium\|all]` | List locally installed versions |
| `list chrome [N]` | List latest N Chrome for Testing versions (v113+, default: 30) |
| `list tags [N]` | List latest N Chrome tags from googlesource (v10+, default: 30) |
| `list chromium [N]` | List latest N Chromium revisions (default: 30) |
| `search chrome <ver> [N]` | Search Chrome versions (e.g. "80", "80.0.3987") |
| `search chromium <ver> [N]` | Search Chromium revisions by Chrome version |
| `download chrome <version>` | Download specific Chrome version |
| `download chromium <revision>` | Download specific Chromium revision |
| `run chrome <version> [args...]` | Run Chrome with isolated user-data |
| `run chromium <revision> [args...]` | Run Chromium with isolated user-data |
| `remove chrome <version>` | Delete a downloaded Chrome version |
| `remove chromium <revision>` | Delete a downloaded Chromium revision |
| `latest chrome` | Download latest stable Chrome |
| `latest chromium` | Download latest stable Chromium |
| `clean cache\|all` | Clear cache or all downloaded data |

### Examples

```bash
# Download latest Chrome 80.x
./install-chrome.sh download chrome 80

# v prefix is auto-stripped
./install-chrome.sh download chrome v80.0.3987

# Semantic search
./install-chrome.sh search chrome 80.0.3987

# Run with flags
./install-chrome.sh run chrome 130.0.6723.69 --headless

# Download specific Chromium revision
./install-chrome.sh download chromium 757694

# Remove old version
./install-chrome.sh remove chrome 80.0.3987.87
```

**PowerShell (Windows):**

```powershell
# Download latest Chrome 80.x
.\install-chrome.ps1 download chrome 80

# v prefix is auto-stripped
.\install-chrome.ps1 download chrome v80.0.3987

# Semantic search
.\install-chrome.ps1 search chrome 80.0.3987

# Run with flags
.\install-chrome.ps1 run chrome 130.0.6723.69 --headless

# Download specific Chromium revision
.\install-chrome.ps1 download chromium 757694

# Remove old version
.\install-chrome.ps1 remove chrome 80.0.3987.87
```

## Directory Structure

```
install-chrome.sh         # bash (Linux/macOS)
install-chrome.ps1        # PowerShell (Windows)
chrome/
  <version>/
    chrome/          Browser binary
    user-data/       Isolated user profile
chromium/
  <revision>/
    chrome/          Browser binary
    user-data/       Isolated user profile
.cache/              API data cache (24h TTL)
```

## Data Sources

- **Version listing**: `chromium.googlesource.com` -- 38K+ version tags from Chrome 10 onwards
- **Download (v113+ for now (2026))**: Google Chrome for Testing CDN
- **Download (pre-v113 for now (2026))**: `chromium-browser-snapshots` -- resolves via Cr-Commit-Position from googlesource commit metadata
