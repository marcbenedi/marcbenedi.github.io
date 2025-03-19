---
title: "Animating the Uncaptured: Humanoid Mesh Animation with Video Diffusion Models"

draft: false

authors:
- admin
- Angela Dai
- Matthias Nießner
date: "2025-03-07T00:00:00Z"
doi: ""

# Schedule page publish date (NOT publication's date).
publishDate: "2017-03-07T00:00:00Z"

# Publication type.
# Accepts a single type but formatted as a YAML list (for Hugo requirements).
# Enter a publication type from the CSL standard.
# publication_types: ["manuscript"]

# Publication name and optional abbreviated publication name.
# publication: "Animating the Uncaptured: Humanoid Mesh Animation with Video Diffusion Models"
# publication_short: "Animating the Uncaptured"

# abstract: <p style="text-align:justify"> Animation of humanoid characters is essential in various graphics applications, but requires significant time and cost to create realistic animations. We propose an approach to synthesize 4D animated sequences of input static 3D humanoid meshes, leveraging strong generalized motion priors from generative video models -- as such video models contain powerful motion information covering a wide variety of human motions. From an input static 3D humanoid mesh and a text prompt describing the desired animation, we synthesize a corresponding video conditioned on a rendered image of the 3D mesh. We then employ an underlying SMPL representation to animate the corresponding 3D mesh according to the video-generated motion, based on our motion optimization. This enables a cost-effective and accessible solution to enable the synthesis of diverse and realistic 4D animations. </p>

# Summary. An optional shortened abstract.
summary: We present a novel approach to generating realistic 4D animations from static 3D humanoid meshes using generative video models. By leveraging powerful motion priors, our method transforms a static 3D mesh into an animated sequence based on a text prompt. We optimize the animation using an SMPL-based motion representation, enabling a cost-effective and accessible solution for creating diverse and lifelike character animations.


# tags:
# - Source Themes
featured: true

links:
- name: Paper
  url: atu_main.pdf
  icon_pack: fas
  icon: file-pdf
- name: Supplementary
  url: atu_supp.pdf
  icon_pack: fas
  icon: file-pdf
- name: ArXiv
  url: http://example.org
  icon_pack: ai
  icon: arxiv
- name: Video
  url: https://youtu.be/hgFj-MJoEjM
  icon_pack: fab
  icon: youtube
- name: Code
  url: http://example.org
  icon_pack: fab
  icon: square-github

# url_pdf: http://arxiv.org/pdf/1512.04133v1
# url_code: 'https://github.com/HugoBlox/hugo-blox-builder'
# url_dataset: '#'
# url_poster: '#'
# url_project: ''
# url_slides: ''
# url_source: '#'
# url_video: '#'

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder. 
image:
  # caption: "Animating the Uncaptured, a novel approach for animating 3D humanoid meshes from text prompts."
  focal_point: ""
  preview_only: false
  placement: 2

# Associated Projects (optional).
#   Associate this publication with one or more of your projects.
#   Simply enter your project's folder or file name without extension.
#   E.g. `internal-project` references `content/project/internal-project/index.md`.
#   Otherwise, set `projects: []`.
# projects:
# - internal-project

# Slides (optional).
#   Associate this publication with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides: "example"` references `content/slides/example/index.md`.
#   Otherwise, set `slides: ""`.
# slides: example

external_link: "/atu"
---

{{% callout note %}}
👉 Go to the <a href="/atu"> project's page. </a> 👈
{{% /callout %}}