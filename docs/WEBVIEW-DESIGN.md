# QOS WebView Design

**Status:** Design only.
**Goal:** A `qos-webview` command that launches a Chromium-based web app
window with isolated profile data, on Wayland, with no shell chrome.

This is the honest interpretation of the "System WebView" requirement
in `docs/WORKLOAD-PROFILES-GUI-GAMING-K8S.md` §2.3. The original doc
implies an Android-style shared rendering engine with a zygote-style
preforked process model. That is **not** what we will build first.

See review §2.7.

---

## 1. What we build first (Tauri-grade)

A thin wrapper:

```
qos-webview --app https://example.app \
            --profile-dir ~/.local/share/qos-webview/example.app \
            --title "Example"
```

Implementation: shell script that exec's chromium with the right
flags. No long-running engine process. Each app launch is an
independent chromium tree.

Flags:

| Flag | Effect |
| --- | --- |
| `--ozone-platform=wayland` | Native Wayland rendering |
| `--enable-features=UseOzonePlatform` | Required for the above |
| `--app=<url>` | Borderless window, no tab bar |
| `--user-data-dir=<path>` | Per-app data isolation |
| `--no-first-run` | Skip Chromium onboarding |
| `--disable-features=TranslateUI` | Cosmetic |

## 2. What we are explicitly **not** building yet

- A zygote-style preforked engine shared across apps. Chromium already
  does process sharing within a profile tree; cross-profile sharing
  via custom zygote requires patching Chromium, which is a no.
- A "system" WebView in the Android sense (a content provider apps
  link against). That is an Android architecture; on Linux the
  equivalent is just `chromium --app`.
- A WebKit fallback. Pick one engine, support it, move on.

## 3. RAM cost (be honest)

- First instance: ~150MB RSS.
- Each additional app: ~60-80MB (Chromium shares some text pages
  across processes via the kernel page cache; not via our wrapper).
- Excluded from `server` and `k8s` profiles entirely.

## 4. Where it fits

- `desktop` profile: `chromium` + `qos-webview` wrapper installed.
- `gaming` profile: inherits from `desktop`.
- Add `qos webview <url>` subcommand to the CLI router as a discovery
  shortcut.

## 5. Sequencing

1. Land `chromium` package in the `desktop` profile in `qos.yaml`.
2. Write the `scripts/qos-webview.sh` wrapper.
3. Install it into the rootfs in `install-services.sh` (guarded so it
   only goes in when the profile is desktop/gaming).
4. Add a `.desktop` file so it can be a default browser handler for
   `x-scheme-handler/qos-app://`.

## 6. Measuring before optimizing

If, after shipping the wrapper, app launch time or RAM cost is the
top user complaint, *then* investigate:

- Chromium `--single-process` (tradeoffs: security, stability).
- A persistent background `--remote-debugging-port` process that we
  reuse across launches.
- KSM (off by default; `RAM-MINIMIZATION-GUIDE.md` recommends keeping
  it off).

Do not pre-emptively engineer a zygote. The review §2.7 is clear:
"on modern Chromium with kernel-side KSM disabled, the gain is
smaller than the doc claims."
