---
# Documentation: https://wowchemy.com/docs/managing-content/

title: "autocast - Stop writing boilerplate"
subtitle: ""
summary: "Introducing `autocast`, a new Python library that automates type conversion using a directed graph, saving you from writing verbose `.detach().cpu().numpy()` chains."
authors: []
tags: [Python, Open Source, Machine Learning, Computer Vision, PyTorch]
categories: [Open Source]
date: 2026-02-09T21:54:00+02:00
lastmod: 2026-02-09T21:54:00+02:00
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

{{< toc >}}

If you work in Computer Vision or Machine Learning, you have likely written this code a thousand times:

```python
# The "Dance of the Types" 🕺
points = prediction.detach().cpu().numpy()
pcd = o3d.geometry.PointCloud()
pcd.points = o3d.utility.Vector3dVector(points)
```

It is verbose. It is brittle. And worst of all, it breaks your flow. You stop thinking about geometry and start thinking about memory layouts, device placement, and wrappers.

I got tired of writing these same three lines in every project. I wanted a way to just say "give me a PointCloud" and have Python figure out the rest.

So, I built [autocast](https://github.com/marcbenedi/autocast).

## A Graph of Types
`autocast` treats type conversion as a routing problem. Instead of manually writing the conversion chain, you just define the start and the end.

```python
from autocast import acast
import open3d as o3d

# "Just give me a PointCloud, I don't care how."
pcd = acast(prediction, o3d.geometry.PointCloud)
```

Under the hood, `autocast` maintains a Directed Graph of all registered types.

When you ask for a conversion from `A` to `C`:

1. It checks if a direct `A -> C` converter exists.
2. If not, it runs a Breadth-First Search (BFS) to find the shortest path (e.g., `A -> B -> C`).
3. It executes the chain automatically.

## Why `autocast` is Cool

### 1. It Handles the "Messy" Stuff

Deep learning pipelines often spit out complex nested structures: lists of dicts of tensors. Converting these manually requires writing recursive loops. `autocast` handles collections natively.

```python
data = {
    "boxes": [torch.tensor(...), torch.tensor(...)],
    "scores": torch.tensor(...)
}

# Convert the WHOLE structure to NumPy arrays in one line
numpy_data = acast(data, np.ndarray)
```

### 2. Extensible (Monkey-Patch Friendly)
You can extend the graph with your own custom types using the `@acaster` decorator.

```python
@acaster(MyCustomBBox, torch.Tensor)
def bbox_to_tensor(bbox):
    return torch.tensor([bbox.x, bbox.y, bbox.w, bbox.h])
```

Now, any time you call `acast(bbox, np.ndarray)`, `autocast` knows it can go `MyCustomBBox -> Tensor -> NumPy`.

## Try it out

It’s available on PyPI now. 

> **Note:** The package name on PyPI is `acaster`, but you import it as `autocast`.

```bash
pip install acaster
```

Check out the code on GitHub: [github.com/marcbenedi/autocast](https://github.com/marcbenedi/autocast)

I’d love to hear if this saves you as much time as it saved me!