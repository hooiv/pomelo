# Pomelo

Pomelo is a Chromium-based Android browser. The discontinued Kiwi Browser is the inspiration for the kind of browser it aims to be; Pomelo is its own project.

This repository does not contain the Chromium source tree. It pins one upstream tag and, later, an ordered patch series applied on top of a fresh checkout. Milestone 1 is only a reproducible **stock** build: `chrome_public_apk`, arm64, release, no Google API keys, and no functional patches.

The APK installs as `org.chromium.chrome`, signed with Chromium's public debug key. It can sit beside Google Chrome. It has no Play services, sign-in, or sync.

## Milestone 1

- Tag in [`CHROMIUM_VERSION`](CHROMIUM_VERSION): **158.0.8127.43**
- [Chromium Dash](https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Android&milestone=158) lists that as the newest Android Stable release on milestone 158 (previous version 158.0.8127.42), read 2026-11-22.
- The [Chrome Releases blog](https://chromereleases.googleblog.com/2026/11/chrome-for-android-update_0281314271.html) on 2026-11-17 announced 158.0.8127.42. Dash has one newer point release, and the git tag [`158.0.8127.43`](https://chromium.googlesource.com/chromium/src.git/+/refs/tags/158.0.8127.43) exists. Higher 158 tags exist in git; they are not the Android Stable channel release.
- [`args.gn`](args.gn): `target_os = "android"`, `target_cpu = "arm64"`, `is_debug = false`, `symbol_level = 0`. `is_desktop_android` is explicitly false.
- [`patches/series`](patches/series) is a placeholder. [`scripts/apply-patches.sh`](scripts/apply-patches.sh) applies it in order and succeeds when every line is a comment.

## Roadmap

**v1.** Desktop-Android extensions, Manifest V2, CRX install, an on-device DevTools console, a bottom address bar, and night mode. The extension work is what turns `is_desktop_android` on.

**v2.** Video downloader and resource sniffer, floating video, a built-in ad blocker, and userscripts.

**v3.** Docked DevTools, sessions, and a task manager.

## How CI works

A stock Android build does not finish inside one GitHub-hosted job. Jobs on `ubuntu-24.04` are killed at 6 hours, so [`.github/workflows/chain.yml`](.github/workflows/chain.yml) runs up to **12 stages**. Each stage is one job in [`.github/workflows/stage.yml`](.github/workflows/stage.yml):

1. Free disk space (preinstalled SDKs, toolchains, and Docker images) and add an 8 GB swapfile.
2. Fetch the pinned tag with Android dependencies and **no git history**.
3. Apply `patches/series` (a no-op today).
4. Restore `out/arm64` from the previous stage's checkpoint, if there is one.
5. Set every source file, except `src/out`, to `2000-01-01T00:00:00Z`, so the restored build directory is still newer than its inputs and ninja resumes.
6. Run `autoninja` on `chrome_public_apk` until 35 minutes before a 330-minute budget measured from the start of the job. The job timeout is 358 minutes. A clean timeout exits 124 and is not a failure.
7. If the APK linked, publish it to a GitHub Release and delete the checkpoint. Otherwise pack `out/arm64` and hand it to the next stage.

[`retry.yml`](.github/workflows/retry.yml) reruns the failed jobs of a `build` run from the last day, up to three attempts, when that run finishes and again hourly. A rerun keeps the previous stage's checkpoint. The hourly run does not start a new build.

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

`out/arm64` has to move from one runner to the next. In that reference run the stage-1 arm64 tree was **5.40 GiB** uncompressed and **981 MiB** after `zstd -3` (17.73%). The uploaded artifact was **1,028,616,180 bytes**.

GitHub Free includes **500 MB** of Actions artifact storage, shared with GitHub Packages, and a hard cap of **10 GB per artifact**. Public repositories do not pay for standard runner minutes. Artifact storage is not included in that exemption: past 500 MB, GitHub bills GB-hours unless the account budget is set to stop usage, in which case the upload fails. Splitting a checkpoint does not shrink the total. It only keeps each artifact under the 10 GB cap.

Pomelo therefore has two backends:

| Backend | When | What it does |
| --- | --- | --- |
| GitHub artifacts | Default, when the S3 secrets below are unset | One artifact named `pomelo-out-<version>-arm64-<stage>`, retention **1 day**, `overwrite: true`, compression level 0 because the payload is already zstd. If a checkpoint is larger than 8 GiB it is split into 2 GiB parts, each its own artifact. After the next stage has uploaded its own checkpoint, the previous one is deleted. After the APK is published, every checkpoint artifact for that version is deleted. |
| S3-compatible bucket | Optional. Intended for a free account | Parts are uploaded under a new generation key, and a `LATEST` pointer is written last. A failed upload leaves the previous generation readable. Old generations are deleted after the pointer moves. Cloudflare R2's free tier (10 GB storage, no egress fee) holds the ~1 GB checkpoint measured above, including a brief second copy during the handoff. |

Use the S3 backend if the account must stay inside the free quota. The GitHub-artifact backend matches the reference pipeline and needs no secrets, and it will sit above the 500 MB allowance for as long as the checkpoint exists. One day of a 1 GB artifact is a small overage if billing is enabled, and a failed upload if a $0 budget blocks it.

sccache is a separate optional cache for patch releases of a milestone that was already built. A full Chromium compile cache is many gigabytes. Do not point it at the same 10 GB free bucket as the checkpoint.

## Start the first build

The build workflow does not run on push. After this workflow file is on the default branch:

1. Open **Actions → build → Run workflow**. Leave the version empty to use `CHROMIUM_VERSION`.
2. Or from a checkout of that branch:

```sh
gh workflow run build.yml --repo hooiv/pomelo
```

Nothing else is required. The optional settings below are unset on a fresh repository, so the run uses GitHub artifacts.

Watch the run. Stage 1 spends roughly half an hour fetching, then compiles until the time budget. If it stops with "build time budget" and uploads a checkpoint, stage 2 starts on its own. The release is tagged `v<version>` and the asset is `pomelo-<version>-arm64.apk`.

`workflow_dispatch` is registered from the default branch. A pull request that only *adds* the workflow cannot be started until that file is on `main`.

## Optional secrets and variables

All of these are optional.

| Name | Where | Purpose |
| --- | --- | --- |
| `CHECKPOINT_S3_BUCKET` | variable or secret | Bucket name. Turns on the S3 backend. |
| `CHECKPOINT_S3_ENDPOINT` | variable or secret | For Cloudflare R2: `https://<accountid>.r2.cloudflarestorage.com` |
| `CHECKPOINT_S3_REGION` | variable or secret | Defaults to `auto`, which is what R2 expects. |
| `CHECKPOINT_S3_ACCESS_KEY_ID` | secret | Access key. |
| `CHECKPOINT_S3_SECRET_ACCESS_KEY` | secret | Secret key. |
| `SCCACHE_BUCKET` | variable | sccache bucket. Off unless this and the endpoint are both set. |
| `SCCACHE_REGION` | variable | sccache region. |
| `SCCACHE_ENDPOINT` | secret | sccache S3 endpoint. |
| `SCCACHE_ACCESS_KEY` | secret | sccache access key. |
| `SCCACHE_SECRET_KEY` | secret | sccache secret key. |

The S3 backend is used only when bucket, endpoint, and both keys are non-empty. AWS CLI is already on the GitHub-hosted image. Requests set checksum calculation to `when_required` so current AWS CLI builds can talk to R2.

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

**Artifact quota.** The measured checkpoint is ~981 MB, about twice the free 500 MB allowance. Expect either a small storage charge or a rejected upload when a budget stops overage. Retention is one day, and a finished build deletes its checkpoint. Two stages can briefly keep the previous checkpoint and the new one.

**R2 free tier.** 10 GB is enough for the checkpoint measured here. It is not enough for that checkpoint plus a full sccache. If a later stage's `out/` compresses past ~5 GB, holding the old and new copies at once can fill a 10 GB bucket; the old generation is deleted only after the new one is uploaded.

**Time.** Plan on most of a day of runner time. A lost runner or a network error during `gclient sync` fails the stage; `retry.yml` reruns it from the last checkpoint, up to three attempts in a day.

**Link memory.** 16 GB plus 8 GB of swap is what the reference pipeline uses. A link that gets `SIGKILL` from the OOM killer fails the stage instead of checkpointing. Only a timeout exit of 124 is resumed.

## License

This repository is [BSD-3-Clause](LICENSE). Scripts adapted from holtdroid/chromium-builds remain under [Apache-2.0](NOTICE). The Chromium tree fetched at build time keeps Chromium's own licenses. The build parses proprietary media formats and leaves decoding to Android's MediaCodec; whether that needs a patent license where you are is for you to judge.
