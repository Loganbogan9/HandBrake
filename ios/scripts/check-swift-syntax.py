#!/usr/bin/env python3
"""Optional cross-platform Swift grammar check; does not typecheck Apple APIs.

Install tree-sitter and tree-sitter-swift in a development environment, then run.
Xcode compilation and XCTest remain required for a verified iOS build.
"""
from pathlib import Path
import sys
from tree_sitter import Language, Parser
import tree_sitter_swift

root = Path(__file__).resolve().parents[1]
parser = Parser(Language(tree_sitter_swift.language()))
failed = False
for path in sorted(root.rglob("*.swift")):
    tree = parser.parse(path.read_bytes())
    errors = []
    def inspect(node):
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.start_point.row + 1}:{node.start_point.column + 1} {node.type}")
        for child in node.children:
            inspect(child)
    inspect(tree.root_node)
    if errors:
        failed = True
        print(f"{path.relative_to(root)}: {', '.join(errors)}", file=sys.stderr)
    else:
        print(f"Swift syntax OK: {path.relative_to(root)}")
raise SystemExit(1 if failed else 0)
