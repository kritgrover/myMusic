"""Slow enrichment must not stall requests, exhaust workers, or miscache labels."""
import asyncio
import threading
import unittest
from unittest.mock import AsyncMock, Mock, patch

import httpx
from isolated_backend import isolated_backend


class MetadataReliabilityTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.environment = isolated_backend()
        self.api, _ = self.environment.__enter__()
        self.service_type = type(self.api.metadata_service)
        self.services = []
        self.releases = []

    async def asyncTearDown(self):
        for release in self.releases:
            release.set()
        # Tests retain the underlying futures so temporary databases cannot be
        # removed while their background work is still finishing.
        for service in self.services:
            with service._lock:
                pending = list(service._pending.values())
            if pending:
                await asyncio.wait_for(asyncio.gather(*[
                    asyncio.wrap_future(future) for future in pending], return_exceptions=True), 3)
            service.close()
        self.api.metadata_service.close()
        self.environment.__exit__(None, None, None)

    def service(self, **kwargs):
        service = self.service_type(**kwargs)
        self.services.append(service)
        return service

    def gated_resolver(self, *, result=None):
        loop = asyncio.get_running_loop()
        started = asyncio.Event()
        release = threading.Event()
        self.releases.append(release)
        calls = []

        def resolve(*args):
            calls.append(args)
            loop.call_soon_threadsafe(started.set)
            if not release.wait(3):
                raise RuntimeError('Test worker was not released')
            return result or {'title': 'Resolved', 'artist': 'Artist', 'source': 'fixture'}

        return resolve, started, release, calls

    async def test_slow_metadata_leaves_health_and_private_audio_responsive(self):
        service = self.service(max_workers=1, response_timeout=0.02)
        resolve, started, release, calls = self.gated_resolver()
        service.resolve = resolve
        user = self.api.db.create_user('metadata-listener', 'unused')
        token = self.api.create_access_token(user['id'], user['username'])
        audio = self.api.Path(self.api.DOWNLOADS_DIR) / 'metadata-fixture.mp3'
        audio.write_bytes(b'0123456789')
        self.api.db.claim_download(user['id'], audio.name)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=self.api.app),
                                     base_url='http://test', headers={'Authorization': 'Bearer ' + token}) as client:
            with patch.object(self.api, 'metadata_service', service):
                pending = asyncio.create_task(client.get('/clean-metadata', params={
                    'title': 'Artist - Song (Official Audio)', 'uploader': 'Artist',
                    'video_url': 'https://www.youtube.com/watch?v=abcdefghijk'}))
                await asyncio.wait_for(started.wait(), 1)
                health = await asyncio.wait_for(client.get('/'), 1)
                media = await asyncio.wait_for(client.get('/downloads/' + audio.name,
                                                           headers={'Range': 'bytes=0-3'}), 1)
                response = await asyncio.wait_for(pending, 1)
        self.assertEqual(health.status_code, 200)
        self.assertEqual(media.status_code, 206)
        self.assertEqual(media.content, b'0123')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['title'], 'Song')
        self.assertEqual(response.json()['source'], 'regex_parsed')
        self.assertFalse(release.is_set())
        self.assertEqual(len(calls), 1)

    async def test_identical_requests_share_work_and_cancelling_one_preserves_other(self):
        service = self.service(max_workers=1, response_timeout=2)
        resolve, started, release, calls = self.gated_resolver()
        service.resolve = resolve
        first = asyncio.create_task(service.resolve_async('Song', 'Artist', 'abcdefghijk'))
        second = asyncio.create_task(service.resolve_async('Song', 'Artist', 'abcdefghijk'))
        await asyncio.wait_for(started.wait(), 1)
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        release.set()
        result = await asyncio.wait_for(second, 1)
        self.assertEqual(result['title'], 'Resolved')
        self.assertEqual(len(calls), 1)

    async def test_timeout_keeps_worker_slot_until_actual_completion(self):
        service = self.service(max_workers=1, response_timeout=0.01)
        resolve, started, release, calls = self.gated_resolver()
        service.resolve = resolve
        first = asyncio.create_task(service.resolve_async('First', 'Artist'))
        await asyncio.wait_for(started.wait(), 1)
        self.assertEqual((await first)['source'], 'regex_parsed')
        self.assertEqual((await service.resolve_async('Second', 'Artist'))['title'], 'Second')
        self.assertEqual(len(calls), 1, 'Saturation must not enqueue another provider job')
        release.set()
        service._response_timeout = 2
        self.assertEqual((await service.resolve_async('First', 'Artist'))['title'], 'Resolved')
        service.resolve = lambda *args: {'title': 'Next', 'artist': 'Artist'}
        self.assertEqual((await service.resolve_async('Second', 'Artist'))['title'], 'Next')

    async def test_provider_exception_releases_capacity_and_shutdown_returns_fallback(self):
        service = self.service(max_workers=1)
        service.resolve = Mock(side_effect=[RuntimeError('provider detail'), {'title': 'Recovered'}])
        self.assertEqual((await service.resolve_async('Song', 'Artist'))['source'], 'regex_parsed')
        self.assertEqual((await service.resolve_async('Song', 'Artist'))['title'], 'Recovered')
        service.close()
        self.assertEqual((await service.resolve_async('Song', 'Artist'))['source'], 'regex_parsed')
        self.assertEqual(service.resolve.call_count, 2)

    async def test_url_validation_precedes_metadata_worker_admission(self):
        resolve = AsyncMock()
        with patch.object(self.api.metadata_service, 'resolve_async', resolve):
            with self.assertRaises(self.api.HTTPException) as mismatch:
                await self.api.clean_metadata('Song', 'Artist', 'abcdefghijk',
                                              'https://www.youtube.com/watch?v=zzzzzzzzzzz')
            self.assertEqual(mismatch.exception.status_code, 400)
            with self.assertRaises(self.api.HTTPException):
                await self.api.clean_metadata('Song', video_url='http://127.0.0.1/private')
        resolve.assert_not_awaited()

    async def test_persistent_cache_is_scoped_to_source_and_input_labels(self):
        service = self.service()
        self.api.db.set_metadata_cache('abcdefghijk', {'title': 'Old unscoped guess'})
        with patch.object(service, '_spotify_validate', side_effect=[
                {'id': 'track-a', 'title': 'Song A', 'artist': 'Artist A'},
                {'id': 'track-b', 'title': 'Song B', 'artist': 'Artist B'}]) as lookup:
            first = await service.resolve_async('Song A', 'Artist A', 'abcdefghijk')
            second = await service.resolve_async('Song B', 'Artist B', 'abcdefghijk')
            again = await service.resolve_async('Song A', 'Artist A', 'abcdefghijk')
        self.assertEqual(first['spotify_id'], 'track-a')
        self.assertEqual(second['spotify_id'], 'track-b')
        self.assertEqual(again, first)
        self.assertEqual(lookup.call_count, 2)

    async def test_unavailable_provider_does_not_persist_a_fallback_as_final_metadata(self):
        service = self.service()
        with patch.object(service, '_spotify_validate', side_effect=[None,
                {'id': 'track-a', 'title': 'Enriched', 'artist': 'Artist'}]):
            first = await service.resolve_async('Song', 'Artist', 'abcdefghijk')
            second = await service.resolve_async('Song', 'Artist', 'abcdefghijk')
        self.assertEqual(first['source'], 'regex_parsed')
        self.assertEqual(second['title'], 'Enriched')

    async def test_late_enrichment_warms_only_its_own_source_and_labels(self):
        service = self.service(max_workers=2, response_timeout=0.01)
        loop = asyncio.get_running_loop()
        started = asyncio.Event()
        release = threading.Event()
        self.releases.append(release)

        def validate(title, artist, *args, **kwargs):
            if title == 'First':
                loop.call_soon_threadsafe(started.set)
                if not release.wait(3):
                    raise RuntimeError('Test worker was not released')
            return {'id': 'catalog-' + title, 'title': title, 'artist': artist}

        with patch.object(service, '_spotify_validate', side_effect=validate) as lookup:
            first = asyncio.create_task(service.resolve_async('First', 'Artist', 'abcdefghijk'))
            await asyncio.wait_for(started.wait(), 1)
            self.assertEqual((await first)['source'], 'regex_parsed')
            service._response_timeout = 2
            second = await service.resolve_async('Second', 'Artist', 'zzzzzzzzzzz')
            self.assertEqual(second['spotify_id'], 'catalog-Second')
            with service._lock:
                pending = list(service._pending.values())
            release.set()
            await asyncio.wait_for(asyncio.gather(*[
                asyncio.wrap_future(future) for future in pending]), 1)
            first_cached = await service.resolve_async('First', 'Artist', 'abcdefghijk')
            second_cached = await service.resolve_async('Second', 'Artist', 'zzzzzzzzzzz')
        self.assertEqual(first_cached['spotify_id'], 'catalog-First')
        self.assertEqual(second_cached['spotify_id'], 'catalog-Second')
        self.assertEqual(lookup.call_count, 2)

    async def test_work_budget_stops_additional_provider_calls(self):
        spotify = Mock(sp=object())
        service = self.service(spotify_service=spotify)
        self.assertIsNone(service._spotify_validate('Song', 'Artist', 'Artist - Song', 'Artist', deadline=0))
        spotify._search_spotify_raw.assert_not_called()
        download = Mock(yt_dlp_exe='fixture', _get_creationflags=lambda: 0,
                        _yt_cmd=lambda *args: ['fixture'])
        service = self.service(download_service=download)
        module = __import__(self.service_type.__module__)
        with patch.object(module.time, 'monotonic', return_value=4), \
             patch.object(module.subprocess, 'run', return_value=Mock(returncode=0, stdout='{}')) as run:
            service._extract_ytdlp_metadata('https://www.youtube.com/watch?v=abcdefghijk', deadline=5)
        self.assertEqual(run.call_args.kwargs['timeout'], 1)


if __name__ == '__main__':
    unittest.main()
