"""Explicit held-out test entry point. Use llm.evaluate while tuning."""

from .evaluate import main


if __name__ == "__main__":
    main(test_only=True)
