---
# Documentation: https://wowchemy.com/docs/managing-content/

title: 'Learning Correspondences For Relative Pose Estimation'
summary: "We present an end-to-end learnable, differentiable method for pairwise relative pose registration of RGB-D frames. Our method is robust to big camera motions thanks to a self-supervised weighting of the predicted correspondences between the frames. Given a pair of frames, our method estimates matches of points and their visibility score. A self-supervised model predicts a confidence weight for visible matches. Finally, visible matches and their weight are fed into a differentiable weighted Procrustes aligner which estimates the rigid transformation between the input frames."
authors: []
tags: ["M.Sc", "Computer Vision", "Deep Learning"]
categories: []
date: 2021-11-01T00:00:00+01:00

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

url_code: ""
url_pdf: "/project/gr/article.pdf"
url_slides: "/project/gr/slides.pdf"
url_video: ""

# Slides (optional).
#   Associate this project with Markdown slides.
#   Simply enter your slide deck's filename without extension.
#   E.g. `slides = "example-slides"` references `content/slides/example-slides.md`.
#   Otherwise, set `slides = ""`.
slides: ""
---


We present an end-to-end learnable, differentiable method for pairwise relative pose registration of RGB-D frames. Our method is robust to big camera motions thanks to a self-supervised weighting of the predicted correspondences between the frames. Given a pair of frames, our method estimates matches of points and their visibility score. A self-supervised model predicts a confidence weight for visible matches. Finally, visible matches and their weight are fed into a differentiable weighted Procrustes aligner which estimates the rigid transformation between the input frames.


![Components of the network](components.png "Pipeline of our method. Given a pair of RGB-D images, $I1, D1 I2, D2$, we estimate the relative pose between these frames as $R \in SO(3)$ and $t \in R^3$ . First, $I1, I2$ are fed into the Correspondence and visibility prediction component, the visible predicted correspondences are weighted in the Correspondence Weighting component. Finally, they are back-projected into 3D and feed into the Weighted Procrustes aligner which estimates the relative pose.")

