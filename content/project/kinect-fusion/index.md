---
title: "Kinect Fusion: Dense Surface Mapping and Tracking"
summary: "Implementation of the paper “Kinect Fusion: Real-Time Dense Surface Mapping and Tracking”"
tags:
- Computer Vision
- Computer Graphics

date: "2021-03-27T00:00:00Z"
draft: false

# Optional external URL for project (replaces project detail page).
external_link: ""

image:
  placement: 2
  caption: "From left to right: depth frame from sensor, normal map back-projected into 3D, reconstructed canonical model, reconstructed canonical model with color"
  focal_point: Smart

links:
- icon: arxiv
  icon_pack: ai
  name: Original paper
  url: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/kinectfusion-uist-comp.pdf
  
url_code: "https://github.com/keremyldrr/KinectFusion"
url_pdf: "/project/kinect-fusion/report.pdf"
url_slides: "/project/kinect-fusion/slides.pdf"
url_video: "https://www.youtube.com/watch?v=3YIve6ju6qg"

# Slides (optional).
#   Associate this project with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides = "example-slides"` references `content/slides/example-slides.md`.
#   Otherwise, set `slides = ""`.
# slides: example
---

Implementation of the paper "Kinect Fusion" by Newcombe et al. [^1]  They presented a method for accurate real-time mapping of indoor scenes, using only a low-cost depth camera and graphics hardware.

{{< youtube 3YIve6ju6qg >}}

This project is part of the lecture 3D Scanning and Motion Capture (https://www.in.tum.de/cg/teaching/winter-term-2021/3d-scanning-motion-capture/). We implemented this project using C++ and CUDA.

# Results

For evaluating our implementation we used TUM's RGB-D SLAM Dataset
https://vision.in.tum.de/data/datasets/rgbd-dataset.

See the final part of the video above to see the results.

# Notes

[^1]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/ismar2011.pdf

<!-- {{< figure src="sidebyside.png" caption="A caption" numbered="true" >}} -->
<!-- {{< figure src="snap.png" caption="A caption" numbered="true" >}} -->
<!-- {{< figure src="pipeline.svg" caption="A caption" numbered="true" >}} -->
