"""Manual-review regressions; synthetic historical snapshots, no external services."""
import json
import unittest
from copy import deepcopy
from html.parser import HTMLParser

from server.dashboard import _catalog_answers, render_record_detail, summarize
from server.questionnaires import MODELS, sheet_schema


class DisclosureParser(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.disclosures = []
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'details' and attrs.get('class') == 'empty-answers':
            self.disclosures.append(attrs)


class DashboardDetailReviewTest(unittest.TestCase):
    def fixture(self):
        record = dict(source_id='woona:review', recording_id='review', dog_id='dog',
                      origin='Woona', dog='Историческая кличка', source='live', date='2026-11-09',
                      ingest_status='complete', capture_status='completed',
                      profile={'answers': {'numberOrName': 'Историческая кличка'}},
                      session_questionnaire={'answers': {'videoRequested': False}}, files=[])
        data = summarize([record], [{'id': 1, 'title': 'Активность', 'labels': []}],
                         {'activity': []}, {}, {})
        return data, data['records'][0]

    def test_empty_rows_collapsed_but_false_zero_and_unknown_visible(self):
        answers = {'emptyNull': None, 'emptyString': '', 'emptyList': [], 'emptyDict': {},
                   'false': False, 'zero': 0, 'unknown': 'unknown', 'no': 'no'}
        original = deepcopy(answers)
        page = _catalog_answers(answers, {})
        visible, collapsed = page.split('<details', 1)
        for key in ('false', 'zero', 'unknown', 'no'):
            self.assertIn('<dt>' + key + '</dt>', visible)
        self.assertIn('<dd>Нет</dd>', visible)
        self.assertIn('<dd>0</dd>', visible)
        for key in ('emptyNull', 'emptyString', 'emptyList', 'emptyDict'):
            self.assertNotIn('<dt>' + key + '</dt>', visible)
            self.assertIn('<dt>' + key + '</dt>', collapsed)
        disclosures = DisclosureParser(page).disclosures
        self.assertEqual(len(disclosures), 1)
        self.assertNotIn('open', disclosures[0])
        self.assertIn('Незаполненные поля (4)', page)
        self.assertEqual(answers, original)

    def test_nested_answers_and_snapshot_text_remain_escaped(self):
        page = _catalog_answers({'<field>': {'list': [False, 0, {'key': 'unknown',
                                 'text': 'Исторический <ответ>'}], 'empty': None}}, {})
        self.assertIn('&lt;field&gt;', page)
        self.assertIn('<li>Нет</li><li>0</li>', page)
        self.assertIn('<li>Исторический &lt;ответ&gt;</li>', page)
        self.assertNotIn('<ответ>', page)
        self.assertNotIn('Код ответа', page)
        self.assertIn('Не указано', page)

    def test_all_schema_field_labels_are_russian_and_snapshot_is_not_changed(self):
        data, record = self.fixture()
        for kind, slot in (('dog', 'profile'), ('session', 'session_questionnaire')):
            answers = {key: 'unknown' for key in sheet_schema(kind)['properties']}
            record[slot] = {'answers': answers}
        heart_keys = json.loads((MODELS / 'heart-questionnaire.schema.json').read_text())['properties']
        record['session_questionnaire']['answers']['heartQuestionnaire'] = {
            key: 'unknown' for key in heart_keys}
        original = deepcopy(record)
        page = render_record_detail(data, record)
        questionnaires = page.split('id="dog-profile"', 1)[1].split('id="technical"', 1)[0]
        for key in set(record['profile']['answers']) | set(record['session_questionnaire']['answers']) | set(heart_keys):
            self.assertNotIn('<dt>' + key + '</dt>', questionnaires, key)
        self.assertIn('<dt>Кличка</dt>', questionnaires)
        self.assertIn('<dt>Измерение пульса</dt>', questionnaires)
        self.assertIn('не текущая анкета собаки', questionnaires)
        self.assertEqual(record, original)

    def test_unavailable_snapshot_is_distinct_from_empty_answers(self):
        data, record = self.fixture()
        record['profile'] = None
        record['session_questionnaire'] = {'answers': {}}
        page = render_record_detail(data, record)
        self.assertIn('Историческая анкета недоступна', page)
        self.assertIn('Нет ответов', page)

    def test_only_explicit_false_marks_video_not_requested(self):
        data, record = self.fixture()
        for flag in (None, True, 0, '', 'false', 'unknown', False):
            with self.subTest(flag=flag):
                record['session_questionnaire'] = {'answers': {'videoRequested': flag}}
                page = render_record_detail(data, record)
                self.assertEqual('<h2>Видео не запрашивалось</h2>' in page, flag is False)
                self.assertEqual('<h2>Видео недоступно</h2>' in page, flag is not False)
        for session in (None, {}, {'answers': {}}, {'answers': None}):
            record['session_questionnaire'] = session
            self.assertIn('<h2>Видео недоступно</h2>', render_record_detail(data, record))

    def test_available_video_wins_over_false_and_unavailable_file_does_not(self):
        data, record = self.fixture()
        record['files'] = [{'name': 'video.mp4', 'relative': 'woona/review/video.mp4',
                            'type': 'video', 'available': True, 'size': 4}]
        page = render_record_detail(data, record)
        self.assertIn('<video controls preload="metadata"', page)
        self.assertNotIn('<h2>Видео не запрашивалось</h2>', page)
        record['files'][0]['available'] = False
        page = render_record_detail(data, record)
        self.assertNotIn('<video', page)
        self.assertIn('<h2>Видео не запрашивалось</h2>', page)
        self.assertNotIn('Файл ещё не передан', page)


if __name__ == '__main__':
    unittest.main()
