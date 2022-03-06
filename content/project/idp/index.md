---
title: Divergence-Free Shape Correspondence with Time Dependent Vector Fields
summary: We are extending the paper “Divergence-Free Shape Correspondence by Deformation” and representing a motion sequence as a time dependent vector field.
tags:
- Shape Analysis
- Computer Graphics
- Optimization

date: "2020-04-27T00:00:00Z"

# Optional external URL for project (replaces project detail page).
external_link: ""

image:
  caption: "Overview of Divergence-Free Shape Interpolation and Correspondence [[1]](https://arxiv.org/abs/1806.10417)"
  focal_point: Smart

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
# slides: example
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
