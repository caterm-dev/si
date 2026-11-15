"""Public movie-title coverage, language separation and reviewed pronunciation checks."""
import csv
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import csv_dictionary as dictionary


def movie_rows(language):
    with (ROOT / 'Data' / language.title() / 'movie.csv').open(encoding='utf-8', newline='') as stream:
        return list(csv.DictReader(stream))


class MovieVocabularyTests(unittest.TestCase):
    def test_movie_categories_have_unique_valid_readings(self):
        for language in ('chinese', 'english'):
            rows = movie_rows(language)
            self.assertTrue(rows)
            self.assertEqual(len({(row['reading'], row['text']) for row in rows}), len(rows))
            for row in rows:
                self.assertGreaterEqual(dictionary.integer(row['weight'], 0, 'count'), 0)
                if language == 'english':
                    self.assertEqual(row['reading'], dictionary.english_reading(row['text']))

    def test_movie_names_keep_reviewed_polyphonic_and_umlaut_readings(self):
        identities = {(row['text'], row['reading']) for row in movie_rows('chinese')}
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
