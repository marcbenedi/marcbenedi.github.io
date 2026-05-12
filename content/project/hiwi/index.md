---
# Documentation: https://wowchemy.com/docs/managing-content/

title: "SLURM Cluster - Dashboard and other tools"
summary: "Designed and deployed a SLURM cluster for the TUM Visual Computing Group, including LDAP-backed authentication, NFS storage, monitoring, and Ansible-driven node provisioning. Built a Vue.js + Flask dashboard so researchers can visualize cluster state, jobs, and resource usage, and released companion open-source tools (LDAP Triggers, LDAP Emails) used in day-to-day administration."
authors: []
tags: ["Back-End", "Front-end" , "Slurm", "M.Sc"]
categories: []
date: 2020-01-06T17:36:11+01:00

draft: false

# Optional external URL for project (replaces project detail page).
external_link: ""

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder.
# Focal points: Smart, Center, TopLeft, Top, TopRight, Left, Right, BottomLeft, Bottom, BottomRight.
image:
  caption: ""
  focal_point: ""
  preview_only: true

# Custom links (optional).
#   Uncomment and edit lines below to show custom links.
# links:
# - name: Follow
#   url: https://twitter.com
#   icon_pack: fab
#   icon: twitter

url_code: ""
url_pdf: ""
url_slides: ""
url_video: ""

# Slides (optional).
#   Associate this project with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides = "example-slides"` references `content/slides/example-slides.md`.
#   Otherwise, set `slides = ""`.
slides: ""

gallery_item:

- album: hiwi
  image: 00_home.png
  caption: HOME
- album: hiwi
  image: 01_jobs.png
  caption: JOBS - Overview of job status and requested resources
- album: hiwi
  image: 011_jobs_detailed1.png
  caption: JOB - User, job id, time information and all requested resources
- album: hiwi
  image: 02_nodes.png
  caption: NODES - Available resources per node and their usage over time
- album: hiwi
  image: 03_resources_per_user.png
  caption: RESOURCES - List and chart of the resources being used per user
- album: hiwi
  image: 04_storage.png
  caption: STORAGE - A list of the storage used per user on each node
- album: hiwi
  image: 05_dark_mode.png
  caption: Dark Mode 🌛 - Because no one should use light mode!
---

<!-- {{< toc >}}  -->

This project is part of my work in the Visual Computing Group ([see my work experience here](/#experience)). 

The lab was not familiar with SLURM and job queues. Part of my responsibilities was to set up the system and ensure that researchers could understand and efficiently use the new cluster setup.

To achieve this, I developed a website, along with all the necessary back-end systems, so that users could visualize the state of the cluster, their jobs, and resource usage. Additionally, none of the members were familiar with Linux DevOps or SLURM. It was my job to understand their requirements and translate them into practical implementations.

## Milestones

- Cluster Setup
  - LDAP server and user authentication accross nodes
  - NFS storage accessible accross all nodes, mounted on demand with *autofs*
  - SLURM cluster setup, user accounts, welcome to the group email, and priority management
  - Metrics collection with Graphana and Telegraf
  - Netboot and node boot configurations
  - Ansible Playbooks
  - Storage benchmarks
  - Modulefiles
  - Storage quotas
  - Enroot integration

- Dashboard
  - Web interface with Vue.js
  - Backend development with Flask 

- Others
  - Maintenance tasks and updates

## Other Developed Tools

### LDAP Triggers

**GitHub:** https://github.com/marcbenedi/ldap-triggers

LDAP Triggers is an Open Source python package under MIT license which triggers an action every time an LDAP action is done. The current supported actions are creation/deletion of users/groups.

It comes with very clear documentation and it’s very easy to set up.

More information: https://blog.marcb.pro/posts/ldap-triggers/

### LDAP Emails

**GitHub:** https://github.com/marcbenedi/ldap-email

This tool allows sending (templated) emails to users in an LDAP database by username or group.

```bash
$ ldapemail send -u user1 -u user2 email-template
$ ldapemail send -g group1 group-template
```


## Gallery

UI/UX is not one of my strengths 😅, but I am still proud of the website, as it is still used in the lab and people find it very convinient.

*Parts of the image may be blurried to preserve user and node information.*

Don't be shy, click on the images! 👇

{{< gallery album="hiwi" >}}



