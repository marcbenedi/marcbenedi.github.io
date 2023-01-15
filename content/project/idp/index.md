---
# Documentation: https://wowchemy.com/docs/managing-content/

title: "Divergence-Free Shape Correspondence with Time Dependent Vector Fields"
summary: ""
authors: []
tags: ["M.Sc", "Shape Analysis", "Computer Graphics", "Optimization"]
categories: []
date: 2020-04-27T20:09:10+01:00

# Optional external URL for project (replaces project detail page).
external_link: ""

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder.
# Focal points: Smart, Center, TopLeft, Top, TopRight, Left, Right, BottomLeft, Bottom, BottomRight.
image:
  caption: ""
  focal_point: ""
  preview_only: false

links:
- icon: arxiv
  icon_pack: ai
  name: Original paper
  url: https://arxiv.org/abs/1806.10417

url_code: ""
url_pdf: ""
url_slides: ""
url_video: "https://youtu.be/VISp8TJIm5g"

# Slides (optional).
#   Associate this project with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides = "example-slides"` references `content/slides/example-slides.md`.
#   Otherwise, set `slides = ""`.
slides: ""
---

In this project, we extended the work of Eisenberger, Zorah, Cremers, "Divergence-Free Shape Interpolation and Correspondence" [^1]. In their work, they present a method to calculate deformation fields between shapes embedded in $\mathbb{R}^D$. To do so, they compute a divergence-free deformation field represented in a coarse-to-fine basis using the Karhunen-Loéve expansion.

![Example of parts of the shape moving in different directions at the same point](original_failure.jpg "Example of parts of a shape moving in different directions in the same part of the space [[1]](https://arxiv.org/abs/1806.10417)")

# Our Contribution

As stated by the original authors, one of the limitations of their work is in movements where different parts of the shape move through the same
region of the embedding space in a contradictory manner.
Their method cannot model such deformation because a vector field can only contain a single vector per point in space.

To overcome this limitation, Eisenberger suggested using time-dependent vector fields, such that a vector at a given point in space can change over time. For that, we solve correspondence and matching problems for the whole sequence during optimization.

# Results

{{< youtube 3cAmUDDTHYs >}}
{{< youtube gUWHj9HRdkA >}}
{{< youtube VISp8TJIm5g >}}

# Notes

[^1]: https://arxiv.org/abs/1806.10417

