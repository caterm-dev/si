#!/usr/bin/env python3
"""Extract one-sentence-per-line TXT from local SI AX exports entirely offline."""

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile


class ExportError(ValueError):
    pass


def text_value(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("text"), str):
        return value["text"]
    return ""


def array_value(value):
    if isinstance(value, dict):
        value = value.get("values", [])
    return value if isinstance(value, list) else []


def references(value):
    if isinstance(value, dict) and type(value.get("ref")) is int:
        return [value["ref"]]
    return [item["ref"] for item in array_value(value)
            if isinstance(item, dict) and type(item.get("ref")) is int]


def sentence_spans(text):
    """Conservative punctuation-based spans, in Python Unicode code-point units."""
    start = index = 0
    closers = '\"\'”’」』）》】)］]}'
    abbreviations = {"mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e"}
    while index < len(text):
        char = text[index]
        boundary = char in "。！？!?"
        if char == ".":
            previous = text[index - 1] if index else ""
            following = text[index + 1] if index + 1 < len(text) else ""
            token = re.search(r"([A-Za-z.]+)$", text[:index])
            word = token.group(1).lower() if token else ""
            boundary = (not following or following.isspace() or following in closers)
            if previous.isdigit() and following.isdigit():
                boundary = False
            if word in abbreviations or (len(word) == 1 and word.isalpha()):
                boundary = False
        if boundary:
            end = index + 1
            while end < len(text) and text[end] in "。！？!?.”’\"'」』）》】)］]}":
                end += 1
            # Keep whitespace in exact source spans rather than silently stripping it.
            while end < len(text) and text[end].isspace():
                end += 1
            yield {"start": start, "end": end, "text": text[start:end]}
            start = index = end
        else:
            index += 1
    if start < len(text):
        yield {"start": start, "end": len(text), "text": text[start:]}


@dataclass
class Fragment:
    text: str
    node_ids: list


class Extractor:
    controls = {"AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXComboBox",
                "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem", "AXToolbar", "AXImage"}
    text_roles = {"AXStaticText", "AXTextArea", "AXTextField", "AXSearchField", "AXListMarker"}
    editable_roles = {"AXTextArea", "AXTextField", "AXSearchField"}
    inline_subroles = {"AXStrongStyleGroup", "AXEmphasisStyleGroup", "AXCodeStyleGroup",
                       "AXSuperscriptStyleGroup", "AXSubscriptStyleGroup", "AXUnderlineStyleGroup"}

    def __init__(self, document, include_controls=False):
        if (not isinstance(document, dict) or document.get("format") != "SI-AX-Export"
                or type(document.get("version")) is not int or document["version"] != 1):
            raise ExportError("Expected an SI-AX-Export version 1 document.")
        rows = document.get("nodes")
        if not isinstance(rows, list) or len(rows) > 5_000:
            raise ExportError("Expected at most 5,000 AX nodes.")
        self.nodes = {}
        for row in rows:
            if not isinstance(row, dict) or type(row.get("id")) is not int or row["id"] in self.nodes:
                raise ExportError("AX node IDs must be unique integers.")
            if not isinstance(row.get("attributes", {}), dict):
                raise ExportError("AX node attributes must be objects.")
            self.nodes[row["id"]] = row
        self.document = document
        self.include_controls = include_controls
        self.seen = set()
        self.warnings = set()
        self.blocks = []
        self.excluded_subtrees = []

    def attrs(self, node_id):
        return self.nodes[node_id].get("attributes", {})

    def children(self, node_id):
        attrs = self.attrs(node_id)
        ordered = references(attrs.get("AXChildrenInNavigationOrder"))
        children = ordered or references(attrs.get("AXChildren")) or references(attrs.get("AXContents"))
        result = []
        for child in children:
            if child in self.nodes:
                result.append(child)
            else:
                self.warnings.add("missingChildReference")
        return result

    def classes(self, node_id):
        return [value for value in array_value(self.attrs(node_id).get("AXDOMClassList")) if isinstance(value, str)]

    def excluded(self, node_id):
        node = self.nodes[node_id]
        attrs = self.attrs(node_id)
        return (bool(node.get("redacted")) or attrs.get("AXHidden") is True
                or text_value(attrs.get("AXSubrole")) == "AXSecureTextField"
                or any(value in {"sr-only", "visually-hidden"} for value in self.classes(node_id)))

    def own_text(self, node_id):
        attrs = self.attrs(node_id)
        # Choose one equivalent label; never concatenate value/title/description copies.
        for name in ("AXValue", "AXTitle", "AXDescription"):
            text = text_value(attrs.get(name))
            if text:
                return text
        return ""

    def paragraph(self, node_id):
        attrs = self.attrs(node_id)
        return (text_value(attrs.get("AXRole")) == "AXParagraph"
                or text_value(attrs.get("AXSubrole")) == "AXParagraph"
                or any(re.match(r"(?i)^paragraph(?:$|[-_])", value) for value in self.classes(node_id)))

    def inline_tree(self, node_id, active=None):
        active = set() if active is None else active
        if node_id in active or len(active) >= 256:
            return False
        attrs = self.attrs(node_id)
        role = text_value(attrs.get("AXRole"))
        if self.paragraph(node_id) or role in {"AXHeading", "AXList", *self.editable_roles}:
            return False
        if role in {"AXStaticText", "AXLink", "AXListMarker"}:
            return True
        if text_value(attrs.get("AXSubrole")) in self.inline_subroles:
            return True
        if role in self.controls:
            return False
        children = self.children(node_id)
        return bool(children) and all(self.inline_tree(child, active | {node_id}) for child in children)

    def same_line(self, children):
        frames = [self.attrs(child).get("AXFrame") for child in children]
        if not frames or any(not isinstance(frame, dict) for frame in frames):
            return False
        intervals = []
        for frame in frames:
            y, height = frame.get("y"), frame.get("height")
            if any(type(value) not in (int, float) or not math.isfinite(value) for value in (y, height)) or height <= 0:
                return False
            intervals.append((y, y + height))
        return max(start for start, _ in intervals) < min(end for _, end in intervals)

    def enter(self, node_id, depth):
        if depth >= 256:
            self.warnings.add("treeDepthLimit")
            return False
        if node_id in self.seen:
            return False
        if self.excluded(node_id):
            self.excluded_subtrees.append({"node_id": node_id, "reason": "hidden-or-secure"})
            self.seen.add(node_id)
            return False
        self.seen.add(node_id)
        return True

    def inline(self, node_id, depth=0):
        if not self.enter(node_id, depth):
            return Fragment("", [])
        if not self.include_controls and text_value(self.attrs(node_id).get("AXRole")) in self.controls:
            self.excluded_subtrees.append({"node_id": node_id, "reason": "body-only-control-filter"})
            return Fragment("", [])
        return self.inline_body(node_id, depth)

    def inline_body(self, node_id, depth):
        attrs = self.attrs(node_id)
        role = text_value(attrs.get("AXRole"))
        value = text_value(attrs.get("AXValue"))
        # A native text value already contains its descendants and original newlines.
        if value and role in self.text_roles:
            pending = list(self.children(node_id))
            covered = set()
            while pending:
                child = pending.pop()
                if child in covered or child == node_id:
                    continue
                covered.add(child)
                pending.extend(self.children(child))
            self.seen.update(covered)
            return Fragment(value, [node_id])
        fragments = [self.inline(child, depth + 1) for child in self.children(node_id)]
        text = "".join(fragment.text for fragment in fragments)
        ids = [node for fragment in fragments for node in fragment.node_ids]
        if text:
            return Fragment(text, ids)
        own = self.own_text(node_id)
        return Fragment(own, [node_id] if own else [])

    def append(self, node_id, fragment, kind, boundary):
        if fragment.text.strip():
            self.blocks.append({"index": len(self.blocks), "kind": kind, "boundary": boundary,
                                "node_id": node_id, "source_node_ids": fragment.node_ids,
                                "text": fragment.text, "sentences": list(sentence_spans(fragment.text))})

    def retain_labels(self, node_id, start):
        """Retain distinct parent/control labels without repeating equivalent child text."""
        if not self.include_controls:
            return
        attrs = self.attrs(node_id)
        rendered = [block["text"] for block in self.blocks[start:]]
        labels = []
        for name in ("AXValue", "AXTitle", "AXDescription"):
            text = text_value(attrs.get(name))
            if not text.strip() or text in rendered or text == "".join(rendered):
                continue
            if any(label["text"] == text for label in labels):
                continue
            labels.append({"kind": "label", "boundary": "accessibility-label", "node_id": node_id,
                           "source_node_ids": [node_id], "source_attribute": name, "text": text,
                           "sentences": list(sentence_spans(text))})
        self.blocks[start:start] = labels

    def walk(self, node_id, depth=0, list_item=False):
        if not self.enter(node_id, depth):
            return
        attrs = self.attrs(node_id)
        role = text_value(attrs.get("AXRole"))
        children = self.children(node_id)
        start = len(self.blocks)
        if role in self.controls:
            if self.include_controls and role in {"AXMenu", "AXMenuBar", "AXToolbar"}:
                for child in children:
                    self.walk(child, depth + 1)
            elif self.include_controls:
                self.append(node_id, self.inline_body(node_id, depth), "control", "accessibility-control")
            else:
                self.excluded_subtrees.append({"node_id": node_id, "reason": "body-only-control-filter"})
            self.retain_labels(node_id, start)
            return
        if role in self.text_roles:
            self.append(node_id, self.inline_body(node_id, depth), "text-field" if role in self.editable_roles else "text",
                        "source-text")
        elif self.paragraph(node_id) or role == "AXHeading" or list_item:
            # Preserve nested lists as independent items instead of fusing them into their parent.
            nested_lists = [child for child in children if text_value(self.attrs(child).get("AXRole")) == "AXList"]
            fragments = [self.inline(child, depth + 1) for child in children if child not in nested_lists]
            fragment = Fragment("".join(part.text for part in fragments), [i for part in fragments for i in part.node_ids])
            if not children:
                fragment = Fragment(self.own_text(node_id), [node_id])
            self.append(node_id, fragment, "list-item" if list_item else "heading" if role == "AXHeading" else "paragraph",
                        "accessibility-structure")
            for child in nested_lists:
                self.walk(child, depth + 1)
        elif role == "AXList":
            for child in children:
                # Navigation lists can contain whole sidebar sections and controls.
                # Only flatten textual items, never their arbitrary UI subtrees.
                textual = (text_value(self.attrs(child).get("AXRole")) == "AXListItem"
                           or self.paragraph(child) or self.inline_tree(child)
                           or any(text_value(self.attrs(item).get("AXRole")) == "AXListMarker"
                                  for item in self.children(child)))
                self.walk(child, depth + 1, list_item=textual)
        elif children and all(self.inline_tree(child) for child in children) and self.same_line(children):
            self.append(node_id, self.inline_body(node_id, depth), "paragraph", "geometry-inferred")
        elif children:
            for child in children:
                self.walk(child, depth + 1)
        else:
            self.append(node_id, Fragment(self.own_text(node_id), [node_id]), "text", "leaf-label")
        self.retain_labels(node_id, start)

    def extract(self, root_id=None):
        if root_id is None:
            root_id = self.document.get("root")
            if type(root_id) is not int or root_id not in self.nodes:
                raise ExportError("The export root is missing.")
            attrs = self.attrs(root_id)
            windows = (references(attrs.get("AXFocusedWindow")) or references(attrs.get("AXMainWindow"))
                       or references(attrs.get("AXWindows")))
            if windows:
                root_id = windows[0]
        if type(root_id) is not int or root_id not in self.nodes:
            raise ExportError("The requested root node is missing.")
        self.walk(root_id)
        for index, block in enumerate(self.blocks):
            block["index"] = index
        truncations = self.document.get("truncations", [])
        if truncations:
            self.warnings.add("sourceExportTruncated")
        return {"format": "SI-AX-Text", "version": 1, "application": self.document.get("application", {}),
                "capturedAt": self.document.get("capturedAt"), "root": root_id,
                "include_controls": self.include_controls, "source_truncations": truncations,
                "excluded_subtrees": self.excluded_subtrees,
                "warnings": sorted(self.warnings), "offset_unit": "unicode-code-point",
                "notes": ["AX reading order is preserved; distinct nodes with repeated text are retained.",
                          "Paragraph boundaries use exposed structure, with marked geometry fallbacks.",
                          "Sentence boundaries are punctuation heuristics, not linguistic guarantees.",
                          "Exposed offscreen content may be included; this is not a screenshot transcription."],
                "blocks": self.blocks}


def extract_document(document, root_id=None, include_controls=False):
    return Extractor(document, include_controls=include_controls).extract(root_id)


def render(result):
    # Source spans stay exact internally; TXT gives each trimmed sentence one line.
    return "".join(re.sub(r"\r\n|[\r\n]", " ", sentence["text"].strip()) + "\n"
                   for block in result["blocks"] for sentence in block["sentences"])


def write_private(destination, text, overwrite=False):
    if destination.exists() and not overwrite:
        raise ExportError("The destination exists; use --overwrite to replace it.")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".ax-text-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(text.encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        if overwrite:
            os.replace(temporary, destination)
        else:
            os.link(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, help="Default: adjacent .sentences.txt file")
    parser.add_argument("--root", type=int, help="Restrict extraction to an AX node (default: focused/main window)")
    controls = parser.add_mutually_exclusive_group()
    controls.add_argument("--body-only", dest="include_controls", action="store_false",
                          help="Exclude button/menu/toolbar text, including inline controls (the default)")
    controls.add_argument("--include-controls", dest="include_controls", action="store_true",
                          help="Also include button/menu/toolbar labels")
    parser.set_defaults(include_controls=False)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(argv)
    destination = args.output or args.source.with_suffix(".sentences.txt")
    try:
        if args.source.resolve() == destination.resolve():
            raise ExportError("The source export cannot be overwritten.")
        if args.source.stat().st_size > 32 * 1_024 * 1_024:
            raise ExportError("The source exceeds the 32 MiB export limit.")
        document = json.loads(args.source.read_bytes())
        result = extract_document(document, args.root, args.include_controls)
        write_private(destination, render(result), args.overwrite)
    except ExportError as error:
        print(f"AX extraction failed: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, RecursionError):
        # Exception strings from decoders can contain source text; keep diagnostics content-free.
        print("AX extraction failed. Check the export format, root, destination and overwrite option.", file=sys.stderr)
        return 1
    count = sum(len(block["sentences"]) for block in result["blocks"])
    print(f"Extracted {count} sentence spans. Saved: {destination}")
    if result["warnings"]:
        print("AX extraction warnings: " + ", ".join(result["warnings"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
