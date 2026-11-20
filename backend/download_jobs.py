"""Durable account-owned download batches with a bounded, leased worker queue.

Only item payloads/results live in SQLite. Fixed workers claim one item at a
time; process restarts and additional server processes never need an in-memory
copy of the queue. The callback must cooperate with ``is_cancelled`` and bound
its subprocess lifetime. Completed items are never repeated on retry/recovery.
"""
import json
import threading
import time
import uuid
from contextlib import closing


class DownloadJobManager:
    def __init__(self, database, callback, *, workers=2, lease_seconds=30,
                 poll_seconds=0.25, clock=time.time, max_jobs_per_user=20):
        self.database = database
        self.callback = callback
        self.workers = max(1, min(2, int(workers)))
        self.lease_seconds = max(1, float(lease_seconds))
        self.poll_seconds = max(0.01, float(poll_seconds))
        self.clock = clock
        self.max_jobs_per_user = max_jobs_per_user
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._lock = threading.Lock()
        self._threads = []
        self._active = {}
        with closing(self.database.get_connection()) as conn, conn:
            conn.executescript('''
                CREATE TABLE IF NOT EXISTS download_jobs (
                    id TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
                    state TEXT NOT NULL DEFAULT 'queued',
                    cancel_requested INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS download_jobs_owner
                    ON download_jobs(user_id, created_at);
                CREATE TABLE IF NOT EXISTS download_job_items (
                    job_id TEXT NOT NULL, item_index INTEGER NOT NULL,
                    payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
                    result TEXT, lease_token TEXT, lease_until REAL,
                    PRIMARY KEY(job_id, item_index)
                );
                CREATE INDEX IF NOT EXISTS download_job_items_queue
                    ON download_job_items(state, lease_until);
            ''')

    def start(self):
        with self._lock:
            # A timed-out shutdown leaves its thread references until those
            # callbacks finish. Reuse the manager once every old thread exits,
            # but never clear cancellation underneath a still-running worker.
            if any(thread.is_alive() for thread in self._threads):
                return
            self._stop.clear()
            self._threads = [threading.Thread(target=self._worker, daemon=True,
                            name=f'mymusic-download-{index}') for index in range(self.workers)]
            self._threads.append(threading.Thread(target=self._heartbeat, daemon=True,
                                 name='mymusic-download-heartbeat'))
            for thread in self._threads:
                thread.start()
        self._wake.set()

    def shutdown(self, wait=True, timeout=5):
        """Stop claiming work; unfinished callbacks cancel/requeue cooperatively.

        A bounded wait avoids hanging server shutdown on a broken provider. A
        still-running callback keeps its token until it exits or the lease
        expires. A stale callback can never commit over a replacement worker.
        """
        self._stop.set()
        self._wake.set()
        if wait:
            deadline = time.monotonic() + max(0, timeout)
            for thread in list(self._threads):
                thread.join(max(0, deadline - time.monotonic()))
        with self._lock:
            if not any(thread.is_alive() for thread in self._threads):
                self._threads = []

    def _active_count(self, conn, user_id):
        return conn.execute('''SELECT COUNT(*) FROM download_jobs j WHERE j.user_id=?
            AND EXISTS (SELECT 1 FROM download_job_items i WHERE i.job_id=j.id
                        AND i.state IN ('queued','running'))''', (user_id,)).fetchone()[0]

    def submit(self, user_id, payloads):
        if not isinstance(payloads, list) or not 1 <= len(payloads) <= 500:
            raise ValueError('Choose between 1 and 500 tracks for a download batch.')
        if any(not isinstance(item, dict) for item in payloads):
            raise ValueError('Each download must contain track details.')
        encoded = [json.dumps(item, allow_nan=False, separators=(',', ':')) for item in payloads]
        if sum(len(item.encode('utf-8')) for item in encoded) > 2_000_000:
            raise ValueError('The download batch contains too much metadata.')
        job_id, now = str(uuid.uuid4()), self.clock()
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            if self._active_count(conn, user_id) >= self.max_jobs_per_user:
                raise ValueError('Finish or cancel an existing download batch before starting another.')
            conn.execute('INSERT INTO download_jobs(id,user_id,created_at,updated_at) VALUES(?,?,?,?)',
                         (job_id, user_id, now, now))
            conn.executemany('INSERT INTO download_job_items(job_id,item_index,payload) VALUES(?,?,?)',
                             [(job_id, index, payload) for index, payload in enumerate(encoded)])
        self._wake.set()
        return self.get(user_id, job_id)

    def _snapshot(self, conn, job):
        items = conn.execute('SELECT * FROM download_job_items WHERE job_id=? ORDER BY item_index',
                             (job['id'],)).fetchall()
        succeeded = sum(item['state'] == 'succeeded' for item in items)
        failed = sum(item['state'] == 'failed' for item in items)
        cancelled = sum(item['state'] == 'cancelled' for item in items)
        running = [item for item in items if item['state'] == 'running']
        queued = any(item['state'] == 'queued' for item in items)
        state = ('cancelled' if job['cancel_requested'] else 'running' if running else
                 'queued' if queued else 'completed')
        status = ('Cancelling...' if running else 'cancelled') if state == 'cancelled' else state
        if state == 'running':
            title = json.loads(running[0]['payload']).get('title') or 'track'
            status = f'Downloading {title}...'
        downloads = []
        for item in items:
            if item['result']:
                downloads.append(json.loads(item['result']))
        first_title = str(json.loads(items[0]['payload']).get('title') or 'Download batch') if items else 'Download batch'
        title = first_title if len(items) == 1 else f'{len(items)} tracks · {first_title}'
        return {
            'download_id': job['id'], 'id': job['id'], 'user_id': job['user_id'],
            'title': title,
            'current': succeeded + failed + cancelled, 'total': len(items),
            'processed': succeeded, 'failed': failed, 'cancelled': cancelled,
            'state': state, 'status': status, 'downloads': downloads,
            'can_retry': not running and not queued and bool(failed + cancelled),
            'created_at': job['created_at'], 'updated_at': job['updated_at'],
        }

    def get(self, user_id, job_id):
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN')
            row = conn.execute('SELECT * FROM download_jobs WHERE id=? AND user_id=?',
                               (job_id, user_id)).fetchone()
            return self._snapshot(conn, row) if row else None

    def list(self, user_id, limit=20):
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN')
            rows = conn.execute('''SELECT * FROM download_jobs j WHERE user_id=?
                ORDER BY CASE WHEN EXISTS (SELECT 1 FROM download_job_items i
                    WHERE i.job_id=j.id AND i.state IN ('queued','running')) THEN 0 ELSE 1 END,
                    created_at DESC LIMIT ?''', (user_id, min(100, max(1, int(limit))))).fetchall()
            return [self._snapshot(conn, row) for row in rows]

    def cancel(self, user_id, job_id):
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            job = conn.execute('SELECT * FROM download_jobs WHERE id=? AND user_id=?',
                               (job_id, user_id)).fetchone()
            if not job:
                return None
            active = conn.execute('''SELECT 1 FROM download_job_items WHERE job_id=?
                AND state IN ('queued','running') LIMIT 1''', (job_id,)).fetchone()
            if active:
                conn.execute("UPDATE download_jobs SET cancel_requested=1,state='cancelled',updated_at=? WHERE id=?",
                             (self.clock(), job_id))
                conn.execute("UPDATE download_job_items SET state='cancelled' WHERE job_id=? AND state='queued'",
                             (job_id,))
        self._wake.set()
        return self.get(user_id, job_id)

    def retry(self, user_id, job_id):
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            job = conn.execute('SELECT * FROM download_jobs WHERE id=? AND user_id=?',
                               (job_id, user_id)).fetchone()
            if not job:
                return None
            if conn.execute('''SELECT 1 FROM download_job_items WHERE job_id=?
                    AND state IN ('queued','running') LIMIT 1''', (job_id,)).fetchone():
                raise ValueError('This download batch is still active.')
            retryable = conn.execute("SELECT 1 FROM download_job_items WHERE job_id=? AND state IN ('failed','cancelled')",
                                     (job_id,)).fetchone()
            if retryable:
                if self._active_count(conn, user_id) >= self.max_jobs_per_user:
                    raise ValueError('Finish or cancel an existing download batch before retrying.')
                conn.execute('''UPDATE download_job_items SET state='queued',result=NULL,
                    lease_token=NULL,lease_until=NULL WHERE job_id=? AND state IN ('failed','cancelled')''', (job_id,))
                conn.execute("UPDATE download_jobs SET state='queued',cancel_requested=0,updated_at=? WHERE id=?",
                             (self.clock(), job_id))
        self._wake.set()
        return self.get(user_id, job_id)

    def cleanup(self, max_age_seconds=86400):
        """Expire terminal job records only; active batches have no age limit."""
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            ids = [row[0] for row in conn.execute('''SELECT id FROM download_jobs j WHERE updated_at<?
                AND NOT EXISTS(SELECT 1 FROM download_job_items i WHERE i.job_id=j.id
                               AND i.state IN ('queued','running'))''',
                                                 (self.clock() - max(0, max_age_seconds),))]
            conn.executemany('DELETE FROM download_job_items WHERE job_id=?', [(job_id,) for job_id in ids])
            conn.executemany('DELETE FROM download_jobs WHERE id=?', [(job_id,) for job_id in ids])
            return len(ids)

    def _refresh(self, conn, job_id):
        job = conn.execute('SELECT * FROM download_jobs WHERE id=?', (job_id,)).fetchone()
        snapshot = self._snapshot(conn, job)
        conn.execute('UPDATE download_jobs SET state=?,updated_at=? WHERE id=?',
                     (snapshot['state'], self.clock(), job_id))

    def _claim(self):
        now = self.clock()
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            expired = conn.execute('''SELECT DISTINCT job_id FROM download_job_items
                WHERE state='running' AND lease_until<=?''', (now,)).fetchall()
            conn.execute('''UPDATE download_job_items SET state=CASE
                WHEN (SELECT cancel_requested FROM download_jobs WHERE id=job_id)=1 THEN 'cancelled' ELSE 'queued' END,
                lease_token=NULL,lease_until=NULL WHERE state='running' AND lease_until<=?''', (now,))
            for row in expired:
                self._refresh(conn, row[0])
            active = conn.execute("SELECT COUNT(*) FROM download_job_items WHERE state='running'").fetchone()[0]
            if active >= self.workers:
                return None
            row = conn.execute('''SELECT i.*,j.user_id FROM download_job_items i
                JOIN download_jobs j ON j.id=i.job_id WHERE i.state='queued' AND j.cancel_requested=0
                AND NOT EXISTS(SELECT 1 FROM download_job_items active
                               WHERE active.job_id=i.job_id AND active.state='running')
                ORDER BY j.created_at,i.item_index LIMIT 1''').fetchone()
            if not row:
                return None
            token = str(uuid.uuid4())
            conn.execute("UPDATE download_job_items SET state='running',lease_token=?,lease_until=? WHERE job_id=? AND item_index=?",
                         (token, now + self.lease_seconds, row['job_id'], row['item_index']))
            conn.execute("UPDATE download_jobs SET state='running',updated_at=? WHERE id=?", (now, row['job_id']))
            return {'job_id': row['job_id'], 'index': row['item_index'], 'user_id': row['user_id'],
                    'payload': json.loads(row['payload']), 'token': token}

    def _cancelled(self, item):
        if self._stop.is_set():
            return True
        with closing(self.database.get_connection()) as conn:
            row = conn.execute('''SELECT j.cancel_requested,i.lease_token,i.lease_until FROM download_job_items i
                JOIN download_jobs j ON j.id=i.job_id WHERE i.job_id=? AND i.item_index=?''',
                               (item['job_id'], item['index'])).fetchone()
            return (not row or row['cancel_requested'] or row['lease_token'] != item['token']
                    or row['lease_until'] <= self.clock())

    def _finish(self, item, result=None, error=False):
        with closing(self.database.get_connection()) as conn, conn:
            conn.execute('BEGIN IMMEDIATE')
            row = conn.execute('''SELECT i.lease_token,j.cancel_requested FROM download_job_items i
                JOIN download_jobs j ON j.id=i.job_id WHERE i.job_id=? AND i.item_index=?''',
                               (item['job_id'], item['index'])).fetchone()
            if not row or row['lease_token'] != item['token']:
                return
            state = ('cancelled' if row['cancel_requested'] else 'queued' if self._stop.is_set() else 'failed') if error else 'succeeded'
            payload = item['payload']
            saved = None
            if state != 'queued':
                saved = {key: payload[key] for key in ('title', 'artist', 'album', 'source_id', 'url', 'spotify_id') if key in payload}
                saved.update(success=state == 'succeeded', index=item['index'])
                if state == 'succeeded':
                    saved.update({key: result[key] for key in ('filename', 'title', 'artist', 'album', 'source_id') if key in result})
                else:
                    saved['error'] = 'Cancelled' if state == 'cancelled' else 'Download failed. Please retry.'
            conn.execute('''UPDATE download_job_items SET state=?,result=?,lease_token=NULL,lease_until=NULL
                WHERE job_id=? AND item_index=? AND lease_token=?''',
                         (state, json.dumps(saved) if saved else None, item['job_id'], item['index'], item['token']))
            self._refresh(conn, item['job_id'])

    def _worker(self):
        while not self._stop.is_set():
            try:
                item = self._claim()
                if item:
                    with self._lock:
                        self._active[item['token']] = item
                    try:
                        if self._cancelled(item):
                            self._finish(item, error=True)
                        else:
                            result = self.callback(item['payload'], item['user_id'], lambda: self._cancelled(item))
                            if not isinstance(result, dict) or not result.get('filename'):
                                raise ValueError('Download did not return a completed file.')
                            self._finish(item, result=result)
                    except Exception:
                        self._finish(item, error=True)
                    finally:
                        with self._lock:
                            self._active.pop(item['token'], None)
                    self._wake.set()
                    continue
            except Exception:
                # A transient database lock must not permanently kill a worker.
                # A claimed item stays recoverable through its persisted lease.
                pass
            self._wake.wait(self.poll_seconds)
            self._wake.clear()

    def _renew_leases(self):
        with self._lock:
            tokens = list(self._active)
        if not tokens:
            return
        now = self.clock()
        with closing(self.database.get_connection()) as conn, conn:
            conn.executemany('''UPDATE download_job_items SET lease_until=?
                WHERE state='running' AND lease_token=? AND lease_until>?''',
                             [(now + self.lease_seconds, token, now) for token in tokens])

    def _heartbeat(self):
        while not self._stop.wait(min(5, self.lease_seconds / 3)):
            try:
                self._renew_leases()
            except Exception:
                # Losing a lease cancels the callback; another worker can recover it.
                pass
