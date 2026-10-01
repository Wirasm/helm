# Canvas anchors

A canvas note names an authored identifier or a literal source excerpt. Helm refuses a
selection it cannot anchor, and the comment field explains why. The sidecar keeps its
existing heading, comment and timestamp structure; clipboard and mail use the same anchor
heading.

| Canvas content | What the anchor names | Findable in source? |
| --- | --- | --- |
| Markdown heading, paragraph, list, blockquote, table or code | Literal enclosing top-level block, including Markdown syntax and original line endings | Yes, as source text |
| Markdown containing an authored HTML id | The nearest authored id | Yes, as an identifier |
| HTML artifact | The nearest authored id on the selected element or an ancestor | Yes, as an identifier |
| Mermaid flowchart, class, state or ER node | The identifier from the Mermaid fence | Yes, as an identifier |
| Mermaid flowchart subgraph, state composite or class namespace | Its authored group identifier | Yes, as an identifier |
| Mermaid mindmap, sequence, gitGraph, pie, edges or other unrecoverable elements | Refused: no recoverable source identifier | No anchor is emitted |
| Id-less HTML, or id-less raw HTML embedded in Markdown | Refused: add an authored id | No anchor is emitted |
| Markdown selection spanning separate top-level blocks, or source block over 2,000 characters | Refused: select an anchorable block | No anchor is emitted |
| Page-owned drawable surface (`data-helm-surface`) | The page owns annotations; helm yields its text tool | Page-specific |
| Browser pane | No canvas annotation bridge | Not applicable |

An identifier heading looks like `` `#phase2` — "Phase 2: Ship" ``. Helm keeps the
selected rendered text beside the identifier so the agent can check that the artifact still
means what the operator marked. Authored HTML ids such as `content`, `actor0` or
`mermaid-0` remain authored ids outside Mermaid; their spelling does not decide provenance.

If an identifier label or historical quotation contains a newline, tab, quote or backslash,
its lossless form is `text <JSON-string>`, for example `` `#phase2` — text "first\nsecond" ``
or `text "first\nsecond"`. JSON-decode the string after `text`; simple raw-quoted labels keep
their existing spelling. Source and selected text use the same `CanvasNotes.jsonString` encoder.

A source heading looks like `source "First **bold** line.\nSecond line.\n" text "bold"`.
Both values are JSON strings from the same encoder. Decoding them recovers the exact
source block and selected words, including newlines, quotes and backslashes. The source block can be larger than the selected words:
a nested list item names its enclosing list, and a table cell names its table. Repeated
blocks can have the same excerpt; the excerpt does not claim a unique position or survive
a rewrite that changes those bytes. Read the current artifact before editing it.

The page preserves source on the DOM because Markdown rendering and selection capture run
in separate WebKit content worlds. `data-helm-source` stores a JSON-encoded source string.
The bridge declares `anchorKind` and Swift validates it; unknown kinds cannot become ids.
Mermaid capture reports a checked `rendererRole` from direct renderer-owned label groups
and the SVG diagram type. Authored CSS classes named `node` or `cluster` do not decide the
role. Flowchart subgraphs and class namespaces carry direct authored suffixes; state
composites use state-family reduction, like ordinary state nodes.

Existing sidecars remain readable. Historical quoted-text headings do not acquire a source
guarantee. They describe rendered text and should be checked against the current artifact.

Hovering a note highlights its verified identifier, exact source block and selected words, or
unique historical rendered quotation. It scrolls an offscreen match into view. A selector with
a mismatched label falls through to verified text lookup; source excerpts must still match exactly.
Missing, duplicate or unsupported targets report that the note cannot be found. A missing page
reports that highlighting is unavailable. Closing the drawer or leaving the note
clears the temporary highlight without clearing a selection awaiting a comment.
