"""Browser login navigation must not change JSON/write auth contracts."""
import io
import unittest
import uuid
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from fastapi.testclient import TestClient

from server import dashboard
from server.app import app
from server.tests import test_dashboard_catalog as fixture


class DashboardLoginTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app, follow_redirects=False)
        self.addCleanup(self.client.close)
        loader = patch.object(dashboard, 'load_dashboard', return_value=fixture.DashboardCatalogTest().fixture())
        self.loader = loader.start()
        self.addCleanup(loader.stop)
        self.html = {'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}
        self.recording = '/dashboard/recordings/' + str(uuid.uuid4())

    def assert_login(self, response, destination):
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        location = urlsplit(response.headers['location'])
        self.assertEqual((location.scheme, location.netloc, location.path), ('', '', '/user/login/'))
        self.assertEqual(parse_qs(location.query), {'next': [destination]})
        self.loader.assert_not_called()

    def test_browser_pages_redirect_without_cookie_and_keep_complete_local_destination(self):
        for destination in ('/dashboard', '/dashboard?q=%D0%BF%D1%91%D1%81&account=clinic&page=2',
                            self.recording + '?back=%2Fdashboard%3Fpage%3D2', self.recording + '/references',
                            '/dashboard?next=https%3A%2F%2Fevil.invalid%2F'):
            with self.subTest(destination=destination):
                self.assert_login(self.client.get(destination, headers=self.html), destination)

    def test_document_navigation_redirects_even_when_viewer_negotiates_json(self):
        self.assert_login(self.client.get('/dashboard', headers={
            'Accept': 'application/json', 'Sec-Fetch-Mode': 'navigate'}), '/dashboard')
        response = self.client.get('/dashboard/data', headers={
            'Accept': 'text/html', 'Sec-Fetch-Mode': 'navigate'})
        self.assertEqual(response.status_code, 401)
        self.assertNotIn('location', response.headers)

    def test_expired_or_irrelevant_cookie_redirects_like_anonymous_navigation(self):
        for code in (401, 403):
            with self.subTest(upstream_status=code), patch.object(dashboard, 'urlopen',
                    side_effect=HTTPError('http://label-studio.invalid', code, 'Denied', {}, None)):
                self.assert_login(self.client.get('/dashboard?page=2',
                    headers={**self.html, 'Cookie': 'sessionid=expired; csrftoken=irrelevant'}), '/dashboard?page=2')

    def test_json_and_non_get_requests_remain_401_even_with_html_accept(self):
        for headers in ({'Accept': 'application/json'}, {'Accept': '*/*'}, {}):
            response = self.client.get('/dashboard', headers=headers)
            self.assertEqual(response.status_code, 401)
            self.assertNotIn('location', response.headers)
            self.assertEqual(response.headers['cache-control'], 'no-store')
        for headers in (self.html, {'Accept': 'application/json'}):
            self.assertEqual(self.client.get('/dashboard/data', headers=headers).status_code, 401)
            self.assertEqual(self.client.post(self.recording + '/references', headers=headers).status_code, 401)
            artifact = '/dashboard/artifacts/' + str(uuid.uuid4()) + '/content'
            response = self.client.head(artifact, headers=headers)
            self.assertEqual(response.status_code, 401)
            self.assertNotIn('location', response.headers)
        self.loader.assert_not_called()

    def test_outage_and_missing_project_permission_do_not_redirect_or_load_data(self):
        for error in (URLError('unavailable'), TimeoutError(),
                      HTTPError('http://label-studio.invalid', 500, 'Unavailable', {}, None)):
            with self.subTest(error=type(error).__name__), patch.object(dashboard, 'urlopen', side_effect=error):
                response = self.client.get('/dashboard', headers={**self.html, 'Cookie': 'sessionid=test'})
                self.assertEqual(response.status_code, 503)
                self.assertNotIn('location', response.headers)
                self.assertEqual(response.headers['cache-control'], 'no-store')
        with patch.object(dashboard, 'urlopen', return_value=io.BytesIO(b'{"permissions":[]}')):
            response = self.client.get('/dashboard', headers={**self.html, 'Cookie': 'sessionid=test'})
            self.assertEqual(response.status_code, 403)
            self.assertNotIn('location', response.headers)
        self.loader.assert_not_called()

    def test_authenticated_browser_renders_without_redirect(self):
        with patch.object(dashboard, 'urlopen', return_value=io.BytesIO(b'{"permissions":["projects.view"]}')):
            response = self.client.get('/dashboard', headers={**self.html, 'Cookie': 'sessionid=valid'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertNotIn('location', response.headers)
        self.loader.assert_called_once()


if __name__ == '__main__':
    unittest.main()
