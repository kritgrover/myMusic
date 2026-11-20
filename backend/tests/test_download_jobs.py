"""Durable worker contracts using temporary SQLite files and event barriers."""
import importlib.util
import sqlite3
import tempfile
import threading
import unittest
from contextlib import closing
from pathlib import Path


spec = importlib.util.spec_from_file_location('download_jobs_tests',
    Path(__file__).resolve().parents[1] / 'download_jobs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DownloadJobManager = module.DownloadJobManager


class _Database:
    def __init__(self, path):
        self.path = path

    def get_connection(self):
        connection = sqlite3.connect(self.path, check_same_thread=False)
        connection.row_factory = sqlite3.Row
        return connection


class DownloadJobsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mymusic-jobs-test-')
        self.database = _Database(str(Path(self.temp.name) / 'jobs.db'))
        self.now = 10000.0
        self.managers = []

    def tearDown(self):
        for manager in self.managers:
            manager.shutdown(timeout=3)
        self.temp.cleanup()

    def manager(self, callback=None, **kwargs):
        result = DownloadJobManager(self.database,
            callback or (lambda payload, user, cancelled: {'filename': payload['title'] + '.m4a'}),
            clock=lambda: self.now, **kwargs)
        self.managers.append(result)
        return result

    def payloads(self, *titles):
        return [{'title': title, 'artist': 'Artist', 'url': 'https://www.youtube.com/watch?v=abcdefghijk'}
                for title in titles]

    def finish(self, manager, item, **kwargs):
        manager._finish(item, result={'filename': item['payload']['title'] + '.m4a'}, **kwargs)

    def test_restart_preserves_success_and_only_resumes_unfinished_items(self):
        first = self.manager()
        job = first.submit(1, self.payloads('first', 'second', 'third'))
        self.assertEqual(job['title'], '3 tracks · first')
        item = first._claim()
        self.finish(first, item)
        interrupted = first._claim()
        reopened = self.manager()
        self.assertIsNone(reopened._claim())  # It cannot steal another live process's batch.
        self.now += 31
        recovered = reopened._claim()
        self.assertEqual(recovered['index'], interrupted['index'])
        self.finish(reopened, recovered)
        final = reopened._claim()
        self.assertEqual(final['index'], 2)
        self.finish(reopened, final)
        progress = reopened.get(1, job['download_id'])
        self.assertEqual((progress['state'], progress['processed'], progress['current']), ('completed', 3, 3))
        self.assertEqual([row['filename'] for row in progress['downloads']],
                         ['first.m4a', 'second.m4a', 'third.m4a'])

    def test_expired_worker_cannot_overwrite_replacement_results(self):
        first, second = self.manager(), self.manager()
        job = first.submit(1, self.payloads('song'))
        stale = first._claim()
        self.now += 31
        current = second._claim()
        second._finish(current, result={'filename': 'correct.m4a'})
        first._finish(stale, result={'filename': 'stale.m4a'})
        self.assertEqual(first.get(1, job['id'])['downloads'][0]['filename'], 'correct.m4a')

    def test_heartbeat_extends_live_work_but_cannot_resurrect_lost_lease(self):
        first, second = self.manager(), self.manager()
        first.submit(1, self.payloads('long'))
        item = first._claim()
        first._active[item['token']] = item
        self.now += 20
        first._renew_leases()
        self.now += 20  # Beyond the original lease, before the renewed lease.
        self.assertIsNone(second._claim())
        self.assertFalse(first._cancelled(item))
        self.now += 11
        first._renew_leases()  # A missed lease cannot be renewed after expiry.
        self.assertTrue(first._cancelled(item))
        recovered = second._claim()
        self.assertNotEqual(recovered['token'], item['token'])

    def test_completed_file_wins_cancellation_race_without_becoming_retryable(self):
        manager = self.manager()
        job = manager.submit(1, self.payloads('finished'))
        item = manager._claim()
        manager.cancel(1, job['id'])
        self.finish(manager, item)
        progress = manager.get(1, job['id'])
        self.assertEqual(progress['processed'], 1)
        self.assertFalse(progress['can_retry'])
        manager.retry(1, job['id'])
        self.assertIsNone(manager._claim())

    def test_two_global_slots_and_one_item_per_batch_across_managers(self):
        first, second = self.manager(), self.manager()
        first.submit(1, self.payloads('a', 'b'))
        first.submit(1, self.payloads('c'))
        first.submit(1, self.payloads('d'))
        one, two = first._claim(), second._claim()
        self.assertNotEqual(one['job_id'], two['job_id'])
        self.assertIsNone(first._claim())
        self.assertIsNone(second._claim())
        self.finish(first, one)
        self.assertIsNotNone(second._claim())

    def test_cancel_then_retry_preserves_completed_items_and_order(self):
        manager = self.manager()
        job = manager.submit(1, self.payloads('done', 'running', 'pending'))
        self.finish(manager, manager._claim())
        running = manager._claim()
        progress = manager.cancel(1, job['id'])
        self.assertEqual(progress['state'], 'cancelled')
        self.assertFalse(progress['can_retry'])
        self.assertTrue(manager._cancelled(running))
        with self.assertRaisesRegex(ValueError, 'still active'):
            manager.retry(1, job['id'])
        manager._finish(running, error=True)
        progress = manager.get(1, job['id'])
        self.assertEqual((progress['processed'], progress['failed'], progress['cancelled']), (1, 0, 2))
        self.assertTrue(progress['can_retry'])
        manager.retry(1, job['id'])
        self.assertEqual(manager._claim()['index'], 1)
        self.assertEqual(manager.get(1, job['id'])['downloads'][0]['filename'], 'done.m4a')

    def test_failed_items_only_retry_and_successes_remain_once(self):
        manager = self.manager()
        job = manager.submit(1, self.payloads('done', 'failed'))
        self.finish(manager, manager._claim())
        manager._finish(manager._claim(), error=True)
        before = manager.get(1, job['id'])
        self.assertEqual((before['state'], before['failed'], before['can_retry']), ('completed', 1, True))
        manager.retry(1, job['id'])
        retried = manager._claim()
        self.assertEqual(retried['index'], 1)
        self.finish(manager, retried)
        after = manager.get(1, job['id'])
        self.assertEqual((after['processed'], after['failed'], after['can_retry']), (2, 0, False))
        self.assertEqual(len(after['downloads']), 2)

    def test_progress_and_actions_are_account_scoped(self):
        manager = self.manager()
        job = manager.submit(1, self.payloads('private'))
        self.assertIsNone(manager.get(2, job['id']))
        self.assertIsNone(manager.cancel(2, job['id']))
        self.assertIsNone(manager.retry(2, job['id']))
        self.assertEqual(manager.list(2), [])
        self.assertEqual(manager.get(1, job['id'])['state'], 'queued')

    def test_cleanup_never_deletes_old_queued_or_running_jobs(self):
        manager = self.manager()
        completed = manager.submit(1, self.payloads('done'))
        self.finish(manager, manager._claim())
        running = manager.submit(1, self.payloads('long'))
        manager._claim()
        queued = manager.submit(1, self.payloads('queued'))
        self.now += 100000
        self.assertEqual(manager.cleanup(max_age_seconds=3600), 1)
        self.assertIsNone(manager.get(1, completed['id']))
        self.assertIsNotNone(manager.get(1, running['id']))
        self.assertIsNotNone(manager.get(1, queued['id']))

    def test_cancelling_work_stays_visible_ahead_of_finished_history(self):
        manager = self.manager()
        active = manager.submit(1, self.payloads('cancelling'))
        item = manager._claim()
        manager.cancel(1, active['id'])
        self.now += 1
        recent = manager.submit(1, self.payloads('recent'))
        manager.cancel(1, recent['id'])
        listed = manager.list(1, limit=1)
        self.assertEqual(listed[0]['id'], active['id'])
        self.assertEqual(listed[0]['status'], 'Cancelling...')
        manager._finish(item, error=True)
        self.assertEqual(manager.list(1, limit=1)[0]['id'], recent['id'])

    def test_batch_and_active_job_limits_are_transactional(self):
        manager = self.manager(max_jobs_per_user=2)
        for payload in ([], self.payloads(*['song'] * 501)):
            with self.assertRaisesRegex(ValueError, '500'):
                manager.submit(1, payload)
        one = manager.submit(1, self.payloads('one'))
        manager.submit(1, self.payloads('two'))
        with self.assertRaisesRegex(ValueError, 'existing download'):
            manager.submit(1, self.payloads('three'))
        manager.submit(2, self.payloads('other'))
        manager.cancel(1, one['id'])
        manager.submit(1, self.payloads('three'))
        with self.assertRaisesRegex(ValueError, 'before retrying'):
            manager.retry(1, one['id'])

    def test_worker_executes_callback_and_persists_result(self):
        callback_entered, release = threading.Event(), threading.Event()
        finished = threading.Event()
        seen = []
        def callback(payload, user_id, cancelled):
            seen.append((payload['title'], user_id, cancelled()))
            callback_entered.set()
            self.assertTrue(release.wait(3))
            return {'filename': 'real-result.m4a', 'title': 'Resolved title'}
        manager = self.manager(callback)
        original_finish = manager._finish
        def finish(*args, **kwargs):
            original_finish(*args, **kwargs)
            finished.set()
        manager._finish = finish
        job = manager.submit(9, self.payloads('request'))
        manager.start()
        self.assertTrue(callback_entered.wait(3))
        self.assertEqual(manager.get(9, job['id'])['state'], 'running')
        release.set()
        self.assertTrue(finished.wait(3))
        self.assertEqual(seen, [('request', 9, False)])
        self.assertEqual(manager.get(9, job['id'])['downloads'][0]['title'], 'Resolved title')

    def test_fixed_workers_bound_actual_parallel_callbacks(self):
        entered_two, release, finished_three = threading.Event(), threading.Event(), threading.Event()
        lock = threading.Lock()
        active = peak = finished_count = 0
        def callback(payload, user_id, cancelled):
            nonlocal active, peak
            with lock:
                active += 1
                peak = max(peak, active)
                if active == 2:
                    entered_two.set()
            try:
                self.assertTrue(release.wait(3))
                return {'filename': payload['title'] + '.m4a'}
            finally:
                with lock:
                    active -= 1
        manager = self.manager(callback)
        original_finish = manager._finish
        def finish(*args, **kwargs):
            nonlocal finished_count
            original_finish(*args, **kwargs)
            with lock:
                finished_count += 1
                if finished_count == 3:
                    finished_three.set()
        manager._finish = finish
        for title in ('one', 'two', 'three'):
            manager.submit(1, self.payloads(title))
        manager.start()
        try:
            self.assertTrue(entered_two.wait(3))
            self.assertEqual(sum(job['state'] == 'running' for job in manager.list(1)), 2)
        finally:
            release.set()
        self.assertTrue(finished_three.wait(3))
        self.assertEqual(peak, 2)

    def test_shutdown_cooperatively_requeues_without_failing_item(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        def callback(payload, user_id, cancelled):
            entered.set()
            self.assertTrue(release.wait(3))
            self.assertTrue(cancelled())
            raise RuntimeError('interrupted')
        manager = self.manager(callback)
        original_finish = manager._finish
        def finish(*args, **kwargs):
            original_finish(*args, **kwargs)
            finished.set()
        manager._finish = finish
        job = manager.submit(1, self.payloads('resume'))
        manager.start()
        self.assertTrue(entered.wait(3))
        manager.shutdown(wait=False)
        release.set()
        self.assertTrue(finished.wait(3))
        manager.shutdown()
        progress = manager.get(1, job['id'])
        self.assertEqual((progress['state'], progress['failed']), ('queued', 0))
        reopened = self.manager()
        self.assertEqual(reopened._claim()['payload']['title'], 'resume')

    def test_cancelled_expired_lease_does_not_restart_cancelled_item(self):
        manager = self.manager()
        job = manager.submit(1, self.payloads('cancel'))
        manager._claim()
        manager.cancel(1, job['id'])
        self.now += 31
        reopened = self.manager()
        self.assertIsNone(reopened._claim())
        self.assertTrue(reopened.get(1, job['id'])['can_retry'])

    def test_start_recovers_after_a_previous_shutdown_timed_out(self):
        entered, release, resumed = threading.Event(), threading.Event(), threading.Event()
        attempts = 0

        def callback(payload, user_id, cancelled):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                entered.set()
                self.assertTrue(release.wait(3))
                self.assertTrue(cancelled())
                raise RuntimeError('interrupted')
            resumed.set()
            return {'filename': 'resumed.m4a'}

        manager = self.manager(callback)
        job = manager.submit(1, self.payloads('resume'))
        manager.start()
        self.assertTrue(entered.wait(3))
        original_threads = list(manager._threads)
        manager.shutdown(timeout=0)
        manager.start()
        self.assertTrue(manager._stop.is_set())
        self.assertEqual(manager._threads, original_threads)
        release.set()
        # Join directly: another shutdown() would clear the stale references
        # and hide the restart behavior this test needs to exercise.
        for thread in original_threads:
            thread.join(3)
            self.assertFalse(thread.is_alive())
        manager.start()
        self.assertTrue(resumed.wait(3))
        manager.shutdown()
        self.assertEqual(manager.get(1, job['id'])['processed'], 1)


if __name__ == '__main__':
    unittest.main()
