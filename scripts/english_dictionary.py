#!/usr/bin/env python3
"""Compatibility entry point for SI's maintained English category CSV dictionary."""

import argparse
import csv
import sqlite3

from csv_dictionary import build as build_csv


def build(check=False):
    build_csv(check=check, language='english')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('build', help='Compile English CSV categories offline').add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        build(args.check)
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, csv.Error, sqlite3.DatabaseError) as error:
        parser.exit(1, f'English dictionary error: {error}\n')


if __name__ == '__main__':
    main()
