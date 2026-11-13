"""Regression contracts for the production manual-review findings; synthetic data only."""
import io
import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server import dashboard
from server.tests import test_dashboard_catalog as catalog_fixture
from server.tests.test_dashboard_workspace import Document


class DashboardManualReviewTest(unittest.TestCase):
    def setUp(self):
        self.data = catalog_fixture.DashboardCatalogTest().fixture()
        api = FastAPI()
        api.include_router(dashboard.router)
        self.client = TestClient(api)
        self.addCleanup(self.client.close)
        loader = patch.object(dashboard, 'load_dashboard', return_value=self.data)
        self.loader = loader.start()
        self.addCleanup(loader.stop)
        auth = patch.object(dashboard, 'urlopen', side_effect=lambda *a, **k:
                            io.BytesIO(b'{"permissions":["projects.view"]}'))
        auth.start()
        self.addCleanup(auth.stop)

    def test_calendar_errors_are_html_no_store_and_preserve_filters_without_false_zero(self):
        for dates, message in [({'date_from': '2026-11-09', 'date_to': '2026-11-01'},
                                 'Начало периода должно быть не позже окончания'),
                                ({'date_to': '2026-02-30'}, 'Укажите существующую дату')]:
            with self.subTest(dates=dates):
                self.loader.reset_mock()
                params = dict(q='<пёс>', account='account-a', status='no_video', ble='absent', **dates)
                response = self.client.get('/dashboard', params=params, headers={'Cookie': 'synthetic=1'})
                self.assertEqual(response.status_code, 422)
                self.assertIn('text/html', response.headers['content-type'])
                self.assertEqual(response.headers['cache-control'], 'no-store')
                doc = Document(response.text)
                alert, = doc.find('p', id='catalog-date-error', role='alert')
                self.assertIn(message, doc.text(alert))
                toolbar, = doc.find('form', **{'aria-label': 'Фильтры записей'})
                inputs = {node['attrs'].get('name'): node['attrs'] for node in doc.find('input', within=toolbar)}
                self.assertEqual(inputs['q']['value'], params['q'])
                for name, value in dates.items():
                    self.assertEqual(inputs[name]['value'], value)
                    self.assertEqual(inputs[name]['aria-invalid'], 'true')
                for name in ('account', 'status', 'ble'):
                    select, = doc.find('select', within=toolbar, name=name)
                    # HTMLParser represents present boolean attributes with None.
                    selected = [n for n in doc.find('option', within=select) if 'selected' in n['attrs']]
                    self.assertEqual(len(selected), 1)
                    self.assertEqual(selected[0]['attrs']['value'], params[name])
                metrics, = doc.find('section', **{'aria-label': 'Сводка выбранных записей'})
                self.assertEqual([doc.text(node) for node in doc.find('strong', within=metrics)], ['—'] * 5)
                self.assertIn('Некорректный период: выборка не рассчитана', response.text)
                self.assertNotIn('Найдено 0', response.text)
                self.assertNotIn('Записей не найдено', response.text)
                self.assertNotIn('Страницы каталога', response.text)
                self.loader.assert_called_once()

    def test_date_error_does_not_bypass_authentication(self):
        response = self.client.get('/dashboard?date_from=2026-11-09&date_to=2026-11-01')
        self.assertEqual(response.status_code, 401)
        self.loader.assert_not_called()

    def test_download_uses_escaped_original_filename_only_for_available_files(self):
        record = {'files': [
            {'name': 'sync.json', 'relative': 'woona/test/sync.json', 'available': True, 'size': 1},
            {'name': 'замер "<пёс>".csv', 'relative': 'woona/test/reference.csv', 'available': True, 'size': 2},
            {'name': 'missing.bin', 'relative': 'never-link-this', 'available': False, 'size': 3},
        ]}
        result = dashboard._catalog_files(record)
        links = [attrs for tag, attrs in catalog_fixture.Elements(result).elements if tag == 'a' and 'download' in attrs]
        self.assertEqual([link['download'] for link in links], ['sync.json', 'замер "<пёс>".csv'])
        self.assertNotIn('never-link-this', result)
        self.assertNotIn('<пёс>', result)


if __name__ == '__main__':
    unittest.main()
