# Windows maintenance entry points. Arguments travel through environment variables.
set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

default:
    @just --list

# Check tools, pins, module revision and selected build workspace; no downloads.
doctor:
    @& ./installer/build/maintain.ps1 -Task doctor; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Show the pinned runtime versions and the next installer filename.
versions:
    @& ./installer/build/maintain.ps1 -Task versions; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Download pinned NSIS, zstd, 7zr and actionlint into installer/build/tools.
bootstrap:
    @& ./installer/build/fetch-build-tools.ps1; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Initialize exactly the module revision recorded by Git.
init:
    @& ./installer/build/maintain.ps1 -Task init; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Fetch upstream refs without merging or updating payload versions.
upstream-fetch:
    @& ./installer/build/maintain.ps1 -Task upstream-fetch; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Merge an upstream ref on a clean branch, retaining a backup branch first.
upstream-merge $upstream_ref="origin/master":
    @& ./installer/build/maintain.ps1 -Task upstream-merge -Ref $env:upstream_ref; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Align the module lock with the Git gitlink after an upstream merge.
pin-modules:
    @& ./installer/build/maintain.ps1 -Task pin-modules; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Read available stable releases without changing pins or installing anything.
updates $component="all":
    @& ./installer/build/update-payloads.ps1 -Component $env:component -Check; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Update reviewed runtime pins (e.g. emacs/git/toolchain/zstd/pandoc/all); optional tag.
update $component $payload_version="latest":
    @& ./installer/build/update-payloads.ps1 -Component $env:component -Version $env:payload_version; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Increment the Windows build revision; Doom's version comes from .doom.
bump-release:
    @& ./installer/build/maintain.ps1 -Task bump-release; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Download and verify the pinned payload archives and build tools.
fetch:
    @& ./installer/build/fetch-build-tools.ps1; if ($LASTEXITCODE) { exit $LASTEXITCODE }; & ./installer/build/fetch-payloads.ps1; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Assemble a workspace for exactly the current sources and pins.
stage:
    @& ./installer/build/build-installer.ps1 -Stages stage; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Retain an interrupted/contaminated workspace beside a fresh staging tree.
restage:
    @& ./installer/build/maintain.ps1 -Task restage; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Complete build with compression, using pins only; optional development label.
build $release_version="":
    @& ./installer/build/build-installer.ps1 -Version $env:release_version; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Complete build without compression for local iteration.
build-fast $release_version="":
    @& ./installer/build/build-installer.ps1 -SkipCompress -Version $env:release_version; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Recompile the current workspace without downloading or restaging.
compile:
    @& ./installer/build/build-installer.ps1 -Stages compile; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Recompile without compression; the staging inputs must still match.
compile-fast:
    @& ./installer/build/build-installer.ps1 -Stages compile -SkipCompress; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Workflow/PowerShell syntax, pin/build checks, regressions and NSIS lifecycle.
test:
    @& ./installer/build/maintain.ps1 -Task test; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Real bundled Emacs/native compiler, Git tools and GUI client in temporary homes.
test-runtime:
    @& ./installer/build/maintain.ps1 -Task test-runtime; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Exercise default editing tools; optional synced straight directory adds real undo persistence.
test-defaults $package_root="":
    @& ./installer/build/maintain.ps1 -Task test-defaults -PackageRoot $env:package_root; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Real WSL tests with an explicitly chosen distribution and an isolated test copy.
test-wsl $distribution:
    @& ./installer/build/maintain.ps1 -Task test-wsl -Distribution $env:distribution; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Build a release after automated checks and verify the resulting archive.
release: _release-check doctor test build test-runtime
    @& ./installer/build/maintain.ps1 -Task verify; if ($LASTEXITCODE) { exit $LASTEXITCODE }

_release-check:
    @& ./installer/build/maintain.ps1 -Task release-check; if ($LASTEXITCODE) { exit $LASTEXITCODE }

# List generated installers and their SHA256 hashes; does not publish.
artifacts:
    @& ./installer/build/maintain.ps1 -Task artifacts; if ($LASTEXITCODE) { exit $LASTEXITCODE }
