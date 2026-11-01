"""Public movie-title coverage, language separation and reviewed pronunciation checks."""
import csv
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import csv_dictionary as dictionary


class MovieVocabularyTests(unittest.TestCase):
    def test_catalog_covers_twenty_years_and_both_language_categories(self):
        data = ROOT / 'Data/Vocabulary'
        with (data / 'movie-catalog.csv').open() as stream:
            catalog = list(csv.DictReader(stream))
        with (data / 'chinese/movie.csv').open() as stream:
            chinese = list(csv.DictReader(stream))
        with (data / 'english/movie.csv').open() as stream:
            english = list(csv.DictReader(stream))
        self.assertEqual({int(row['year']) for row in catalog}, set(range(2007, 2027)))
        self.assertEqual(len({(row['year'], row['chinese']) for row in catalog}), len(catalog))
        zh_texts = {row['text'] for row in chinese}
        en_identities = {(row['reading'], row['text'].lower()) for row in english}
        for row in catalog:
            with self.subTest(title=row['chinese']):
                self.assertIn(row['chinese'], zh_texts)
                self.assertIn((dictionary.english_reading(row['english']), row['english'].lower()), en_identities)
        for rows in (chinese, english):
            self.assertEqual(len({(r['reading'], r['text']) for r in rows}), len(rows))
        curation = next(r for r in json.loads((data / 'meta.json').read_text())['curations']
                        if r['id'] == 'movie-titles-2007-2026')
        self.assertEqual(curation['films'], len(catalog))
        self.assertEqual(curation['catalog_sha256'], hashlib.sha256((data / 'movie-catalog.csv').read_bytes()).hexdigest())

    def test_movie_names_keep_reviewed_polyphonic_and_umlaut_readings(self):
        path = ROOT / 'Data/Vocabulary/chinese/movie.csv'
        with path.open() as stream:
            identities = {(row['text'], row['reading']) for row in csv.DictReader(stream)}
        for text, reading in [('长安三万里', "chang'an'san'wan'li"),
                              ('哪吒之魔童闹海', "ne'zha'zhi'mo'tong'nao'hai"),
                              ('封神第一部：朝歌风云', "feng'shen'di'yi'bu'zhao'ge'feng'yun"),
                              ('西游·降魔篇', "xi'you'xiang'mo'pian"),
                              ('驴得水', "lv'de'shui"), ('爱乐之城', "ai'yue'zhi'cheng"),
                              ('失恋33天', "shi'lian'san'shi'san'tian"),
                              ('熊出没·年年有熊', "xiong'chu'mo'nian'nian'you'xiong")]:
            self.assertIn((text, reading), identities)


if __name__ == '__main__':
    unittest.main()
