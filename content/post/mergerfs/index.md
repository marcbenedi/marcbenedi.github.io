---
# Documentation: https://docs.hugoblox.com/managing-content/

title: "Pooling per-node scratch storage with mergerfs"
subtitle: ""
summary: "How I glued together the per-node scratch directories of our SLURM cluster into a single, unified mount point — using mergerfs — and an interactive bash script to manage mounts across all nodes from one place."
authors: []
tags: ["Slurm", "mergerfs", "FUSE", "Storage", "Ansible", "Bash"]
categories: []
date: 2025-10-01T11:03:24+02:00
lastmod: 2025-10-01T11:03:24+02:00
featured: false
draft: false

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder.
# Focal points: Smart, Center, TopLeft, Top, TopRight, Left, Right, BottomLeft, Bottom, BottomRight.
image:
  caption: ""
  focal_point: ""
  preview_only: false

# Projects (optional).
#   Associate this post with one or more of your projects.
#   Simply enter your project's folder or file name without extension.
#   E.g. `projects = ["internal-project"]` references `content/project/deep-learning/index.md`.
#   Otherwise, set `projects = []`.
projects: []
---

{{% callout note %}}
**Update — 2026-05-21:** After upgrading one of our nodes to **Ubuntu 24.04** (which packages **mergerfs 2.33**), mounts started failing with `Operation not permitted`. The cause is a packaging bug: the Ubuntu 24.04 `mergerfs` package ships its mount helper `/usr/bin/mergerfs-fusermount` **without the setuid bit**, so when invoked by a normal user it can't ask the kernel to create the FUSE mount.

**⚒️Fix** (as root, once per affected node):

```bash
sudo chmod u+s /usr/bin/mergerfs-fusermount
```

Older Ubuntu 20.04 nodes (mergerfs 2.28) are not affected because that version uses the system's `fusermount3` directly, which already has setuid set. If your nodes boot from a read-only `squashfs` image with an overlay (common for netbooted/live setups), the `chmod` will live in the writable upper layer and survive normal operation, but a reboot from a fresh image will wipe it — bake the setuid bit into the image, or re-apply the `chmod` after each reboot.
{{% /callout %}}

After my [VSCode-on-Slurm post](/post/vscode-slurm/) seemed to land well, here's another small tool that has saved me an embarrassing amount of `cd`-ing around our cluster: **[mergerfs](https://github.com/trapexit/mergerfs)**.

> **TL;DR:** mergerfs is a FUSE filesystem that lets you mount *N* directories as if they were one. I use it to pool the per-node scratch storage on our SLURM cluster into a single tidy mount under my home directory, so I can `ls`, `tail`, and `rsync` across nodes without thinking about which node a file lives on.

📥 **In a hurry?** [Download `cluster_mergerfs.sh`](cluster_mergerfs.sh) — the wrapper script discussed below.

{{< toc >}}

## The problem

Like a lot of academic clusters, ours doesn't have one big shared scratch pool. Each compute node has its own local-ish fast storage:

```
/cluster/node1/<user>/...
/cluster/node2/<user>/...
/cluster/node3/<user>/...
/cluster/node4/<user>/...
```

This is great for IO performance — jobs hit the storage attached to the node they ran on — but bad for the human running them. A single training run that scheduled across multiple nodes leaves logs scattered everywhere. Tailing one log means knowing which node produced it. Backing things up means looping over nodes. Pointing tools (TensorBoard, viewers, scripts) at a single root is impossible.

What I want is a *view*: one path that looks like the union of all those per-node directories, transparently.

That's exactly what mergerfs gives you.

## What mergerfs is (mental model)

mergerfs is a userspace, **policy-driven** union filesystem. You hand it a list of *branches* (existing directories) and a mount point, and it presents the union of those branches at the mount point. Reads transparently fall through to whichever branch has the file; writes get routed to a branch according to a **create policy** you configure.

Crucially, **mergerfs doesn't move data**. Each file still lives on exactly one branch on disk — mergerfs just makes the namespace look unified. If you bypass the mount and look at a branch directly, you still see the real underlying files. That's what makes it safe to bolt on top of an existing setup without migrations.

## Prerequisites

Before any of this works, two things need to be true on **every node** you want to mount on:

1. **`mergerfs` is installed.** It's packaged for most distributions (`apt install mergerfs`, `dnf install mergerfs`, etc.); otherwise grab a release from [the project's GitHub](https://github.com/trapexit/mergerfs/releases). How you push that out is up to you (Ansible, Salt, your distro's image, or just SSH-ing it in) — the important thing is that the binary is there and on `PATH`.
2. **FUSE allows `user_allow_other`.** mergerfs is intended to run as a normal user (don't run it as root), and you'll almost certainly want the merged view to be readable by other tools/users on the box — daemons, jobs running as a different user, root doing backups. That requires `user_allow_other` in `/etc/fuse.conf`:

   ```bash
   # /etc/fuse.conf
   user_allow_other
   ```

   This is a one-time, root-level change per node.

### SSH from where you run the script

The script orchestrates every node by SSHing into it and running a small bash payload on the remote side, so the host you launch it from needs to be able to SSH into every cluster node **without a password prompt**. (When it works on several nodes in parallel it reuses a single shared SSH connection per node via `ControlMaster`/`ControlPersist`, and runs in `BatchMode` so a stalled auth prompt fails fast instead of hanging invisibly.) In practice that means:

- **Key-based auth** set up to all nodes (an `ssh-agent` with your key loaded, or a key without a passphrase). The script doesn't handle interactive password entry — it'll just hang.
- **Hostnames resolvable** by the names that come back from `sinfo` / `scontrol show hostnames`. If your SLURM short hostnames aren't directly DNS-resolvable, add an entry per node in `~/.ssh/config`:

  ```
  Host node1
      HostName node1.cluster.example.org
      User <your-user>
  ```

- **`bash` available on the remote side** (the script runs heredoc'd bash on each node).
- **No host-key prompts on first contact**. Either pre-populate `~/.ssh/known_hosts`, or add `StrictHostKeyChecking=accept-new` in `~/.ssh/config` for your cluster hosts so the first SSH doesn't block waiting for a y/n.

If you can run `ssh <node> hostname` against every node and it just prints the hostname with no prompts, you're set.

## My mergerfs options

Here are the options I mount with, and why each one:

```
cache.files=off,use_ino,func.getattr=newest,
category.create=mfs,moveonenospc=true,
minfreespace=300G,allow_other
```

- **`cache.files=off`** — disable kernel page caching of file content. With networked-ish per-node storage this avoids stale-cache surprises; performance is rarely the bottleneck for what I use the merged view for (browsing logs, rsync).
- **`use_ino`** — preserve the underlying filesystem's inode numbers in the merged view. Tools that compare files by `(dev, ino)` (rsync, tar) behave correctly.
- **`func.getattr=newest`** — if the same path exists on several branches, `stat()` returns the version with the most recent mtime. Handy when a job's log file ends up on multiple nodes.
- **`category.create=mfs`** — *most-free-space* create policy. New files go to whichever branch currently has the most free space. Keeps things naturally balanced.
- **`moveonenospc=true`** — if a write fails with `ENOSPC`, mergerfs will transparently move the file to another branch and retry. Saves a job from dying because the branch it landed on filled up.
- **`minfreespace=300G`** — branches with less than 300 GB free are excluded from new file creation. With ML workloads writing big checkpoints this prevents pathological "write 200 GB onto a branch that had 250 GB and lock everything up" cases.
- **`allow_other`** — combined with `user_allow_other` in `fuse.conf` (above), allows other users on the box to read the mount.

## A script to manage it across the cluster

Mounting one merged view by hand is `mergerfs <opts> /a:/b:/c /mnt`. Doing that across N nodes for M merge sets, and remembering to clean up, gets old fast. So I wrote a small bash tool. It runs as an interactive menu by default, and every action is also available non-interactively through a flag-driven CLI (`mount`, `status`, `unmount`, `kill`, `rsync`, `list`). It can:

- **Mount** any subset of merge sets on any subset of nodes (creates source dirs if missing, refuses to mount if a source is unreachable, replaces stale mounts).
- **Check status** — for each (set, node), show whether it's active, the merged-view `df`, the active mount options, per-source disk usage, and flag any branch below `minfreespace` (so you know mergerfs has stopped writing to it). It also catches **drift** (a live mount whose branches or options no longer match the config), **stale or wedged** mounts, and **stray data** written under a mount point while it was unmounted. Slow probes — file counts and `du -sh` — are gated behind `--counts`/`--sizes`, and `--table` prints a compact one-row-per-node view. Every run ends with a de-duplicated summary and, when relevant, `FAILED`/`WARNINGS` blocks so a problem on one node can't get lost in the scrollback.
- **Unmount** safely (`fusermount -uz`).
- **Kill a wedged mergerfs process** (`kill`) — for when a mount has gone unresponsive: it locates the right `mergerfs` PID by matching the mount point at the *end* of `/proc/<pid>/cmdline` (so a path that appears as a *source* in another mergerfs instance doesn't false-match), `kill -9`s it, then attempts `fusermount -uz`, falling back to `umount -l` if needed.
- **Show rsync commands** — emit ready-to-paste `rsync` lines for migrating each merge set into a single consolidated directory, for the day you outgrow the union view and want to physically merge.
- **Work in parallel** — `-j N` fans the per-node work out concurrently (default is serial); each node's output is buffered and replayed in selection order so it stays readable.

Node discovery uses `sinfo` + `scontrol show hostnames` so it always picks up what SLURM currently knows about, plus the head node.

The whole thing is one self-contained file. You declare your merge sets at the top and run it — the interactive menu does the rest, or you can drive it straight from the command line:

```bash
cluster_mergerfs                                   # interactive menu
cluster_mergerfs status -s all -n all -j 8         # fast parallel sweep of everything
cluster_mergerfs mount  -s projectA-logs -n current -y
cluster_mergerfs unmount -s projectB-scenes -n node1 --dry-run
```

📥 **[Download `cluster_mergerfs.sh`](cluster_mergerfs.sh)** (single file, ~1,900 lines, no dependencies beyond `mergerfs`, `ssh`, and standard SLURM tooling).

Each merge set is declared with a `merge_set` helper, in either of two forms — a **pattern** form where `{node}` expands across a node list, or an **explicit** form listing each branch directly. Every set gets a short *tag* (e.g. `projectA-logs`) that you then pass to `--set` on the CLI:

```bash
# Pattern form: one branch per node, sharing a template.
merge_set projectA-logs /home/<user>/projects/projectA/logs \
  --nodes node1,node2,node3,node4 \
  --template '/cluster/{node}/<user>/projectA_logs'

# Explicit form: list each branch directly.
merge_set projectB-scenes /home/<user>/projects/projectB/scenes \
  /cluster/node1/<user>/projectB/scenes

MERGERFS_OPTS="cache.files=off,use_ino,func.getattr=newest,category.create=mfs,moveonenospc=true,minfreespace=300G,allow_other"
```

If you'd rather not edit the script itself, the same settings can live in `~/.config/cluster_mergerfs.conf` (or a file pointed to by `$CLUSTER_MERGERFS_CONFIG`), which is sourced as bash — so it can call `merge_set` and override `MERGERFS_OPTS`, `HEAD_NODE`, and friends.

## A few practical notes

- **mergerfs mounts are per-machine.** Each compute node sees the merged view through its own mergerfs process; there's no cluster-wide FS magic. The script just SSH-loops the same mount on every node so you get a consistent view wherever you land.
- **Run as your user, not root.** Combined with `allow_other`, that gives you the right ownership and avoids weird `chown` aftermath.
- **Don't write into a branch directly while the merged view is mounted on top of it** — mergerfs caches some metadata, so changes that bypass the union can confuse it briefly. If in doubt, write through the mount point.
- **`minfreespace` is your friend.** Without it, a single full branch can break creates pretty unintuitively. With it, mergerfs just rotates traffic onto branches that still have headroom.
- **If a mount goes hung,** the "Kill mergerfs process" action is much safer than `kill -9 $(pgrep mergerfs)` — it specifically matches the mount point at the *end* of the cmdline so it never kills a different instance.

## Wrap-up

mergerfs isn't going to replace a real distributed filesystem, and that's fine — it's not trying to. What it *does* give you is a five-minute Saturday-afternoon way to make per-node storage feel like one place, without moving any data and without admin-team meetings about provisioning. Combined with a small wrapper script, it's been one of the higher quality-of-life upgrades to my day-to-day workflow on the cluster.

---

### Disclaimer

The script linked above is released under the MIT License and is provided **"as is", without warranty of any kind**, express or implied. It performs operations that touch filesystems, mount points, and remote machines via SSH, and includes destructive actions (unmount, `kill -9`). You are solely responsible for understanding what it does before running it, for testing it in a safe environment first, and for any data loss, downtime, or other consequences that may result from its use. Use at your own risk.
