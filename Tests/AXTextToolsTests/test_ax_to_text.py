from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest

from scripts import ax_to_text as tool


def node(identifier, role="AXGroup", children=(), **attrs):
    return {"id": identifier, "attributes": {"AXRole": role, "AXChildren": refs(*children), **attrs}}


def refs(*identifiers):
    return {"values": [{"ref": identifier} for identifier in identifiers], "totalCount": len(identifiers)}


def document(*nodes, **metadata):
    return {"format": "SI-AX-Export", "version": 1, "root": 0, "nodes": list(nodes), "truncations": [], **metadata}


def paragraph(identifier, children):
    return node(identifier, children=children, AXDOMClassList={"values": ["Paragraph-example"]})


class AXTextTests(unittest.TestCase):
    def test_inline_styles_links_and_mentions_reconstruct_one_original_paragraph(self):
        source = document(node(0, children=[1]), paragraph(1, [2, 3, 4, 5, 6]),
                          node(2, children=[7], AXSubrole="AXStrongStyleGroup"),
                          node(3, "AXStaticText", AXValue="可以查看 "),
                          node(4, "AXLink", children=[8], AXTitle="Apple", AXDescription="Apple"),
                          node(5, "AXButton", AXTitle="example.swift"),
                          node(6, "AXStaticText", AXValue="。"),
                          node(7, "AXStaticText", AXValue="现在"),
                          node(8, "AXStaticText", AXValue="Apple "))
        blocks = tool.extract_document(source, include_controls=True)["blocks"]
        self.assertEqual([block["text"] for block in blocks], ["现在可以查看 Apple example.swift。"])
        self.assertEqual(blocks[0]["source_node_ids"], [7, 3, 8, 5, 6])
        self.assertEqual(blocks[0]["boundary"], "accessibility-structure")

    def test_default_window_and_explicit_subtree_exclude_unrelated_menus_and_windows(self):
        source = document(node(0, "AXApplication", [1, 2, 3], AXFocusedWindow={"ref": 2}),
                          node(1, "AXWindow", [4]), node(2, "AXWindow", [5]),
                          node(3, "AXMenuBar", [6]), node(4, "AXStaticText", AXValue="other window"),
                          node(5, "AXStaticText", AXValue="focused window"), node(6, "AXMenuItem", AXTitle="Menu"))
        self.assertEqual(tool.render(tool.extract_document(source)), "focused window\n")
        result = tool.extract_document(source, root_id=0, include_controls=True)
        self.assertEqual([block["text"] for block in result["blocks"]], ["other window", "focused window", "Menu"])

    def test_repeats_remain_while_shared_references_and_parent_label_copies_do_not_duplicate(self):
        source = document(node(0, children=[1, 2, 1]),
                          node(1, "AXHeading", [3], AXTitle="Again", AXDescription="Again"),
                          node(2, "AXStaticText", AXValue="Again"), node(3, "AXStaticText", AXValue="Again"))
        self.assertEqual([block["text"] for block in tool.extract_document(source)["blocks"]], ["Again", "Again"])

    def test_native_text_value_preserves_exact_unicode_newlines_and_whitespace(self):
        original = "  LÜ'SE e\u0301 👩🏽‍💻\r\n第二行\0\n\n第三段  "
        source = document(node(0, children=[1, 2]), node(1, "AXTextArea", [2], AXValue=original),
                          node(2, "AXStaticText", AXValue="a duplicate child"))
        blocks = tool.extract_document(source)["blocks"]
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0]["text"].encode(), original.encode())
        self.assertEqual("".join(part["text"] for part in blocks[0]["sentences"]), original)

    def test_lists_keep_item_boundaries_and_inline_fragments(self):
        source = document(node(0, children=[1]), node(1, "AXList", [2, 3]),
                          node(2, children=[4, 5]), node(3, children=[6, 7]),
                          node(4, "AXListMarker", AXValue="• "), node(5, "AXStaticText", AXValue="第一项。"),
                          node(6, "AXListMarker", AXValue="• "), node(7, "AXStaticText", AXValue="第二项！"))
        blocks = tool.extract_document(source)["blocks"]
        self.assertEqual([block["text"] for block in blocks], ["• 第一项。", "• 第二项！"])
        self.assertTrue(all(block["kind"] == "list-item" for block in blocks))

    def test_sidebar_navigation_lists_do_not_become_a_single_body_paragraph(self):
        source = document(node(0, children=[1, 2]), node(1, "AXList", [3]),
                          paragraph(2, [7]), node(3, children=[4, 5]),
                          node(4, "AXButton", AXTitle="Sidebar action"),
                          node(5, "AXButton", children=[6], AXTitle="Another action"),
                          node(6, "AXStaticText", AXValue="Another action"),
                          node(7, "AXStaticText", AXValue="Body paragraph."))
        body = tool.extract_document(source, include_controls=False)
        self.assertEqual([block["text"] for block in body["blocks"]], ["Body paragraph."])
        self.assertEqual({entry["reason"] for entry in body["excluded_subtrees"]}, {"body-only-control-filter"})
        self.assertEqual([block["text"] for block in tool.extract_document(source, include_controls=True)["blocks"]],
                         ["Sidebar action", "Another action", "Body paragraph."])

    def test_default_excludes_sidebar_button_titles_and_opt_in_avoids_parent_duplicates(self):
        title = "关于示例终端，我想支持远程连接"
        source = document(node(0, children=[1]), node(1, "AXList", [2]),
                          node(2, children=[3], AXTitle=title, AXDescription=title),
                          node(3, "AXButton", AXTitle=title, AXDescription=title))
        result = tool.extract_document(source)
        self.assertFalse(result["include_controls"])
        self.assertEqual(result["blocks"], [])
        result = tool.extract_document(source, include_controls=True)
        self.assertEqual([block["text"] for block in result["blocks"]], [title])
        self.assertEqual(result["blocks"][0]["source_node_ids"], [3])

    def test_distinct_container_and_control_labels_are_kept_in_reading_order(self):
        source = document(node(0, children=[1]), node(1, "AXToolbar", [2, 3], AXTitle="Tools"),
                          node(2, "AXButton", AXTitle="Open", AXDescription="Open document"),
                          node(3, "AXPopUpButton", [4], AXTitle="All projects"),
                          node(4, "AXStaticText", AXValue="Selected project"))
        blocks = tool.extract_document(source, include_controls=True)["blocks"]
        self.assertEqual([block["text"] for block in blocks],
                         ["Tools", "Open document", "Open", "All projects", "Selected project"])
        self.assertEqual([block["index"] for block in blocks], list(range(5)))

    def test_cli_defaults_to_body_only_and_controls_require_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "SI-AX-synthetic.json"
            source.write_text(json.dumps(document(node(0, children=[1, 2]),
                                                 node(1, "AXButton", AXTitle="Sidebar title"),
                                                 node(2, "AXStaticText", AXValue="Body text"))))
            self.assertEqual(tool.main([str(source)]), 0)
            self.assertEqual(source.with_suffix(".sentences.txt").read_text(), "Body text\n")
            self.assertEqual(tool.main([str(source), "--include-controls", "--overwrite"]), 0)
            self.assertEqual(source.with_suffix(".sentences.txt").read_text(), "Sidebar title\nBody text\n")
            self.assertEqual(tool.main([str(source), "--body-only", "--overwrite"]), 0)
            self.assertEqual(source.with_suffix(".sentences.txt").read_text(), "Body text\n")

    def test_default_excludes_inline_buttons_but_keeps_surrounding_paragraph_text(self):
        source = document(node(0, children=[1]), paragraph(1, [2, 3, 4]),
                          node(2, "AXStaticText", AXValue="Before "),
                          node(3, "AXButton", [5], AXTitle="Button title"),
                          node(4, "AXStaticText", AXValue=" after."),
                          node(5, "AXStaticText", AXValue="Button child"))
        result = tool.extract_document(source)
        self.assertEqual([block["text"] for block in result["blocks"]], ["Before  after."])
        self.assertEqual(result["blocks"][0]["source_node_ids"], [2, 4])
        self.assertEqual(result["excluded_subtrees"], [{"node_id": 3, "reason": "body-only-control-filter"}])

    def test_hidden_and_secure_nodes_are_excluded_without_discarding_offscreen_text(self):
        source = document(node(0, children=[1, 2, 3, 4, 5]),
                          node(1, "AXStaticText", AXValue="hidden", AXHidden=True),
                          node(2, "AXStaticText", AXValue="screen reader label", AXDOMClassList={"values": ["sr-only"]}),
                          node(3, "AXTextField", AXValue="secret", AXSubrole="AXSecureTextField"),
                          {"id": 4, "redacted": "secureTextElement"},
                          node(5, "AXStaticText", AXValue="exposed offscreen", AXFrame={"x": 0, "y": -100, "width": 100, "height": 0}))
        self.assertEqual([block["text"] for block in tool.extract_document(source)["blocks"]], ["exposed offscreen"])

    def test_navigation_order_wins_over_export_node_order_and_cycles_are_bounded(self):
        source = document(node(0, children=[1, 2], AXChildrenInNavigationOrder=refs(2, 1, 999)),
                          node(1, "AXStaticText", AXValue="second"), node(2, children=[3, 0]),
                          node(3, "AXStaticText", AXValue="first"))
        result = tool.extract_document(source)
        self.assertEqual([block["text"] for block in result["blocks"]], ["first", "second"])
        self.assertIn("missingChildReference", result["warnings"])

    def test_geometry_fallback_joins_same_line_only_and_marks_inference(self):
        def frame(y):
            return {"x": 0, "y": y, "width": 40, "height": 15}
        source = document(node(0, children=[1, 2]), node(1, children=[3, 4]), node(2, children=[5, 6]),
                          node(3, "AXStaticText", AXValue="Hello ", AXFrame=frame(0)),
                          node(4, "AXStaticText", AXValue="world.", AXFrame=frame(0)),
                          node(5, "AXStaticText", AXValue="First line", AXFrame=frame(30)),
                          node(6, "AXStaticText", AXValue="Second line", AXFrame=frame(50)))
        blocks = tool.extract_document(source)["blocks"]
        self.assertEqual([block["text"] for block in blocks], ["Hello world.", "First line", "Second line"])
        self.assertEqual(blocks[0]["boundary"], "geometry-inferred")

    def test_sentence_spans_keep_punctuation_quotes_decimals_urls_and_source_offsets(self):
        text = '第一句。“第二句！” Dr. Chen uses 3.14 and example.com. Next? 末尾'
        parts = list(tool.sentence_spans(text))
        self.assertEqual([part["text"] for part in parts],
                         ['第一句。', '“第二句！” ', 'Dr. Chen uses 3.14 and example.com. ', 'Next? ', '末尾'])
        self.assertEqual("".join(part["text"] for part in parts), text)
        for part in parts:
            self.assertEqual(text[part["start"]:part["end"]], part["text"])

    def test_source_truncation_is_propagated_and_partial_text_remains_marked(self):
        source = document(node(0, "AXStaticText", AXValue={"text": "partial", "truncated": True}),
                          truncations=["textLimit"])
        result = tool.extract_document(source)
        self.assertEqual(result["source_truncations"], ["textLimit"])
        self.assertIn("sourceExportTruncated", result["warnings"])
        self.assertEqual(result["blocks"][0]["text"], "partial")

    def test_invalid_documents_and_duplicate_ids_are_rejected(self):
        for source in [{}, {"format": "SI-AX-Export", "version": 2}, document(node(0), node(0)),
                       document(node(2)), document(node(0), root=[]), document(node(0), version=True)]:
            with self.subTest(source=source), self.assertRaises(tool.ExportError):
                tool.extract_document(source)

    def test_sentence_output_is_one_line_per_sentence_and_source_spans_keep_original_breaks(self):
        source = document(node(0, "AXTextArea", AXValue="Hello\r\nworld.\n下一句！"))
        result = tool.extract_document(source)
        self.assertEqual(tool.render(result), "Hello world.\n下一句！\n")
        self.assertEqual(result["blocks"][0]["text"], "Hello\r\nworld.\n下一句！")

    def test_private_outputs_refuse_overwrite_and_preserve_original_export(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "SI-AX-synthetic.json"
            original = json.dumps(document(node(0, "AXStaticText", AXValue="原文。"))).encode()
            source.write_bytes(original)
            self.assertEqual(tool.main([str(source)]), 0)
            output = source.with_suffix(".sentences.txt")
            self.assertEqual(output.read_text(), "原文。\n")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            output.write_text("keep existing")
            self.assertEqual(tool.main([str(source)]), 1)
            self.assertEqual(output.read_text(), "keep existing")
            self.assertEqual(tool.main([str(source), "--overwrite"]), 0)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(tool.main([str(source), "--output", str(source), "--overwrite"]), 1)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(sorted(p.name for p in source.parent.iterdir()), [source.name, output.name])

    def test_truncated_snapshot_exports_available_sentences_with_content_free_warnings(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "SI-AX-synthetic.json"
            source.write_text(json.dumps(document(node(0, children=[1, 99]),
                                                 node(1, "AXStaticText", AXValue="Synthetic private text."),
                                                 truncations=["valueLimit"])))
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(tool.main([str(source)]), 0)
            self.assertEqual(source.with_suffix(".sentences.txt").read_text(), "Synthetic private text.\n")
            self.assertIn("sourceExportTruncated", stderr.getvalue())
            self.assertIn("missingChildReference", stderr.getvalue())
            self.assertNotIn("Synthetic private text", stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
