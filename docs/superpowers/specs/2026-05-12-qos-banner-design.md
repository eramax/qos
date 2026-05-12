# QOS Login Banner Design

## Goal

Replace Alpine's default login welcome text with a QOS-specific banner that prints on interactive SSH logins.

The banner should show:

- QOS version, generated at `make full` time
- kernel version
- RAM summary
- disk usage summary

The version string must be build-stamped, not runtime-generated.

## Requirements

- The banner must appear only for interactive shells.
- Noninteractive SSH commands must remain quiet.
- The kernel, RAM, and disk values must be read at login time.
- The version string must come from build output produced by `make full`.
- The implementation must not depend on Python.

## Proposed Design

### Build-time version stamp

`make full` writes a version file into the staged rootfs, likely under `/etc/qos/version`.

The file should contain a human-readable build timestamp and, if available, a git revision string.

Example format:

```text
QOS build: 2026-05-12 09:30:41 UTC
Git commit: abcdef1
```

### Login-time banner script

Add a shell script in `/etc/profile.d/` that runs for interactive shells only.

The script reads:

- `/etc/qos/version`
- `uname -r`
- `/proc/meminfo`
- `df -h /`

It prints a compact banner and then exits.

### Login behavior

The script must detect interactive shells and do nothing for:

- SSH command execution
- build scripts
- noninteractive shell invocations

This keeps `ssh root@host command` quiet while still showing the banner on normal login.

## Data Flow

1. Build pipeline generates the version stamp during `make full`.
2. The version stamp is copied into the rootfs.
3. `profile` sources the new banner script on shell startup.
4. The script checks whether the shell is interactive.
5. If interactive, it prints build version plus live system info.

## Testing

Add tests that verify:

- the version file is created during the staged build
- the profile script is installed
- the script is gated to interactive shells only
- the script reads the build version file
- the script reads live kernel, RAM, and disk values

Also verify the resulting image still boots cleanly.

## Out of Scope

- changing the SSH authentication model
- changing the Alpine base MOTD package
- adding a graphical banner
- adding runtime networking logic

