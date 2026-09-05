# Changelog

## [0.4.0](https://github.com/raulgg/airpods-control/compare/v0.3.0...v0.4.0) (2026-09-05)


### Features

* **cli:** consolidate result and exit-code semantics ([#61](https://github.com/raulgg/airpods-control/issues/61)) ([ce98226](https://github.com/raulgg/airpods-control/commit/ce982265df7f826898e01d6c0daa953454d1cdb3))
* **status:** report AirPods ear placement ([#58](https://github.com/raulgg/airpods-control/issues/58)) ([4159037](https://github.com/raulgg/airpods-control/commit/4159037e46955989f89a4317e264046c82051b13))


### Bug Fixes

* **cli:** preserve discovery failures and denial TTL ([#68](https://github.com/raulgg/airpods-control/issues/68)) ([4a80204](https://github.com/raulgg/airpods-control/commit/4a80204fb66645b69cf961d93d3a5d86ff84d486))
* probe support-report listening modes Off last ([#91](https://github.com/raulgg/airpods-control/issues/91)) ([95c17ab](https://github.com/raulgg/airpods-control/commit/95c17ab1e2cc1e4dc3cbf4faf6d4b524f3af9add))


### Performance Improvements

* **cli:** defer HAL inventory until AV cannot serve ([#97](https://github.com/raulgg/airpods-control/issues/97)) ([762ffb8](https://github.com/raulgg/airpods-control/commit/762ffb8031cb2ae1071e7fd0de22e806493085f1))

## [0.3.0](https://github.com/raulgg/airpods-control/compare/v0.2.1...v0.3.0) (2026-08-27)


### Features

* control listening modes on unselected AirPods ([#31](https://github.com/raulgg/airpods-control/issues/31)) ([79cbd3a](https://github.com/raulgg/airpods-control/commit/79cbd3a3e8d2ed3b7d5defc5db45e1021d2ea0ff))
* verify AirPods Pro 2 (Lightning) compatibility ([#39](https://github.com/raulgg/airpods-control/issues/39)) ([d0e0358](https://github.com/raulgg/airpods-control/commit/d0e0358a71ceb5db3e3538d339535bd886094bac)), closes [#34](https://github.com/raulgg/airpods-control/issues/34)


### Bug Fixes

* clear stale Allow Off cache after a no-op ([#48](https://github.com/raulgg/airpods-control/issues/48)) ([8673a71](https://github.com/raulgg/airpods-control/commit/8673a7149e001942be7e4e1d4145cd491087f0d2))
* make Allow Off cache safe across stale reads ([#32](https://github.com/raulgg/airpods-control/issues/32)) ([9bd42d8](https://github.com/raulgg/airpods-control/commit/9bd42d8741620afcb6b14eb136d56ad0eb4ff246))

## Changelog

Release Please maintains this file from Conventional Commit titles merged after
`v0.2.1`. Earlier release notes remain available on the
[GitHub Releases](https://github.com/raulgg/airpods-control/releases) page.
