"""Only completed, bounded download attempts can publish owned audio files."""

import subprocess
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from isolated_backend import isolated_backend


class DownloadPublicationTests(unittest.TestCase):
    source = 'https://www.youtube.com/watch?v=testFixture'

    @classmethod
    def setUpClass(cls):
        cls.environment = isolated_backend()
        cls.api, cls.root = cls.environment.__enter__()
        import download_service
        cls.module = download_service

    @classmethod
    def tearDownClass(cls):
        cls.environment.__exit__(None, None, None)

    def setUp(self):
        self.output = self.root / 'downloads' / uuid.uuid4().hex
        self.output.mkdir()
        self.service = object.__new__(self.module.DownloadService)
        self.service.output_dir = str(self.output)
        self.service.yt_dlp_exe = 'fixture-ytdlp'
        self.service.ffmpeg_exe = 'fixture-ffmpeg'
        self.service._js_runtime = None
        self.key = uuid.uuid4().hex
        self.folder = self.output / 'users' / '17'
        self.destination = self.folder / f'{self.key}-Song - Artist.m4a'
        self.tagger = patch.object(self.module, 'MP4', return_value=SimpleNamespace(tags={'fixture': 1}, save=lambda: None))
        self.tagger.start()
        self.addCleanup(self.tagger.stop)
        # Exercise Windows tree ownership even when this suite runs on Linux.
        for name, value in (('CREATE_NEW_PROCESS_GROUP', 512), ('CREATE_NO_WINDOW', 134217728)):
            flag = patch.object(self.module.subprocess, name, value, create=True)
            flag.start()
            self.addCleanup(flag.stop)

    def download(self, **kwargs):
        return self.service.download_audio(
            self.source, 'Song', 'Artist', owner_id=17,
            download_key=self.key, **kwargs)

    def assert_clean(self):
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.folder.glob('.job-*')), [])

    def test_publication_is_single_atomic_move_after_processing(self):
        original_replace = self.module.os.replace
        staged = []

        def extract(args, source, prefix, max_bytes, **kwargs):
            self.assertFalse(self.destination.exists())
            self.assertEqual(source, self.source)
            self.assertEqual(args[args.index('--max-filesize') + 1], '128')
            candidate = Path(prefix + '.m4a')
            candidate.write_bytes(b'complete-audio')
            Path(prefix + '.part').write_bytes(b'temporary')
            staged.append(candidate)

        def publish(source, destination):
            self.assertEqual(source, staged[0])
            self.assertEqual(destination, self.destination)
            self.assertFalse(destination.exists())
            self.assertEqual(source.read_bytes(), b'complete-audio')
            original_replace(source, destination)

        with patch.object(self.service, '_bounded_stream_process', side_effect=extract), \
                patch.object(self.module.os, 'replace', side_effect=publish) as replace:
            result = self.download(max_bytes=128)
        replace.assert_called_once()
        self.assertEqual(self.destination.read_bytes(), b'complete-audio')
        self.assertEqual(result['filename'], f'users/17/{self.destination.name}')
        self.assertEqual(list(self.folder.glob('.job-*')), [])

    def test_completed_identity_is_reused_after_unrecorded_database_completion(self):
        def extract(args, source, prefix, max_bytes, **kwargs):
            Path(prefix + '.m4a').write_bytes(b'completed-before-db-crash')

        with patch.object(self.service, '_bounded_stream_process', side_effect=extract) as extract:
            completed = self.download()
        extract.assert_called_once()
        # No completion record was persisted; retry the same durable payload.
        with patch.object(self.service, '_bounded_stream_process', side_effect=AssertionError('download repeated')):
            recovered = self.download()
        self.assertEqual(completed, recovered)
        self.assertEqual(list(self.folder.glob('*.m4a')), [self.destination])
        self.assertEqual(self.destination.read_bytes(), b'completed-before-db-crash')

    def test_abandoned_crash_candidate_is_never_treated_as_completed_audio(self):
        abandoned = self.folder / f'.job-{self.key}'
        abandoned.mkdir(parents=True)
        stale = abandoned / 'audio.m4a'
        stale.write_bytes(b'incomplete-previous-attempt')

        def no_output(args, source, prefix, max_bytes, **kwargs):
            self.assertNotEqual(Path(prefix).parent, abandoned)

        with patch.object(self.service, '_bounded_stream_process', side_effect=no_output):
            with self.assertRaisesRegex(RuntimeError, 'complete audio'):
                self.download()
        self.assertFalse(self.destination.exists())
        self.assertEqual(stale.read_bytes(), b'incomplete-previous-attempt')
        self.assertEqual(list(self.folder.glob('.job-*')), [abandoned])

    def test_expired_attempt_cannot_delete_replacement_attempt_files(self):
        started, release, expired = threading.Event(), threading.Event(), threading.Event()
        prefixes = []

        def extract(args, source, prefix, max_bytes, **kwargs):
            prefixes.append(prefix)
            if len(prefixes) == 1:
                Path(prefix + '.m4a').write_bytes(b'old-attempt')
                started.set()
                if not release.wait(3):
                    raise AssertionError('Replacement did not release the old worker')
            else:
                self.assertNotEqual(Path(prefix).parent, Path(prefixes[0]).parent)
                Path(prefix + '.m4a').write_bytes(b'replacement-attempt')

        with patch.object(self.service, '_bounded_stream_process', side_effect=extract), \
                ThreadPoolExecutor(max_workers=1) as pool:
            old = pool.submit(self.download, cancel_check=expired.is_set)
            try:
                self.assertTrue(started.wait(3))
                self.download()
                self.assertTrue(Path(prefixes[0] + '.m4a').exists())
                expired.set()
            finally:
                release.set()
            with self.assertRaises(self.module.DownloadCancelled):
                old.result(timeout=3)
        self.assertEqual(self.destination.read_bytes(), b'replacement-attempt')
        self.assertEqual(list(self.folder.glob('.job-*')), [])

    def test_missing_empty_and_oversized_results_cannot_publish(self):
        for content in (None, b'', b'123456'):
            with self.subTest(content=content):
                def extract(args, source, prefix, max_bytes, **kwargs):
                    if content is not None:
                        Path(prefix + '.m4a').write_bytes(content)
                with patch.object(self.service, '_bounded_stream_process', side_effect=extract):
                    with self.assertRaises(RuntimeError):
                        self.download(max_bytes=5)
                self.assert_clean()

    def test_tag_growth_is_rechecked_before_publication(self):
        def extract(args, source, prefix, max_bytes, **kwargs):
            Path(prefix + '.m4a').write_bytes(b'audio')
        def tagger(path):
            return SimpleNamespace(tags={'fixture': 1}, save=lambda: Path(path).write_bytes(b'audio-plus-tags'))
        with patch.object(self.service, '_bounded_stream_process', side_effect=extract), \
                patch.object(self.module, 'MP4', side_effect=tagger):
            with self.assertRaisesRegex(RuntimeError, 'file size limit'):
                self.download(max_bytes=5)
        self.assert_clean()

    def test_failed_process_cannot_publish_an_existing_staged_candidate(self):
        def extract(args, source, prefix, max_bytes, **kwargs):
            Path(prefix + '.m4a').write_bytes(b'incomplete')
            raise RuntimeError('provider failed')
        with patch.object(self.service, '_bounded_stream_process', side_effect=extract):
            with self.assertRaisesRegex(RuntimeError, 'provider failed'):
                self.download()
        self.assert_clean()

    def test_cancellation_after_processing_and_after_tagging_cannot_publish(self):
        for cancel_at in (2, 3):
            with self.subTest(cancel_at=cancel_at):
                checks = iter([False] * (cancel_at - 1) + [True])
                def extract(args, source, prefix, max_bytes, **kwargs):
                    Path(prefix + '.m4a').write_bytes(b'complete')
                with patch.object(self.service, '_bounded_stream_process', side_effect=extract):
                    with self.assertRaises(self.module.DownloadCancelled):
                        self.download(cancel_check=lambda: next(checks))
                self.assert_clean()

    def test_cancelled_child_tree_is_killed_by_pid_and_temporary_files_are_removed(self):
        process = Mock(pid=23456)
        process.poll.return_value = None
        checks = iter([False, False, True])

        def launch(command, **kwargs):
            template = command[command.index('--output') + 1]
            Path(template.replace('%(ext)s', 'm4a.part')).write_bytes(b'partial')
            self.assertTrue(kwargs['creationflags'] & subprocess.CREATE_NEW_PROCESS_GROUP)
            return process

        with patch.object(self.module.platform, 'system', return_value='Windows'), \
                patch.object(self.module.subprocess, 'Popen', side_effect=launch), \
                patch.object(self.module.subprocess, 'run') as terminate:
            with self.assertRaises(self.module.DownloadCancelled):
                self.download(cancel_check=lambda: next(checks))
        self.assertEqual(terminate.call_args.args[0], ['taskkill', '/PID', '23456', '/T', '/F'])
        self.assertNotIn('/IM', terminate.call_args.args[0])
        process.wait.assert_called_once_with(timeout=10)
        self.assert_clean()

    def test_timeout_and_live_temporary_size_limit_stop_tree_and_cannot_publish(self):
        for limit, elapsed, error in ((5, 0, 'file size limit'), (100, 61, 'timed out')):
            with self.subTest(error=error):
                process = Mock(pid=23456)
                process.poll.return_value = None
                def launch(command, **kwargs):
                    template = command[command.index('--output') + 1]
                    Path(template.replace('%(ext)s', 'm4a')).write_bytes(b'partial')
                    return process
                with patch.object(self.module.platform, 'system', return_value='Windows'), \
                        patch.object(self.module.subprocess, 'Popen', side_effect=launch), \
                        patch.object(self.module.subprocess, 'run') as terminate, \
                        patch.object(self.module.time, 'monotonic', side_effect=[0, elapsed]):
                    with self.assertRaisesRegex(RuntimeError, error):
                        self.download(max_bytes=limit, timeout=60)
                self.assertEqual(terminate.call_args.args[0], ['taskkill', '/PID', '23456', '/T', '/F'])
                self.assert_clean()

    def test_process_exit_during_tree_kill_preserves_cancellation(self):
        process = Mock(pid=23456)
        process.poll.return_value = None
        checks = iter([False, False, True])
        with patch.object(self.module.platform, 'system', return_value='Windows'), \
                patch.object(self.module.subprocess, 'Popen', return_value=process), \
                patch.object(self.module.subprocess, 'run', side_effect=ProcessLookupError):
            with self.assertRaises(self.module.DownloadCancelled):
                self.download(cancel_check=lambda: next(checks))
        process.wait.assert_called_once_with(timeout=10)
        self.assert_clean()

    def test_excessive_process_logs_stop_only_the_owned_tree(self):
        process = Mock(pid=23456)
        process.poll.return_value = None
        def launch(command, **kwargs):
            kwargs['stdout'].write(b'x' * 1048577)
            kwargs['stdout'].flush()
            return process
        with patch.object(self.module.platform, 'system', return_value='Windows'), \
                patch.object(self.module.subprocess, 'Popen', side_effect=launch), \
                patch.object(self.module.subprocess, 'run') as terminate:
            with self.assertRaisesRegex(RuntimeError, 'excessive diagnostic output'):
                self.download()
        self.assertEqual(terminate.call_args.args[0], ['taskkill', '/PID', '23456', '/T', '/F'])
        self.assert_clean()

    def test_posix_cancellation_stops_the_owned_session_group(self):
        process = Mock(pid=23456)
        process.poll.return_value = None
        checks = iter([False, False, True])
        with patch.object(self.module.platform, 'system', return_value='Linux'), \
                patch.object(self.module.subprocess, 'Popen', return_value=process) as launch, \
                patch.object(self.module.os, 'killpg', create=True) as terminate, \
                patch.object(self.module.signal, 'SIGKILL', 9, create=True):
            with self.assertRaises(self.module.DownloadCancelled):
                self.download(cancel_check=lambda: next(checks))
        self.assertTrue(launch.call_args.kwargs['start_new_session'])
        self.assertEqual(terminate.call_args.args, (23456, 9))
        self.assert_clean()


if __name__ == '__main__':
    unittest.main()
