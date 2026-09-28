---
name: visualize
description: Use when the user asks to visualize, diagram, chart, draw or map something, asks to be shown how something works, or when a flow, a structure or a set of numbers would land better as a picture than as prose.
---

# Visualize

The reader looks at a picture. Terminals and chat panes do not draw diagrams, so diagram source in a reply is text they have to render in their head.

## The deliverable

1. **One self-contained HTML page** (inline CSS and SVG, no network requests), written to the scratch directory the user's instructions name, else the system temp directory. Open it for the reader (`open`, `xdg-open`).
2. **The page answers the reader's question.** Its first line is the answer in one plain sentence. The picture shows the idea behind that answer: the parts the reader would name, in the reader's words, and what passes between them.
3. **You have looked at it.** Render the page to an image and check it before replying. Fix clipped labels, overlaps and arrows that point the wrong way, then stop any server or browser you started to render it.
4. **The reply's first sentence is the answer.** Then the page's path, then at most three lines on what the page shows. Anything else you need to report, such as a denied command, comes last.

When the destination renders diagrams itself, such as a Markdown file in a repository or a host that renders Mermaid, write the diagram there and give its path instead.

## Choosing the tool

| The picture shows | Use when available |
| --- | --- |
| numbers: comparisons, trends, parts of a whole | `dataviz` |
| structure or flow: architecture, sequence, states, data flow | `diagram-design` |
| how CSS sizes or lays something out | `explain-css-layout` |
| anything else, or none of these installed | hand-written HTML and SVG |

A routed skill decides the style. The deliverable above still holds.
