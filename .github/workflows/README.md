# GitHub Actions Workflows

This directory contains CI/CD workflows for automated testing and quality checks.

## Workflows

### `swift-tests.yml` - Swift Testing & Linting

**Triggers:**
- Pull requests to `main`
- Pushes to `main`
- Only when macOS code changes (`macos/**`)

**Jobs:**

#### 1. `test` - Swift Unit & Integration Tests
- Runs on: macOS 14
- Xcode: 15.2
- Steps:
  - ✅ Checkout code
  - ✅ Setup Xcode
  - ✅ Cache Swift packages (for faster builds)
  - ✅ Resolve dependencies
  - ✅ Build project
  - ✅ Run all tests (`swift test`)
  - ✅ Upload test results as artifacts

**Expected**: All tests should pass (currently 58/61 tests passing)

#### 2. `lint` - SwiftLint Code Quality
- Runs on: macOS 14
- Steps:
  - ✅ Install SwiftLint
  - ✅ Run SwiftLint on all Swift code
  - ✅ Upload linting results

**Expected**: 0 violations (we follow strict Swift style guidelines)

#### 3. `status-check` - Overall CI Status
- Runs after test + lint complete
- Reports overall pass/fail
- **Required status check** for merging PRs

## Test Results

Test results are visible in:
- **PR Checks**: GitHub shows pass/fail on PR
- **Job Summary**: Click workflow run → See test summary
- **Artifacts**: Download full test output (retained 30 days)

## Performance

**Typical run times:**
- First run (no cache): ~5-7 minutes
- Subsequent runs (cached): ~2-3 minutes

**Caching:**
- Swift package dependencies cached
- Significantly faster subsequent builds

## Configuration

### Branch Protection Rules (Recommended)

Set these in GitHub Settings → Branches → main:

**Required status checks:**
- ✅ `Run Swift Tests`
- ✅ `SwiftLint`

**Other rules:**
- ✅ Require pull request reviews: 1
- ✅ Require status checks to pass
- ✅ Require branches to be up to date
- ⬜ Require conversation resolution (optional)

### Workflow Permissions

Default permissions are sufficient. Workflows can:
- Read code
- Write job summaries
- Upload artifacts

## Monitoring

### View Workflow Runs

```bash
# Via GitHub CLI
gh run list --workflow=swift-tests.yml

# View specific run
gh run view <run-id>

# Watch live
gh run watch
```

### Re-run Failed Workflows

From GitHub UI or CLI:
```bash
gh run rerun <run-id>
```

## Troubleshooting

### Tests Fail in CI but Pass Locally

**Common Causes:**
1. **Xcode version mismatch**
   - Local: Check with `xcodebuild -version`
   - CI: Currently using Xcode 15.2
   - Fix: Update workflow or local Xcode

2. **Missing dependencies**
   - Check `Package.resolved` is committed
   - Ensure all dependencies in `Package.swift`

3. **Environment differences**
   - CI runs in clean environment
   - Check for hardcoded paths
   - Use `FileManager.default.homeDirectoryForCurrentUser`

### Cache Issues

Clear cache by:
1. Go to repo Settings → Actions → Caches
2. Delete `macos-spm-*` caches
3. Re-run workflow

Or update cache key in workflow:
```yaml
key: ${{ runner.os }}-spm-v2-${{ hashFiles('**/Package.resolved') }}
```

### SwiftLint Failures

**Local check:**
```bash
cd macos
swiftlint
```

**Auto-fix:**
```bash
swiftlint --fix
```

## Future Enhancements

Potential additions:

- [ ] **Code Coverage**: Generate coverage reports
- [ ] **Terraform Validation**: Validate infrastructure code
- [ ] **Lambda Tests**: Test Python Lambda functions
- [ ] **Security Scanning**: Dependency vulnerability checks
- [ ] **Performance Tests**: Track test execution time
- [ ] **Nightly Builds**: Run comprehensive tests daily
- [ ] **Deploy Workflows**: Auto-deploy to dev/staging

## Cost

GitHub Actions usage:
- **Private repos**: Free for 2,000 minutes/month
- **macOS runners**: 10x multiplier (5 min = 50 min usage)
- **Typical cost**: ~100-150 minutes/month (well within free tier)

## Resources

- [GitHub Actions Docs](https://docs.github.com/en/actions)
- [Swift on GitHub Actions](https://github.com/actions/starter-workflows/blob/main/ci/swift.yml)
- [SwiftLint GitHub Action](https://github.com/norio-nomura/action-swiftlint)

---

*Last Updated: 2025-11-12*
