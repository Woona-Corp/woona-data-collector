"""Workspace UX contracts using synthetic records and authenticated local routes only."""
import io
import unittest
import uuid
from copy import deepcopy
from html.parser import HTMLParser
from unittest.mock import patch
from urllib.parse import parse_qs, urlencode, urlsplit

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server import dashboard
from server.tests import test_dashboard_catalog as catalog_fixture


class Document(HTMLParser):
    """Tiny DOM for semantic assertions, independent of styling and SVG markup."""

    def __init__(self, page):
        super().__init__()
        self.root = {'tag': 'document', 'attrs': {}, 'children': []}
        self.stack = [self.root]
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        node = {'tag': tag, 'attrs': dict(attrs), 'children': []}
        self.stack[-1]['children'].append(node)
        if tag not in {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
                       'link', 'meta', 'param', 'source', 'track', 'wbr'}:
            self.stack.append(node)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index]['tag'] == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        self.stack[-1]['children'].append(data)

    @classmethod
    def text(cls, node):
        if isinstance(node, str):
            return node
        return ''.join(cls.text(child) for child in node['children'])

    def find(self, tag=None, within=None, **attrs):
        found = []

        def visit(node):
            if isinstance(node, str):
                return
            if (tag is None or node['tag'] == tag) and all(
                    node['attrs'].get(key) == value for key, value in attrs.items()):
                found.append(node)
            for child in node['children']:
                visit(child)

        visit(within or self.root)
        return found


def query(link):
    return {key: values[0] for key, values in
            parse_qs(urlsplit(link['attrs']['href']).query, keep_blank_values=True).items()}


class DashboardWorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.data = catalog_fixture.DashboardCatalogTest().fixture()
        self.data['records'].sort(key=lambda record: record['recording_id'])

    def test_catalog_is_a_captioned_table_with_scoped_headers_not_record_articles(self):
        doc = Document(dashboard.render(self.data, ''))
        table, = doc.find('table')
        caption, = doc.find('caption', within=table)
        self.assertIn('съёмки, передачи файлов и разметки', doc.text(caption))
        headers = doc.find('th', within=table)
        self.assertEqual([doc.text(h) for h in headers], [
            'Собака / сессия', 'Дата (UTC)', 'Длительность', 'Съёмка',
            'Передача', 'Разметка', 'Открыть запись'])
        self.assertTrue(all(h['attrs'].get('scope') == 'col' for h in headers))
        body, = doc.find('tbody', within=table)
        rows = doc.find('tr', within=body)
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(len(doc.find('td', within=row)) == len(headers) for row in rows))
        self.assertEqual({row['attrs']['data-record-id'] for row in rows}, {'one', 'two', 'three'})
        self.assertFalse(doc.find('article'), 'Records must not regress to giant article cards')

    def test_independent_capture_transfer_label_states_have_text_not_just_color(self):
        record = self.data['records'][0]
        record['capture_status'] = 'interrupted'
        record['server_status'] = {'transfer': {'status': 'verified'}}
        record['annotated_any'] = True
        doc = Document(dashboard.render(self.data, record['recording_id']))
        row, = doc.find('tr', **{'data-record-id': record['recording_id']})
        for column, expected in [('Съёмка', 'Прервана'), ('Передача', 'Подтверждена'),
                                 ('Разметка', 'Есть разметка')]:
            cell, = doc.find('td', within=row, **{'data-label': column})
            self.assertIn(expected, doc.text(cell))
        detail = Document(dashboard.render_record_detail(self.data, record))
        for text in ('Съёмка', 'Прервана', 'Передача на сервер', 'Подтверждена', 'Разметка', 'Есть разметка'):
            self.assertIn(text, detail.text(detail.root))

    def test_sidebar_counts_all_actual_accounts_even_when_catalog_is_empty(self):
        self.data['records'].append(deepcopy(self.data['records'][0]))
        doc = Document(dashboard.render(self.data, 'no match', account='account-a'))
        nav, = doc.find('nav', **{'aria-label': 'Аккаунты'})
        links = {query(link)['account']: link for link in doc.find('a', within=nav)}
        for account, label, count in [('', 'Все аккаунты', 4), ('__unassigned__', 'Без аккаунта', 1),
                                      ('account-a', 'Имя account-a', 2), ('account-b', 'Имя account-b', 1)]:
            self.assertEqual(doc.text(links[account]), label + str(count))
        self.assertEqual(links['account-a']['attrs']['aria-current'], 'page')

    def test_tabs_are_scoped_and_unavailable_label_counts_are_unknown_not_zero(self):
        self.data['records'][0]['video'] = False
        self.data['records'][1]['annotated_all'] = True
        for available in (True, False):
            with self.subTest(available=available):
                self.data['label_service'] = {'available': available, 'message': 'offline'}
                doc = Document(dashboard.render(self.data, '', account='account-a', status='no_video'))
                nav, = doc.find('nav', **{'aria-label': 'Быстрые фильтры'})
                tabs = {query(link)['status']: link for link in doc.find('a', within=nav)}
                self.assertEqual(doc.text(tabs['all']).strip(), 'Все записи 1')
                self.assertEqual(doc.text(tabs['no_video']).strip(), 'Без видео 1')
                for status in ('awaiting_annotation', 'complete'):
                    text = doc.text(tabs[status])
                    if available:
                        self.assertTrue(text.endswith('1' if status == 'awaiting_annotation' else '0'))
                    else:
                        self.assertIn('—', text)
                        self.assertIn('недоступно', text)
                        self.assertNotIn('0', text)
                self.assertTrue(all(query(link)['account'] == 'account-a' for link in tabs.values()))

    def test_unavailable_label_filter_never_becomes_empty_zero_summary(self):
        self.data['label_service'] = {'available': False, 'message': 'offline'}
        params = dict(q='Сессия', account='account-a', date_from='2026-11-01',
                      date_to='2026-11-30', ble='present')
        for status in ('complete', 'awaiting_annotation', 'ready', 'in_progress'):
            with self.subTest(status=status):
                doc = Document(dashboard.render(self.data, params['q'], status=status,
                    account=params['account'], date_from=params['date_from'],
                    date_to=params['date_to'], ble=params['ble']))
                summary, = doc.find('section', **{'aria-label': 'Сводка выбранных записей'})
                self.assertEqual([doc.text(n) for n in doc.find('strong', within=summary)],
                                 ['Недоступно', '—', '—', '—', 'Недоступно'])
                self.assertEqual([doc.text(h) for h in doc.find('h2')], ['Не удалось проверить разметку'])
                recovery, = [a for a in doc.find('a') if doc.text(a) == 'Показать все записи']
                self.assertEqual(query(recovery), {**params, 'status': 'all', 'page': '1'})
                self.assertNotIn('Найдено 0', doc.text(doc.root))
                self.assertFalse(doc.find('nav', **{'aria-label': 'Страницы каталога'}))

    def filtered_page(self):
        record = deepcopy(self.data['records'][0])
        record['video'] = False
        record['ble'] = True
        self.data['records'] = [deepcopy(record) for _ in range(60)]
        params = dict(q='Сессия', account=record['account_id'], date_from='2026-11-01',
                      date_to='2026-11-30', status='no_video', ble='present')
        page = dashboard.render(self.data, params['q'], page=2,
                                **{k: v for k, v in params.items() if k != 'q'})
        return Document(page), {**params, 'page': '2'}

    def test_individual_filter_removal_resets_page_but_keeps_every_other_filter(self):
        doc, params = self.filtered_page()
        chips = [link for link in doc.find('a')
                 if link['attrs'].get('aria-label', '').startswith('Убрать фильтр:')]
        self.assertEqual(len(chips), 6)
        removed = set()
        for link in chips:
            actual = query(link)
            changed = [key for key in params if key != 'page' and actual.get(key) != params[key]]
            self.assertEqual(len(changed), 1)
            key, = changed
            removed.add(key)
            expected = {**params, key: 'all' if key in ('status', 'ble') else '', 'page': '1'}
            self.assertEqual(actual, expected)
            self.assertEqual(urlsplit(link['attrs']['href']).fragment, 'data-manager')
        self.assertEqual(removed, set(params) - {'page'})

    def test_pagination_and_open_detail_preserve_full_filter_context(self):
        doc, params = self.filtered_page()
        nav, = doc.find('nav', **{'aria-label': 'Страницы каталога'})
        links = doc.find('a', within=nav)
        self.assertEqual({query(link)['page'] for link in links}, {'1', '2', '3'})
        for link in links:
            self.assertEqual(query(link), {**params, 'page': query(link)['page']})
        opens = [link for link in doc.find('a')
                 if link['attrs'].get('aria-label', '').startswith('Открыть запись ')]
        self.assertEqual(len(opens), 25)
        for link in opens:
            back = query(link)['back']
            self.assertEqual(urlsplit(back).path, '/dashboard')
            self.assertEqual(dict(parse_qs(urlsplit(back).query, keep_blank_values=True)),
                             {key: [value] for key, value in params.items()})
            detail = Document(dashboard.render_record_detail(self.data, self.data['records'][0], back))
            backlink, = [a for a in detail.find('a') if 'К выборке записей' in detail.text(a)]
            self.assertEqual(backlink['attrs']['href'], back)

    def test_available_files_have_download_actions_unavailable_files_have_no_url(self):
        record = self.data['records'][0]
        record['files'].append(dict(name='missing.mp4', relative='must-never-be-linked',
                                    available=False, storage_status='available', size=8, type='video'))
        doc = Document(dashboard.render_record_detail(self.data, record))
        section, = doc.find('section', id='files')
        items = doc.find('li', within=section)
        self.assertEqual(len(items), 3)
        for item in items:
            links = doc.find('a', within=item)
            if 'missing.mp4' in doc.text(item):
                self.assertFalse(links)
                self.assertIn('Недоступен', doc.text(item))
            else:
                downloads = [a for a in links if 'download' in a['attrs']]
                self.assertEqual(len(downloads), 1)
                self.assertTrue(downloads[0]['attrs']['aria-label'].startswith('Скачать '))
                self.assertTrue(downloads[0]['attrs']['href'].startswith('/data/local-files/?d='))
        self.assertFalse(any('must-never-be-linked' in n['attrs'].get('href', '') or
                             'must-never-be-linked' in n['attrs'].get('src', '') for n in doc.find()))

    def test_empty_initial_and_filtered_empty_explain_different_next_steps(self):
        filtered = Document(dashboard.render(self.data, 'no-match'))
        self.data['records'] = []
        initial = Document(dashboard.render(self.data, ''))
        self.assertEqual([filtered.text(h) for h in filtered.find('h2')], ['Записей не найдено'])
        self.assertEqual([initial.text(h) for h in initial.find('h2')], ['Записей пока нет'])
        self.assertIn('Измените запрос или сбросьте фильтры.', filtered.text(filtered.root))
        self.assertIn('сессии, отправленные с устройств', initial.text(initial.root))
        self.assertFalse(initial.find('table'))
        self.assertFalse(filtered.find('table'))

    def test_technical_tools_are_reachable_outside_collapsing_account_sidebar(self):
        doc = Document(dashboard.render(self.data, ''))
        sidebar, = doc.find('aside', **{'aria-label': 'Навигация проекта'})
        tools, = doc.find('nav', **{'aria-label': 'Технические инструменты'})
        self.assertNotIn(tools, doc.find('nav', within=sidebar))
        self.assertEqual({link['attrs']['href'] for link in doc.find('a', within=tools)},
                         {'/dashboard/data', '/db/woona/', '/db/labels/', '/files/'})
        self.assertEqual(len(doc.find('summary', **{'aria-label': 'Технические инструменты'})), 1)

    def test_no_checkbox_or_fake_bulk_actions_on_catalog_or_detail(self):
        for page in (dashboard.render(self.data, ''),
                     dashboard.render_record_detail(self.data, self.data['records'][0])):
            doc = Document(page)
            self.assertFalse(doc.find('input', type='checkbox'))
            self.assertFalse(doc.find(role='checkbox'))
            actions = doc.find('button') + doc.find('a')
            for action in actions:
                text = doc.text(action).casefold()
                for fake in ('выбрать все', 'выделить все', 'массов', 'удалить выбран', 'экспорт выбран'):
                    self.assertNotIn(fake, text)


class DashboardWorkspaceRoutesTest(unittest.TestCase):
    def setUp(self):
        self.data = catalog_fixture.DashboardCatalogTest().fixture()
        self.record = self.data['records'][0]
        self.record['recording_id'] = str(uuid.uuid4())
        api = FastAPI()
        api.include_router(dashboard.router)
        self.client = TestClient(api)
        self.addCleanup(self.client.close)
        self.headers = {'Cookie': 'session=synthetic'}
        loader = patch.object(dashboard, 'load_dashboard', return_value=self.data)
        self.loader = loader.start()
        self.addCleanup(loader.stop)
        auth = patch.object(dashboard, 'urlopen', side_effect=lambda *a, **k:
                            io.BytesIO(b'{"permissions":["projects.view"]}'))
        auth.start()
        self.addCleanup(auth.stop)
        self.path = '/dashboard/recordings/' + self.record['recording_id']

    def test_detail_route_renders_safe_return_and_rejects_external_or_invalid_back(self):
        safe = '/dashboard?' + urlencode(dict(q='пёс & <tag>', account='account-a',
            date_from='2026-11-01', date_to='2026-11-30', status='no_video', ble='present', page=2))
        for back, expected in [(safe, safe + '#data-manager'),
                               ('https://evil.example/dashboard', '/dashboard'),
                               ('//evil.example/dashboard', '/dashboard'),
                               ('javascript:alert(1)', '/dashboard'),
                               ('http://[invalid', '/dashboard'),
                               ('/dashboard/../elsewhere', '/dashboard'),
                               ('/other', '/dashboard'), ('', '/dashboard')]:
            with self.subTest(back=back):
                response = self.client.get(self.path, params={'back': back}, headers=self.headers)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.headers['cache-control'], 'no-store')
                doc = Document(response.text)
                link, = [a for a in doc.find('a') if 'К выборке записей' in doc.text(a)]
                self.assertEqual(link['attrs']['href'], expected)
                self.assertFalse(urlsplit(link['attrs']['href']).netloc)
                self.assertFalse(urlsplit(link['attrs']['href']).scheme)

    def test_workspace_read_routes_still_require_a_label_studio_session(self):
        for path in ('/dashboard', '/dashboard/data', self.path):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 401)
        self.loader.assert_not_called()
        with patch.object(dashboard, 'urlopen', side_effect=lambda *a, **k:
                          io.BytesIO(b'{"permissions":[]}')):
            self.assertEqual(self.client.get(self.path, headers=self.headers).status_code, 403)
        self.loader.assert_not_called()

    def test_back_length_validated_before_loading_snapshot(self):
        prefix = '/dashboard?q='
        boundary = prefix + 'x' * (2048 - len(prefix))
        self.assertEqual(self.client.get(self.path, params={'back': boundary},
                                         headers=self.headers).status_code, 200)
        self.loader.reset_mock()
        response = self.client.get(self.path, params={'back': boundary + 'x'}, headers=self.headers)
        self.assertEqual(response.status_code, 422)
        self.loader.assert_not_called()


if __name__ == '__main__':
    unittest.main()
