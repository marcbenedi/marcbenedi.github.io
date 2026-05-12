---
# Documentation: https://docs.hugoblox.com/managing-content/

title: "Ollama"
subtitle: ""
summary: ""
authors: []
tags: []
categories: []
date: 2026-03-22T16:39:01+01:00
lastmod: 2026-03-22T16:39:01+01:00
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


curl -fsSL https://ollama.com/download/ollama-linux-amd64.tar.zst | zstd -d | tar -x -C ~/.local/

curl -fsSL https://claude.ai/install.sh | bash

https://github.com/papersgpt/papersgpt-for-zotero

https://www.papersgpt.com/literature-review


"""
Act as the lead author writing the 'Related Work' section for a top-tier CVPR paper. Analyze the provided papers and organize them into 3 to 4 distinct thematic categories.

CRITICAL INSTRUCTIONS FOR LENGTH:

You MUST write a minimum of 3 full paragraphs per category.

Do NOT compress the papers into a single paragraph.

Dedicate at least 150 words to explaining the methodology of each individual paper before comparing it to the others.

End every category with a dedicated, detailed paragraph explaining the specific bottlenecks and gaps in that line of research.

Keep the tone dense, objective, and highly technical. If your response for a category is only one paragraph, you have failed the instructions.
"""