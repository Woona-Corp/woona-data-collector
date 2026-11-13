"""Synthetic catalog rendering: no database, network or private recordings."""
import unittest
from copy import deepcopy
from html.parser import HTMLParser

from server.dashboard import render, render_record_detail, summarize


class Elements(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.elements = []
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class DashboardCatalogTest(unittest.TestCase):
    def fixture(self):
        records = []
        for identity, dog, account, started, source, duration in (
            ('one', 'Альфа <пёс>', 'account-a', '2026-11-09T01:00:00+03:00', 'live', 3600),
            ('two', 'Бета', 'account-b', '2026-11-09T23:59:59Z', 'replay', 7200),
            ('three', 'Гамма', None, '2026-11-10T00:00:00Z', 'live', None),
        ):
            records.append(dict(source_id='woona:' + identity, recording_id=identity, dog_id='dog-' + identity,
                origin='Woona', dog=dog, account_id=account, account_name='Имя ' + account if account else None,
                date=started[:10], started_at=started, ended_at=None, duration_seconds=duration,
                source=source, session_label='Сессия ' + identity, ingest_status='complete', capture_status='completed',
                profile={'version_id': 'v1', 'answers': {'numberOrName': dog, 'weightKg': 15}},
                session_questionnaire={'answers': {'schemaVersion': 2, 'plannedActivities': ['Активность'],
                    'videoRequested': True, 'notes': '<script>bad()</script>', 'nested': {'list': ['первый', 'второй']}}},
                files=[{'name': 'video.mp4', 'relative': 'woona/' + identity + '/video.mp4', 'size': 4,
                        'type': 'video', 'available': True, 'storage_status': 'available'},
                       {'name': 'sensor.bin', 'relative': 'woona/' + identity + '/sensor.bin', 'size': 4,
                        'type': 'packet', 'available': True}]))
        data = summarize(records, [{'id': 21, 'title': 'Активность', 'timeline_name': 'labels', 'labels': []}],
                         {'activity': []}, {}, {'dogs': 3, 'profile_versions': 3, 'session_questionnaires': 3})
        # Rendering fixtures isolate status presentation from eligibility contract details.
        for record in data['records']:
            record['eligible'] = True
            record['exclusion_reasons'] = []
        return data

    def test_search_account_and_inclusive_utc_dates(self):
        data = self.fixture()
        page = render(data, '', account='account-a', date_from='2026-11-08', date_to='2026-11-08')
        self.assertIn('Найдено 1 из 3 записей', page)
        self.assertIn('08.11.2026 22:00:00 UTC', page)
        self.assertIn('Альфа &lt;пёс&gt;', page)
        self.assertNotIn('Сессия two', page)
        self.assertIn('Найдено 1 из 3 записей', render(data, 'Имя account-b'))
        self.assertIn('Найдено 1 из 3 записей', render(data, 'dog-one'))
        self.assertIn('Найдено 1 из 3 записей', render(data, '', account='__unassigned__'))
        self.assertIn('Найдено 0 из 3 записей', render(data, '', account='account-a', date_from='2026-11-09'))
        self.assertIn('Найдено 1 из 3 записей', render(data, '', date_from='2026-11-09', date_to='2026-11-09'))

    def test_scoped_hours_exclude_replay_unknown_and_negative(self):
        data = self.fixture()
        page = render(data, '')
        self.assertIn('Часы сессий съёмки</span><strong>1.00</strong>', page)
        self.assertIn('Replay: 1 (исключены из часов); длительность неизвестна: 1', page)
        self.assertIn('не оценка качества видео или сигнала', page)
        self.assertIn('Часы сессий съёмки</span><strong>0.00</strong>', render(data, '', account='account-b'))
        for record in data['records']:
            record['duration_seconds'] = -1
        self.assertIn('длительность неизвестна: 3', render(data, ''))
        data['records'][0]['duration_seconds'] = float('nan')
        self.assertIn('длительность неизвестна: 3', render(data, ''))

    def test_outage_is_unknown_no_task_links_or_false_awaiting(self):
        data = self.fixture()
        record = data['records'][0]
        record['tasks'] = {'activity': {'id': 42, 'labeled': True}}
        record['annotated_any'] = record['annotated_all'] = True
        data['label_service'] = {'available': False, 'message': 'Сервис временно недоступен <private>'}
        self.assertIn('Недоступно', render(data, ''))
        for page in (render(data, ''), render_record_detail(data, record)):
            self.assertIn('наличие задачи не проверено', page)
            self.assertNotIn('ожидают импорта 0', page)
            self.assertNotIn('/data?task=', page)
            self.assertNotIn('Ожидает разметки', page)
            self.assertIn('&lt;private&gt;', page)
        for status in ('complete', 'awaiting_annotation'):
            page = render(data, '', status=status)
            self.assertIn('Выборка по разметке сейчас недоступна', page)
            self.assertNotIn('Найдено 0 из 3 записей', page)

    def test_detail_available_video_only_semantic_questionnaires_and_file_errors(self):
        data = self.fixture()
        record = next(r for r in data['records'] if r['recording_id'] == 'one')
        record['files'].append({'name': 'broken<file>.mp4', 'relative': 'never-link-this', 'size': 20,
            'available': False, 'storage_status': 'available', 'error_code': 'stored_file_missing',
            'error_message': 'Сохраните <оригинал>'})
        record['server_status'] = {'transfer': {'status': 'integrity_problem'},
            'artifacts': [{'id': 'missing', 'fileName': 'broken<file>.mp4', 'errorCode': 'stored_file_missing'}]}
        page = render_record_detail(data, record)
        parsed = Elements(page).elements
        videos = [attrs for tag, attrs in parsed if tag == 'video']
        self.assertEqual(len(videos), 1)
        self.assertIn('controls', videos[0])
        self.assertEqual(videos[0]['preload'], 'metadata')
        self.assertNotIn('autoplay', videos[0])
        self.assertTrue(videos[0]['src'].startswith('/data/local-files/?d='))
        self.assertNotIn('never-link-this', page)
        self.assertIn('Проблема целостности — сохраните локальные оригиналы', page)
        self.assertIn('Кличка', page)
        self.assertIn('Вес, кг', page)
        self.assertIn('<li>первый</li>', page)
        self.assertIn('не текущая анкета собаки', page)
        self.assertIn('stored_file_missing', page)
        self.assertIn('Сохраните &lt;оригинал&gt;', page)
        self.assertIn('stored_file_missing', render(data, 'one'))
        record['files'][0]['available'] = False
        self.assertNotIn('<video', render_record_detail(data, record))

    def test_escaping_task_ids_urls_and_no_automatic_refresh(self):
        data = self.fixture()
        record = data['records'][0]
        record['tasks'] = {'activity': {'id': '1&x="<img>', 'labeled': False}}
        record['recording_id'] = '../x" onfocus="bad'
        record['files'][0]['relative'] = 'woona/<file>"&.mp4'
        record['account_name'] = '<img src=x onerror=bad>'
        for page in (render(data, '"<img>'), render_record_detail(data, record)):
            self.assertNotIn('<img', page)
            self.assertNotIn('<script', page)
            self.assertNotIn('http-equiv="refresh"', page)
            self.assertIn('Обновить вручную', page)
            self.assertIn('Обновлено:', page)
            for _, attrs in Elements(page).elements:
                self.assertNotIn('onfocus', attrs)
                self.assertNotIn('onerror', attrs)
        detail = render_record_detail(data, record)
        self.assertIn('task=1%26x%3D%22%3Cimg%3E', detail)
        self.assertIn('/references', detail)
        self.assertIn('загрузка контрольного файла', detail)
        self.assertNotIn('/data?task=', render(data, ''))

    def test_quick_filters_and_legacy_positional_api(self):
        data = self.fixture()
        record = data['records'][0]
        record['server_status'] = {'transfer': {'status': 'uploading', 'stalled': True}}
        record['video'] = False
        self.assertIn('Найдено 1 из 3 записей', render(data, '', status='upload_problem'))
        self.assertIn('Найдено 1 из 3 записей', render(data, '', status='no_video'))
        self.assertIn('Найдено 1 из 3 записей', render(data, '', 'incomplete', 'all', 1))
        self.assertIn('Нет прогресса ≥15 минут', render(data, ''))
        record['video'] = True
        record['tasks'] = {'activity': {'id': 2, 'labeled': False}}
        self.assertIn('Найдено 1 из 3 записей', render(data, '', 'ready', 'all', 1))
        self.assertIn('Найдено 3 из 3 записей', render(data, '', status='awaiting_annotation'))
        record['annotated_all'] = record['annotated_any'] = True
        self.assertIn('Найдено 1 из 3 записей', render(data, '', status='complete'))
        self.assertIn('Найдено 0 из 3 записей', render(data, '', ble='absent'))

    def test_reference_only_failure_is_an_upload_problem_without_invalidating_capture(self):
        data = self.fixture()
        record = data['records'][0]
        record['server_status'] = {
            'transfer': {'status': 'verified', 'stalled': False},
            'artifacts': [{'id': 'reference', 'type': 'ecg', 'storageStatus': 'uploading',
                           'partOfCaptureReceipt': False, 'errorCode': 'upload_interrupted',
                           'errorMessage': 'Продолжите загрузку контрольного файла'}]}
        record['files'].append({'id': 'reference', 'name': 'ecg.csv', 'type': 'ecg',
                                'available': False, 'storage_status': 'uploading', 'size': 100})
        page = render(data, '', status='upload_problem')
        self.assertIn('Найдено 1 из 3 записей', page)
        self.assertIn('upload_interrupted', page)
        self.assertIn('Передано полностью</span><strong>1</strong>', page)
        self.assertIn('Проблемы передачи</span><strong>1</strong>', page)

    def test_annotation_does_not_hide_current_exclusion(self):
        data = self.fixture()
        record = data['records'][0]
        record['annotated_any'] = True
        record['exclusion_reasons'] = ['Проверка целостности не подтверждена']
        page = render_record_detail(data, record)
        self.assertIn('Есть разметка; сейчас не допущено:', page)
        self.assertIn('Проверка целостности не подтверждена', page)

    def test_pagination_keeps_filters_escaped_and_empty_state(self):
        data = self.fixture()
        original = data['records'][0]
        data['records'] = [deepcopy(original) for _ in range(30)]
        page = render(data, '', account=original['account_id'], date_from='2026-11-01', date_to='2026-11-30', page=2)
        self.assertIn('Показано 26–30 из 30', page)
        self.assertIn('date_from=2026-11-01&amp;date_to=2026-11-30', page)
        self.assertIn('Записей не найдено', render(data, 'no-such-record'))


if __name__ == '__main__':
    unittest.main()
