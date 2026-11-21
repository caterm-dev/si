"""Project exported trees onto the lexical candidate features used by the app."""

import argparse
import json
from pathlib import Path


# Values supplied for every lexical row when generation was disabled.
LEGACY_SOURCE_VALUES = {
    "from_si_engine": 1,
    "from_pinyin_model": 0,
    "pinyin_model_beam_rank": None,
}
LEGACY_METADATA = ("pinyin_checkpoint_sha256", "beam_size")


def project_ranker(document):
    names = document["feature_names"]
    retained = [name for name in names if name not in LEGACY_SOURCE_VALUES]
    indices = {name: index for index, name in enumerate(retained)}

    def project(node):
        kind = node["kind"]
        if kind == "leaf":
            return node
        feature = node["feature"]
        if type(feature) is not int or not 0 <= feature < len(names):
            raise ValueError("Invalid LambdaRank split feature")
        name = names[feature]
        if name not in LEGACY_SOURCE_VALUES:
            return {**node, "feature": indices[name],
                    "left": project(node["left"]), "right": project(node["right"])}

        value = LEGACY_SOURCE_VALUES[name]
        if kind == "categorical":
            take_left = value in node["categories"]
        elif kind == "numeric":
            missing = node["missing"]
            if (missing == "NaN" and value is None) or (missing == "Zero" and not value):
                take_left = node["default_left"]
            else:
                take_left = (value or 0) <= node["threshold"]
        else:
            raise ValueError("Unsupported LambdaRank split type")
        return project(node["left" if take_left else "right"])

    return {**{name: value for name, value in document.items() if name not in LEGACY_METADATA},
            "feature_names": retained, "trees": [project(tree) for tree in document["trees"]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        with args.source.open(encoding="utf-8") as stream:
            document = project_ranker(json.load(stream))
        args.destination.write_text(json.dumps(document, allow_nan=False) + "\n", encoding="utf-8")
    except (KeyError, OSError, TypeError, ValueError) as error:
        parser.exit(2, f"SI ranking projection: {error}\n")


if __name__ == "__main__":
    main()
