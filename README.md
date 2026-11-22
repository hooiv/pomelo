# Pomelo

Pomelo is a Chromium-based Android browser. The discontinued Kiwi Browser is the inspiration for the kind of browser it aims to be; Pomelo is its own project.

This repository does not contain the Chromium source tree. It pins one upstream tag and applies [`patches/series`](patches/series) on top of a fresh checkout. The APK is `chrome_public_apk` for arm64, release, with no Google API keys. Its name is Pomelo and its id is `io.github.hooiv.pomelo`, so it installs beside Chrome. It is signed with Chromium's public debug key and has no Play services, sign-in, or sync.

## This build

- Tag in [`CHROMIUM_VERSION`](CHROMIUM_VERSION): **158.0.8127.43**
- [Chromium Dash](https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&milestone=158) lists that as the newest Android Stable release on milestone 158 (previous version 158.0.8127.42), read 2026-11-22.
- The [Chrome Releases blog](https://chromereleases.googleblog.com/2026/11/chrome-for-android-update_0281314271.html) on 2026-11-17 announced 158.0.8127.42. Dash has one newer point release, and the git tag [`158.0.8127.43`](https://chromium.googlesource.com/chromium/src.git/+/refs/tags/158.0.8127.43) exists. Higher 158 tags exist in git; they are not the Android Stable channel release.
- [`args.gn`](args.gn): `target_os = "android"`, `target_cpu = "arm64"`, `is_debug = false`, `symbol_level = 0`, `is_desktop_android = true`, package `io.github.hooiv.pomelo`.
- [`patches/series`](patches/series) is applied in order by [`scripts/apply-patches.sh`](scripts/apply-patches.sh). A patch that does not apply stops the build.

## Roadmap

**v1, in [`patches/series`](patches/series), not yet proven on a device.** Desktop-Android extensions, Manifest V2, unpacked and sideloaded CRX install, a desktop user agent on the Chrome Web Store, on-device DevTools (Developer tools and Inspect) on phones, the address bar on the bottom with a setting to move it, and website darkening when the app theme is dark. A device build still has to confirm the patches compile and the UI behaves.

| Patch | What it changes |
| --- | --- |
| `0001-rebrand-pomelo.patch` | Launcher and widget titles. The package id is `chrome_public_manifest_package` in `args.gn`. |
| `0002-desktop-android-extensions.patch` | MV2, extension schemas, the phone extensions menu, unpacked install, and the Web Store user agent. Adapted from afterbird's M151 series. |
| `0003-on-device-devtools.patch` | DevTools feature on, phone form factor allowed, Inspect menu item, phone viewport. |
| `0004-bottom-address-bar.patch` | `AndroidBottomBar` on, default position bottom. Settings still offers top. |
| `0005-night-mode.patch` | Theme setting can darken websites, and that default is allow while the UI is dark. |

**v2.** Video downloader and resource sniffer, floating video, a built-in ad blocker, and userscripts.

**v3.** Docked DevTools, sessions, and a task manager.

## How CI works

The Android build does not finish inside one GitHub-hosted job. Jobs on `ubuntu-24.04` are killed at 6 hours, so [`.github/workflows/chain.yml`](.github/workflows/chain.yml) runs up to **12 stages**. Each stage is one job in [`.github/workflows/stage.yml`](.github/workflows/stage.yml):

1. Free disk space (preinstalled SDKs, toolchains, and Docker images) and add an 8 GB swapfile.
2. Fetch the pinned tag with Android dependencies and **no git history**.
3. Apply `patches/series`. A reject stops the job.
4. Restore `out/arm64` from the previous stage's checkpoint, if there is one.
5. Set every source file, except `src/out`, to `2000-01-01T00:00:00Z`, so the restored build directory is still newer than its inputs and ninja resumes.
6. Run `autoninja` on `chrome_public_apk` until 35 minutes before a 330-minute budget measured from the start of the job. The job timeout is 358 minutes. A clean timeout exits 124 and is not a failure.
7. If the APK linked, publish it on `v<version>` and delete the checkpoint prerelease. Otherwise pack `out/arm64` and upload it to `checkpoint-<run_id>` for the next stage.

[`retry.yml`](.github/workflows/retry.yml) reruns the failed jobs of a `build` run from the last day, up to three attempts, when that run finishes and again hourly. A rerun keeps the checkpoint prerelease. The third failure deletes it. The same workflow deletes any `checkpoint-*` release older than two days. It does not start a new build.

The chained-job shape, the disk cleanup, the fixed mtimes, and the time budget are adapted from [holtdroid/chromium-builds](https://github.com/holtdroid/chromium-builds) (Apache-2.0). See [NOTICE](NOTICE).

### How many stages

The workflow allows 12. The only measured build of this exact tag on the same runner class is [holtdroid/chromium-builds run 44578317698](https://github.com/holtdroid/chromium-builds/actions/runs/44578317698) (2026-11-19):

| Stage | arm64 | What it did |
| --- | --- | --- |
| 1 | ran, about 4h 56m | compiled, then checkpointed |
| 2 | ran, about 3h 25m | finished `chrome_public_apk` **and** `system_webview_apk` |
| 3–12 | skipped | |

That arm64 build included WebView, which Pomelo does not build. Two stages is the evidence-based expectation for this tag. It is not a guarantee. x86_64 in that same run needed a third stage; Pomelo does not build x86_64.

### Checkpoint storage

`out/arm64` has to move from one runner to the next. In that reference run the stage-1 arm64 tree was **5.40 GiB** uncompressed and **981 MiB** after `zstd -3` (17.73%). That is already larger than the **500 MB** of Actions artifact storage included with GitHub Free. Artifact storage is billed past that allowance, separately from the free public-runner minutes, and a budget that stops overage rejects the upload.

The default backend is a **GitHub Release**, which is not part of that artifact meter. Each Actions run uses its own prerelease tag `checkpoint-<run_id>`, so two builds do not share assets. `GITHUB_TOKEN` only needs `contents: write`. The zstd stream is split into parts of at most 1900 MiB, under the 2 GiB release-asset limit. A manifest records the sha256 and size of every part. The next stage downloads the parts named by a `LATEST` asset, which is written only after the parts and the manifest are uploaded, and `scripts/checkpoint.sh restore` checks those checksums before it extracts anything.

The checkpoint release is created with `--prerelease` and `--latest=false`, and every upload sets those again. It is not the release GitHub shows as Latest. The browser APK stays on `v<version>`.

The tag and its assets are deleted when:

- the APK release is published (that release is then marked Latest again)
- the stage fails on its third attempt, which is the last automatic retry
- [`retry.yml`](.github/workflows/retry.yml) sees a `checkpoint-*` prerelease published more than two days ago

A failed attempt before the last one keeps the tag, so the rerun can resume.

| Backend | When | Tradeoff |
| --- | --- | --- |
| GitHub Release | Default | Fits a free account without a separate storage bill. Parts must stay under 2 GiB. The tag is a prerelease and is removed when the build finishes or after two days. |
| GitHub artifact | `CHECKPOINT_BACKEND=artifact` | Same handoff the reference pipeline uses. A ~981 MB checkpoint exceeds the free 500 MB allowance for as long as it exists. Retention is one day. |
| S3-compatible bucket | Complete bucket settings, or `CHECKPOINT_BACKEND=s3` | Optional. Useful if you already have a bucket. It is not the default: a bucket without a spend cap can keep accruing, and a full compiler cache does not fit next to the checkpoint on a small free tier. |

sccache is a separate optional cache for later patch releases of a milestone that was already built. Leave it unset for this stock build.

## Start the first build

The build workflow does not run on push. After this workflow file is on the default branch:

1. Open **Actions → build → Run workflow**. Leave the version empty to use `CHROMIUM_VERSION`.
2. Or from a checkout of that branch:

```sh
gh workflow run build.yml --repo hooiv/pomelo
```

Nothing else is required. The optional settings below are unset on a fresh repository, so each stage stores its checkpoint on the prerelease `checkpoint-<run_id>`.

Watch the run. Stage 1 spends roughly half an hour fetching, then compiles until the time budget. If it stops with "build time budget" and uploads a checkpoint, stage 2 starts on its own. The release is tagged `v<version>` and the asset is `pomelo-<version>-arm64.apk`.

`workflow_dispatch` is registered from the default branch. A pull request that only *adds* the workflow cannot be started until that file is on `main`.

## Optional secrets and variables

All of these are optional.

| Name | Where | Purpose |
| --- | --- | --- |
| `CHECKPOINT_BACKEND` | variable | `release` (default), `artifact`, or `s3`. `github` is accepted as an alias for `artifact`. |
| `CHECKPOINT_S3_BUCKET` | variable or secret | Bucket name. With the endpoint and both keys, selects S3 unless `CHECKPOINT_BACKEND` says otherwise. |
| `CHECKPOINT_S3_ENDPOINT` | variable or secret | S3 API endpoint, such as `https://<accountid>.r2.cloudflarestorage.com`. |
| `CHECKPOINT_S3_REGION` | variable or secret | Defaults to `auto`. |
| `CHECKPOINT_S3_ACCESS_KEY_ID` | secret | Access key. |
| `CHECKPOINT_S3_SECRET_ACCESS_KEY` | secret | Secret key. |
| `SCCACHE_BUCKET` | variable | sccache bucket. Off unless this and the endpoint are both set. |
| `SCCACHE_REGION` | variable | sccache region. |
| `SCCACHE_ENDPOINT` | secret | sccache S3 endpoint. |
| `SCCACHE_ACCESS_KEY` | secret | sccache access key. |
| `SCCACHE_SECRET_KEY` | secret | sccache secret key. |

A complete S3 configuration selects that backend on its own. Set `CHECKPOINT_BACKEND=release` to keep release checkpoints even if those values are present. AWS CLI is already on the GitHub-hosted image. Requests set checksum calculation to `when_required` so current AWS CLI builds can talk to S3-compatible endpoints.

## Build locally

x86-64 Linux, 100 GB of disk or more, and 16 GB of RAM or more. The final link wants swap if you are at 16 GB. Depot Tools and the Android build dependencies are installed by the fetch script when `CI=true`; locally, install them yourself after the checkout exists.

```sh
scripts/fetch.sh
./chromium/src/build/install-build-deps.sh --android
scripts/apply-patches.sh
scripts/touch-sources.sh
scripts/build.sh
scripts/package.sh "$(scripts/resolve-version.sh)" dist
```

`scripts/build.sh 3600` stops after an hour with exit 124 and can be run again. The checkout is `./chromium` (gitignored). Changing `args.gn` after `out/arm64/build.ninja` exists requires deleting that directory so `gn gen` runs again.

## Risks

**Disk.** GitHub's runner documentation lists 14 GB of SSD for `ubuntu-24.04`. That is the published guarantee. The reference run on 2026-11-19 saw a 145 GB root filesystem: about 115 GB free after cleanup, 71 GB free after the fetch (the checkout was ~44 GB), and 58 GB free at the end of stage 2. If a runner is actually limited to 14 GB, the fetch cannot succeed. Cleanup cannot create space the disk does not have.

**Checkpoint lifetime.** The default prerelease is deleted when the APK is published and when a run fails for the third time. Anything still tagged `checkpoint-*` after two days is deleted by the hourly retry workflow. Until then the tag is a prerelease and is not Latest. A third-attempt failure throws the checkpoint away, so a later manual rerun fetches and compiles from the start of that stage.

**Artifact quota.** `CHECKPOINT_BACKEND=artifact` stores the same ~981 MB object as an Actions artifact. That is about twice the free 500 MB allowance. Expect a storage charge, or a rejected upload when a budget stops overage.

**S3.** Optional. A bucket with no spend cap can keep billing after the build is gone. The release backend is the one that stays inside GitHub without that meter.

**Time.** Plan on most of a day of runner time. A lost runner or a network error during `gclient sync` fails the stage; `retry.yml` reruns it from the last checkpoint, up to three attempts in a day.

**Link memory.** 16 GB plus 8 GB of swap is what the reference pipeline uses. A link that gets `SIGKILL` from the OOM killer fails the stage instead of checkpointing. Only a timeout exit of 124 is resumed.

## License

This repository is [BSD-3-Clause](LICENSE). Scripts adapted from holtdroid/chromium-builds remain under [Apache-2.0](NOTICE). The Chromium tree fetched at build time keeps Chromium's own licenses. The build parses proprietary media formats and leaves decoding to Android's MediaCodec; whether that needs a patent license where you are is for you to judge.
