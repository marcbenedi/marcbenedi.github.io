---
# Documentation: https://wowchemy.com/docs/managing-content/
draft: true

title: "Learning Robust Correspondences Estimation"
summary: ""
authors: []
tags: ["Optimization", "SAT", "M.Sc", "featured"]
categories: []
date: 2022-09-15T20:05:18+01:00

# Optional external URL for project (replaces project detail page).
external_link: ""

# Featured image
# To use, add an image named `featured.jpg/png` to your page's folder.
# Focal points: Smart, Center, TopLeft, Top, TopRight, Left, Right, BottomLeft, Bottom, BottomRight.
image:
  caption: ""
  focal_point: ""
  preview_only: false

# Custom links (optional).
#   Uncomment and edit lines below to show custom links.
# links:
# - name: Follow
#   url: https://twitter.com
#   icon_pack: fab
#   icon: twitter

# url_code: "https://github.com/marcbenedi/lrce"
url_pdf: "/project/masters-thesis/lrce.pdf"
# url_slides: "/project/masters-thesis/slides.pdf"

# Slides (optional).
#   Associate this project with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides = "example-slides"` references `content/slides/example-slides.md`.
#   Otherwise, set `slides = ""`.
slides: ""
---

<!-- **Author:** Marc Benedí San Millán   -->
<!-- **Institution:** Technical University of Munich (TUM)   -->
<!-- **Thesis Title:** Learning Robust Correspondences Estimation (LRCE) -->

LRCE addresses the challenging problem of **relative camera pose estimation** in computer vision, essential for applications like 3D reconstruction, Structure from Motion (SfM), and Simultaneous Localization and Mapping (SLAM). Estimating a camera's position and orientation from a sequence of images has been a long-standing issue in the field.

# Main Contributions
LRCE introduces an **end-to-end differentiable model** for pose estimation between pairs of RGB-D frames (color + depth). The key idea is learning **confidence scores for correspondences** (matched points between images) in a **self-supervised** manner, helping to filter outliers and improve pose accuracy.

## Key Components:
1. **Correspondence and Visibility Estimation:** Predicts matching points between two frames and their visibility.
2. **Correspondence Weighting:** Assigns confidence scores to filter unreliable correspondences.
3. **Differentiable Weighted Procrustes:** Optimizes the final pose estimation by aligning the points using their confidence scores.

# Evaluation
LRCE was tested on the **ScanNet** dataset, showing improved performance in matching and pose estimation compared to traditional methods (e.g., SIFT, ORB) and modern deep learning techniques (e.g., LoFTR). Its differentiable, self-supervised nature makes it particularly robust in wide-baseline and occlusion-heavy scenarios.

# Conclusion
This thesis demonstrates how integrating **end-to-end learning** and self-supervised weighting can make camera pose estimation more accurate and robust. The source code is publicly available for further research and improvements.

<!-- **Read more:** [GitHub Link](https://github.com/marcbenedi/LRCE) -->

