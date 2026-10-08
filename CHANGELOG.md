# Changelog

Repository-level changes -- CI, release tooling, documentation -- are
documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Each chart is versioned and released on its own. chart-releaser tags every
release `<chart>-<version>` (for example `sglang-0.8.6`) and publishes it, with
its notes, on the
[GitHub Releases page](https://github.com/modelsphere/helm-charts/releases);
the chart history is there and in `git log charts/<chart>`, not in this file.

## [Unreleased]

### Added
- CI on every pull request and push to `main`: `helm lint --strict` and a
  `helm template` render of every chart, and a gate for the license text and
  committed credentials.
- Dependabot for the GitHub Actions.
- `NOTICE` and this changelog.
- CI fails a pull request that changes a chart's templates, `values.yaml`,
  `values.schema.json` or vendored subcharts without raising its `Chart.yaml`
  version (`hack/check-chart-version.sh`). Such a change would otherwise merge
  and never be published, because release.yml skips versions already released.

### Changed
- GitHub Actions in `check-images.yml` and `release.yml` pinned to commit SHAs.
- README names the project ModelSphere.

[Unreleased]: https://github.com/modelsphere/helm-charts/commits/main
