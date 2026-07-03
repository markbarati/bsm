# Publish BSM Community to a public GitHub repository

## 1. Run the safety checks

```bash
./scripts/public-release-check.sh
```

Review the repository for secrets that generic scanners may not recognize:

```bash
git grep -nEi 'real-domain|real-email|real-public-ip|company-name'
```

## 2. Initialize and publish

Using GitHub CLI:

```bash
git init
git add .
git commit -m "Initial public release of BSM Community"
git branch -M main
gh repo create bsm-community --public --source=. --remote=origin --push
```

Or create an empty public repository in the GitHub website, then:

```bash
git init
git add .
git commit -m "Initial public release of BSM Community"
git branch -M main
git remote add origin https://github.com/YOUR-USER/bsm-community.git
git push -u origin main
```

## 3. Turn on repository security

In GitHub, open **Settings → Code security** and verify that Secret Scanning and Push Protection are enabled. Never depend on scanning as the only control; keep secrets out of Git history from the start.

## 4. Create a release

```bash
git tag -a v0.2.0 -m "BSM Community 0.2.0"
git push origin v0.2.0
```

The included release workflow validates the source, creates the archives, the one-file bootstrap, the update package, and SHA-256 checksums, then attaches them to a GitHub Release.

## 5. Installation command after publishing

```bash
git clone https://github.com/YOUR-USER/bsm-community.git
cd bsm-community
sudo ./bootstrap.sh
```

For a pinned release, download the one-file bootstrap from Releases, verify its checksum, and execute it locally.
