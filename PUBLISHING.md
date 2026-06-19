# Publish `bittensor-burn-message` to PyPI

Uses **PyPI Trusted Publishing** (GitHub OIDC) — no long-lived PyPI API token in GitHub.

Releases upload **compiled wheels only** (Cython native extensions). No source tarball is published.

Wheels contain **no bundled secrets** (no Telegram tokens, chat IDs, or Taostats API keys). End users supply all credentials via `install` or their local `.env`.

## One-time setup

### 1. PyPI account

- Create account at [pypi.org](https://pypi.org)
- Enable **2FA** (Account settings → Add 2FA)

### 2. Trusted publisher (before first upload)

PyPI → **Account settings** → **Publishing** → **Add a new pending publisher**

| Field | Value |
|-------|--------|
| PyPI project name | `bittensor-burn-message` |
| Owner | your GitHub username or org |
| Repository name | this repo name |
| Workflow name | `build-wheels.yml` |
| Environment name | *(leave blank)* |

The first successful upload creates the project on PyPI.

## Build wheels in CI (test — no PyPI upload)

1. Push workflow to GitHub.
2. **Actions** → **Build wheels** → **Run workflow**
3. Leave **Upload compiled wheels to PyPI** **unchecked**
4. When the run finishes, open the run → **Artifacts**:
   - **`wheels-windows-latest`**, **`wheels-ubuntu-latest`**, or **`wheels-macos-latest`** — recommended for end users (one OS, all supported Python versions)
   - **`all-wheels`** — every OS/Python wheel in one zip (for PyPI-style mirrors or admins)

End users do **not** pick a specific `.whl` file; `pip` picks the compatible build.

**Cloned repo (keep wheels in `dist/`):** unzip artifact `.whl` files into `dist/` inside the repo, then from the repo root:

```bash
python scripts/install.py
# or: pip install bittensor-burn-message --no-index --find-links dist
```

**Standalone wheel folder:** unzip the artifact, `cd` into that folder, then:

```bash
pip install bittensor-burn-message --no-index --find-links .
```

Each artifact zip includes **`INSTALL.txt`** with these commands.

Tag pushes (`v*`) also build wheels and publish artifacts only — they do **not** upload to PyPI unless you opt in below.

## Create release tag `v1.0.2`

1. Set `version = "1.0.2"` in `pyproject.toml` (already set for this release).
2. Commit and push:

   ```bash
   git add pyproject.toml README.md
   git commit -m "Release v1.0.2"
   git push origin main
   ```

3. Create an **annotated** tag (recommended) and push it:

   ```bash
   git tag -a v1.0.2 -m "Release v1.0.2"
   git push origin v1.0.2
   ```

   Pushing `v1.0.2` triggers **Build wheels** automatically (see `build-wheels.yml`).

4. On GitHub: **Releases** → **Draft a new release** → select tag **`v1.0.2`** → add release notes → **Publish release**.

5. *(Optional)* Upload to PyPI: **Actions** → **Build wheels** → **Run workflow** → check **Upload compiled wheels to PyPI**.

To retag after a mistake (only if the tag was **not** pushed yet):

```bash
git tag -d v1.0.2
git tag -a v1.0.2 -m "Release v1.0.2"
```

If the tag was already pushed, delete it on GitHub first or use a new patch version (e.g. `v1.0.3`).

## Release to PyPI

CI builds platform wheels on Windows, Linux, and macOS (Python 3.9–3.14) and uploads **all** `*.whl` files.

1. Bump `version` in `pyproject.toml` and commit
2. **Actions** → **Build wheels** → **Run workflow**
3. Check **Upload compiled wheels to PyPI**
4. Run

Requires the [trusted publisher](#2-trusted-publisher-before-first-upload) configured on PyPI.

## Local build (optional)

```bash
python scripts/build_wheel.py --local
python scripts/install.py
# twine upload dist/*.whl
```

For all platforms locally, use cibuildwheel (Docker on Linux recommended):

```bash
python scripts/build_wheel.py
```

Production upload is via CI + Trusted Publishing.

## Verify

```bash
pip install bittensor-burn-message
bittensor-burn-message status
```
