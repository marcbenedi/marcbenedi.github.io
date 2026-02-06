---
# Documentation: https://docs.hugoblox.com/managing-content/

title: "Mergerfs"
subtitle: ""
summary: ""
authors: []
tags: []
categories: []
date: 2025-10-01T11:03:24+02:00
lastmod: 2025-10-01T11:03:24+02:00
featured: false
draft: true

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

After my previous post about slurm gained a lot of tarcking, I will add a new post about a convinient tool useful for cluster setups where the storage in the server is not set up as a pool

> TL;DR: We will use Mergerfs to "merge/fuse" different directories into a single point.

Draft points:

- What is the end result

- Requirements - if not installed in the servers - then won't be possible to do it

- Setup

- Script

ansible-playbook install_mergerfs.yaml && ansible-playbook enable_fuse_allow_other.yaml


root@vmniessner9:/home/marc/SlurmSetup/Ansible/playbooks# cat enable_fuse_allow_other.yaml 
---
- name: Ensure FUSE config allows user_allow_other
  hosts: compute-nodes
  remote_user: root
  tasks:
    - name: Ensure fuse.conf exists
      ansible.builtin.file:
        path: /etc/fuse.conf
        state: touch
        mode: '0644'

    - name: Enable user_allow_other in fuse.conf
      ansible.builtin.lineinfile:
        path: /etc/fuse.conf
        regexp: '^#?user_allow_other'
        line: 'user_allow_other'
        state: present
        create: yes
        backrefs: yes


The user_allow_other option in /etc/fuse.conf is a configuration setting for FUSE (Filesystem in Userspace).

In short: It grants non-root users the permission to use the allow_other mount option. Without this setting enabled in the configuration file, a regular user cannot make their mounted filesystem accessible to other users on the system.


Yes, exactly. If you are running mergerfs as a regular user (which is a good practice), enabling user_allow_other is practically mandatory if you want any other software on your system to actually use that storage pool.
