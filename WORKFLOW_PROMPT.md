# Assignment 8: aesdchar driver + aesdsocket on /dev/aesdchar

This one is split into two runs because I have to push in between. Run 1 writes the driver and the aesdsocket
changes and tests them in QEMU. Run 2 puts it all into Buildroot and runs the full test.

The hard rules (no pushing, commit message style, one QEMU at a time, how to wait on builds) are in
`~/AESD/.claude/PROJECT.md`. I'm not repeating them here. When you hand work to someone, point them at the
section of this file they own instead of copying it into their prompt.

## Where things are right now
I checked all of this on 2026-10-19, so you don't need to survey it again.

- Everything runs in WSL under `~/AESD`. Get my GitHub username with `gh api user -q .login`. gh is logged in and
  git uses the WSL ssh key.
- There's no global git identity in WSL. Commit like this:
  `git -c user.name="$(git log -1 --format=%an)" -c user.email="$(git log -1 --format=%ae)" commit ...`
- Don't try to build or load kernel modules on the host. WSL has no kernel headers. All driver testing is in QEMU.
- A3 repo (`~/AESD/assignment-3-<username>`) is set up and clean. The assignment8 base is merged (`a9952cc`),
  .gitignore covers the kbuild output (`533e571`), and `conf/assignment.txt` is `assignment8`.
  `aesd-char-driver/` has the template files (`main.c`, `aesdchar.h`, `Makefile`, `aesdchar_load`,
  `aesdchar_unload`) and my circular buffer from assignment 7, which the merge didn't touch.
- `server/aesdsocket.c` has `#define DATA_FILE "/var/tmp/aesdsocketdata"` around line 70. It already opens the file
  fresh for every append and every read back. It also has a timestamp thread and deletes the file on exit. The
  Makefile uses `CFLAGS ?= -g` and always adds `-Wall -Werror -pthread`.
- The A5 folder (`~/AESD/assignment-5-<username>`) is my working copy for A8 and it's set up and clean. origin is
  `cu-ecen-aeld/assignment-8-<username>` and the old origin is now `assignment-5-remote`. The buildroot assignment8
  base is merged (`657caef`, submodules updated) and `conf/assignment.txt` is `assignment8-buildroot`. The base
  still uses the `24-assignment7-buildroot` container in the workflow. Leave that alone.
- That folder already has a full build (`buildroot/output`, 14G), so builds are incremental. Don't clone it
  somewhere else and don't move it, since Buildroot output has absolute paths in it.
  - `base_external/package/aesd-assignments/aesd-assignments.mk` is a generic-package with an ssh SITE (it has to
    stay `git@`). VERSION is `ad66f56...`. It builds `finder-app` and `server` and installs `S99aesdsocket` from
    `server/aesdsocket-start-stop`.
  - `base_external/rootfs_overlay/etc/init.d/S98lddmodules` is from A7. Keep it. `BR2_PACKAGE_LDD=y`.
- You can use that build output to test Run 1:
  - kernel tree: `buildroot/output/build/linux-6.18.7` (has `.config` and `Module.symvers`)
  - cross compiler: `buildroot/output/host/bin/aarch64-buildroot-linux-gnu-gcc`
  - `./runqemu.sh` boots it. Log in with `sshpass -p root ssh -p 10022 root@localhost` (scp uses `-P 10022`).
- The template: `main.c` has TODOs in open, release, read, write, init and cleanup, plus `MODULE_AUTHOR`.
  `struct aesd_dev` in `aesdchar.h` only has `cdev`. `aesd_circular_buffer_add_entry()` returns void.
  `aesdchar_load` does `insmod ./aesdchar.ko` if the .ko is next to it, otherwise `modprobe aesdchar`.
- How it gets graded (`assignment-autotest/test/shared/script-helpers`, `validate_aesdchar`): `aesdchar` has to
  show up in `lsmod` after boot. Before drivertest and again before sockettest it does `rmmod aesdchar` and then
  `modprobe aesdchar`. So the module has to be modprobe-able (kernel-module infra), and aesdsocket can't keep
  `/dev/aesdchar` open while it's idle. `drivertest.sh` gets copied to `/usr/bin` in QEMU, and sockettest is the
  assignment 5 script.

---

# Run 1: driver and aesdsocket in the A3 repo, tested in QEMU (hierarchy)

## How to split it up
- Keep it flat. Director sends work straight to workers, no manager. Skip the intake survey, the stuff above is
  already checked.
- R1-1 and R1-2 can run at the same time since they're in different folders. Then R1-3, then R1-4. Only R1-4
  touches QEMU.
- None of this takes more than a few minutes. Please don't add host build checks or extra stop conditions unless
  you have an actual reason.

## R1-1: the driver (worker, only `aesd-char-driver/`)
I already decided how this should work, just implement it:
- `aesdchar.h`: add `struct aesd_circular_buffer buffer`, `struct aesd_buffer_entry partial` (the write that
  hasn't gotten its newline yet) and `struct mutex lock` to `struct aesd_dev`. Include `aesd-circular-buffer.h`
  and `<linux/mutex.h>`.
- open sets `filp->private_data = container_of(inode->i_cdev, struct aesd_dev, cdev)`. release doesn't need to do
  anything.
- read: take the lock with `mutex_lock_interruptible` (return `-ERESTARTSYS` if it fails) and find the entry for
  `*f_pos`. If there isn't one, return 0. Otherwise copy `min(count, entry->size - offset)` bytes with
  `copy_to_user` (`-EFAULT` if it fails), move `*f_pos` forward and return how many bytes you copied.
- write: if `count` is 0 just return 0. Under the lock, `krealloc` partial to `size + count` (`-ENOMEM`) and
  `copy_from_user` onto the end of it (`-EFAULT`). If the new bytes have a `'\n'` in them, then if the buffer is
  full `kfree` the entry at `in_offs` first, add partial to the buffer and reset partial. Return `count`. Ignore
  offsets for writes.
- init: `aesd_circular_buffer_init` and `mutex_init` before `aesd_setup_cdev`. cleanup: after `cdev_del`, `kfree`
  every entry (`AESD_CIRCULAR_BUFFER_FOREACH`) and `partial.buffptr`.
- Put my GitHub username in `MODULE_AUTHOR` and comment out `#define AESD_DEBUG 1`.
- Match the style that's already in the file. Max line length 120.
- It has to cross-build with zero warnings (this is one command, `<A5>` is the A5 folder):
  `make -C aesd-char-driver KERNELDIR=<A5>/buildroot/output/build/linux-6.18.7 ARCH=arm64`
  `CROSS_COMPILE=<A5>/buildroot/output/host/bin/aarch64-buildroot-linux-gnu-`

## R1-2: aesdsocket (worker, only `server/`)
- Add `#ifndef USE_AESD_CHAR_DEVICE` / `#define USE_AESD_CHAR_DEVICE 1`. When it's on, `DATA_FILE` is
  `/dev/aesdchar`. When it's off it stays `/var/tmp/aesdsocketdata`.
- When it's on: no timestamp thread, don't create or truncate the file at startup, and never delete it on exit.
  Keep opening and closing it per packet so the fd is never held open while idle. Update the comment at the top
  of the file to match.
- Optional Makefile override: `USE_AESD_CHAR_DEVICE ?= 1`, passed as `-DUSE_AESD_CHAR_DEVICE=$(USE_AESD_CHAR_DEVICE)`.
- It has to build with zero warnings both ways, with the normal build and with the Yocto-like flags in PROJECT.md.
  `make -C server USE_AESD_CHAR_DEVICE=0` still has to pass the standalone socket test from PROJECT.md.

## R1-3: review (worker, read only)
Go through `main.c` and `aesdchar.h` line by line against R1-1. Make sure every path unlocks, nothing leaks on
the `-EFAULT` path, on overwrite or at unload, `*f_pos` moves forward, and partial writes get appended. Check
R1-2 against its list too. Just report what you find. The Director decides what gets fixed, and there's only
one fix round.

## R1-4: test in QEMU and commit (worker)
1. Boot the A5 image with `./runqemu.sh`, detached and logging to a file. Do the QEMU and port checks from
   PROJECT.md first.
2. Copy `aesdchar.ko`, `aesdchar_load`, `aesdchar_unload`, `assignment-autotest/test/assignment8/drivertest.sh`
   and a cross-built aesdsocket into `/tmp` on the target. Build aesdsocket with
   `make -C server CC=<A5>/buildroot/output/host/bin/aarch64-buildroot-linux-gnu-gcc` and `make clean` after.
   `/tmp/aesdchar_load` should pick up the local .ko.
3. In QEMU, load the driver and run `drivertest.sh`. It has to exit 0 with all three blocks matching. Then
   `/etc/init.d/S99aesdsocket stop`, start `/tmp/aesdsocket -d`, and run
   `assignment-autotest/test/assignment5/sockettest.sh` from the host (port 9000). That has to pass too.
4. Check the grader's rmmod path. Stop aesdsocket and make sure `rmmod aesdchar` works. Then run
   `/tmp/aesdchar_load`, start aesdsocket again and make sure `rmmod aesdchar` still works while it's idle.
5. Shut QEMU down and clean any build output out of the A3 tree. The scp changed the image's rootfs, but that's
   fine because Run 2 rebuilds it.
6. Commit in the A3 repo, something like "assignment 8 complete: aesdchar driver and aesdsocket on /dev/aesdchar".

## When Run 1 is done
Give me the commit hashes, the drivertest and sockettest output, and what the review found and what got fixed.
Then stop. I push the A3 repo before Run 2.

---

# Run 2: Buildroot in the A5 folder (solo, no hierarchy)

Before this starts I'll have pushed the A3 repo. The A5 folder is already set up (see above).

1. In `aesd-assignments.mk`:
   - set `VERSION` to the Run 1 commit hash. It should match `git -C <A3> ls-remote origin main`.
   - add `AESD_ASSIGNMENTS_MODULE_SUBDIRS = aesd-char-driver` and put `$(eval $(kernel-module))` before
     `$(eval $(generic-package))`.
   - install `aesdchar_load` and `aesdchar_unload` to `/usr/bin`, and a new `S97aesdchar` to `/etc/init.d` (start
     runs `aesdchar_load`, stop runs `aesdchar_unload`). Put `S97aesdchar` in the package folder next to
     `finder-test.sh`.
   - if kernel-module infra needs it, add `depends on BR2_LINUX_KERNEL` to `Config.in` like the `ldd` package does.
   Leave everything else alone.
2. Run `./build.sh`. It's incremental. Start it detached with a log and an exit code marker, and wait with bounded
   waits.
3. Run `./full-test.sh` (it builds, boots QEMU and runs the grader). It has to end with "complete with success"
   and no validation errors. If it fails, report it, don't keep retrying. You can fix it once if it's clearly
   something in the files from step 1.
4. Commit using the course message style.

## When Run 2 is done
Give me the commit hashes, the `full-test.sh` summary and which files changed.

---

## Stuff I do myself
- After Run 1: push the A3 repo.
- After Run 2: push the A5 folder's `main` to `origin` (the A8 repo).
  Tag `assignment-8-complete` in the A3 and A8 repos and push the tags.
