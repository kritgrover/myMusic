import sqlite3
import json
import time
import uuid
from datetime import datetime
from config import settings
from auth_utils import verify_password

class Database:
    def __init__(self):
        self.db_url = settings.DATABASE_URL.replace("sqlite:///", "")
        self.init_db()
        # Clean up expired cache entries on startup
        self.cleanup_expired_cache()

    def get_connection(self):
        # check_same_thread=False allows the connection to be used across threads
        # This is safe because we create a new connection per operation
        conn = sqlite3.connect(self.db_url, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    def init_db(self):
        conn = self.get_connection()
        cursor = conn.cursor()

        # Users table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            is_active INTEGER DEFAULT 1,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
        ''')
        self._ensure_column(cursor, "users", "tagline", "TEXT")

        # History table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER,
            song_title TEXT NOT NULL,
            artist TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            duration_played REAL,
            spotify_id TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
        ''')
        self._ensure_column(cursor, "history", "user_id", "INTEGER")
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_history_user_id_timestamp ON history(user_id, timestamp DESC)')

        # Spotify Cache table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS spotify_cache (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            expiry REAL NOT NULL
        )
        ''')

        # Legacy genre table (kept for backward compatibility with existing DBs)
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS genre_counts (
            genre TEXT PRIMARY KEY,
            count INTEGER DEFAULT 0,
            last_played DATETIME
        )
        ''')

        # User-scoped genre table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS genre_counts_user (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            genre TEXT NOT NULL,
            count INTEGER DEFAULT 0,
            last_played DATETIME,
            UNIQUE(user_id, genre),
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
        ''')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_genre_counts_user_id ON genre_counts_user(user_id)')

        # User-scoped playlists
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS playlists (
            id TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            cover_image TEXT,
            created_at DATETIME NOT NULL,
            updated_at DATETIME NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
        ''')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_playlists_user_id ON playlists(user_id)')

        cursor.execute('''
        CREATE TABLE IF NOT EXISTS playlist_songs (
            id TEXT PRIMARY KEY,
            playlist_id TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT,
            album TEXT,
            filename TEXT,
            file_path TEXT,
            url TEXT,
            thumbnail TEXT,
            duration REAL,
            created_at DATETIME NOT NULL,
            FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
        )
        ''')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_playlist_songs_playlist_id ON playlist_songs(playlist_id)')
        
        conn.commit()
        conn.close()

    def _ensure_column(self, cursor, table_name, column_name, column_type):
        cursor.execute(f"PRAGMA table_info({table_name})")
        columns = {row["name"] for row in cursor.fetchall()}
        if column_name not in columns:
            cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {column_type}")

    # Users
    def create_user(self, username, password_hash):
        conn = self.get_connection()
        cursor = conn.cursor()
        try:
            cursor.execute('''
            INSERT INTO users (username, password_hash, is_active, created_at)
            VALUES (?, ?, 1, ?)
            ''', (username, password_hash, datetime.now()))
            conn.commit()
            user_id = cursor.lastrowid
            return self.get_user_by_id(user_id)
        finally:
            conn.close()

    def get_user_by_username(self, username):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT * FROM users WHERE username = ?', (username,))
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None

    def get_user_by_id(self, user_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT * FROM users WHERE id = ?', (user_id,))
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None

    def get_user_profile(self, user_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            '''
            SELECT id, username, tagline, created_at
            FROM users
            WHERE id = ?
            ''',
            (user_id,),
        )
        row = cursor.fetchone()
        conn.close()
        return dict(row) if row else None

    def update_user_profile(self, user_id, username, tagline):
        conn = self.get_connection()
        cursor = conn.cursor()
        safe_tagline = tagline.strip() if tagline else ""
        try:
            cursor.execute(
                '''
                UPDATE users
                SET username = ?, tagline = ?
                WHERE id = ?
                ''',
                (username, safe_tagline, user_id),
            )
            changed = cursor.rowcount > 0
            conn.commit()
            if not changed:
                return None
            return self.get_user_profile(user_id)
        except sqlite3.IntegrityError as exc:
            raise ValueError("username_taken") from exc
        finally:
            conn.close()

    def verify_user_credentials(self, username, password):
        user = self.get_user_by_username(username)
        if not user or not user.get("is_active"):
            return None
        if not verify_password(password, user["password_hash"]):
            return None
        return user

    # History
    def add_history(self, user_id, song_title, artist, duration_played, spotify_id=None):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        INSERT INTO history (user_id, song_title, artist, duration_played, spotify_id, timestamp)
        VALUES (?, ?, ?, ?, ?, ?)
        ''', (user_id, song_title, artist, duration_played, spotify_id, datetime.now()))
        conn.commit()
        conn.close()

    def get_recent_history(self, user_id, limit=50):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT * FROM history 
        WHERE user_id = ?
        ORDER BY timestamp DESC 
        LIMIT ?
        ''', (user_id, limit))
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]

    def get_top_artists(self, user_id, limit=10):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT artist, COUNT(*) as count 
        FROM history 
        WHERE user_id = ?
        GROUP BY artist 
        ORDER BY count DESC 
        LIMIT ?
        ''', (user_id, limit))
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]

    def get_history_summary(self, user_id, start_ts, end_ts):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            '''
            SELECT
                COUNT(*) AS plays,
                COALESCE(SUM(duration_played), 0.0) AS total_duration_played,
                COUNT(DISTINCT artist) AS unique_artists
            FROM history
            WHERE user_id = ?
              AND timestamp >= ?
              AND timestamp < ?
            ''',
            (user_id, start_ts, end_ts),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return {"plays": 0, "total_duration_played": 0.0, "unique_artists": 0}
        return {
            "plays": int(row["plays"] or 0),
            "total_duration_played": float(row["total_duration_played"] or 0.0),
            "unique_artists": int(row["unique_artists"] or 0),
        }

    def get_top_artists_in_range(self, user_id, start_ts, end_ts, limit=5):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            '''
            SELECT artist, COUNT(*) AS count
            FROM history
            WHERE user_id = ?
              AND timestamp >= ?
              AND timestamp < ?
            GROUP BY artist
            ORDER BY count DESC
            LIMIT ?
            ''',
            (user_id, start_ts, end_ts, limit),
        )
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]

    def get_top_tracks_in_range(self, user_id, start_ts, end_ts, limit=5):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute(
            '''
            SELECT song_title, artist, COUNT(*) AS count
            FROM history
            WHERE user_id = ?
              AND timestamp >= ?
              AND timestamp < ?
            GROUP BY song_title, artist
            ORDER BY count DESC, song_title ASC
            LIMIT ?
            ''',
            (user_id, start_ts, end_ts, limit),
        )
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]

    # Cache methods
    def get_cache(self, key):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT data, expiry FROM spotify_cache WHERE key = ?', (key,))
        row = cursor.fetchone()
        conn.close()
        
        if row:
            data, expiry = row
            if time.time() < expiry:
                return json.loads(data)
            else:
                # Expired
                self.delete_cache(key)
        return None

    def set_cache(self, key, data, ttl_seconds=3600):
        conn = self.get_connection()
        cursor = conn.cursor()
        expiry = time.time() + ttl_seconds
        cursor.execute('''
        INSERT OR REPLACE INTO spotify_cache (key, data, expiry)
        VALUES (?, ?, ?)
        ''', (key, json.dumps(data), expiry))
        conn.commit()
        conn.close()

    def delete_cache(self, key):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('DELETE FROM spotify_cache WHERE key = ?', (key,))
        conn.commit()
        conn.close()

    def cleanup_expired_cache(self):
        """Remove all expired cache entries.
        
        This should be called periodically to prevent the cache table
        from growing indefinitely.
        
        Returns:
            int: Number of entries deleted
        """
        conn = self.get_connection()
        cursor = conn.cursor()
        current_time = time.time()
        
        # First, count how many we're about to delete
        cursor.execute('SELECT COUNT(*) FROM spotify_cache WHERE expiry < ?', (current_time,))
        count = cursor.fetchone()[0]
        
        # Delete expired entries
        cursor.execute('DELETE FROM spotify_cache WHERE expiry < ?', (current_time,))
        conn.commit()
        conn.close()
        
        if count > 0:
            print(f"Cleaned up {count} expired cache entries")
        
        return count

    def get_cache_stats(self):
        """Get statistics about the cache.
        
        Returns:
            dict: Cache statistics including total entries and expired count
        """
        conn = self.get_connection()
        cursor = conn.cursor()
        current_time = time.time()
        
        cursor.execute('SELECT COUNT(*) FROM spotify_cache')
        total = cursor.fetchone()[0]
        
        cursor.execute('SELECT COUNT(*) FROM spotify_cache WHERE expiry < ?', (current_time,))
        expired = cursor.fetchone()[0]
        
        conn.close()
        
        return {
            'total_entries': total,
            'expired_entries': expired,
            'valid_entries': total - expired
        }

    def increment_genres(self, user_id, genres):
        """Increment play count for genres based on what user listens to"""
        if not genres:
            return
        conn = self.get_connection()
        cursor = conn.cursor()
        for genre in genres:
            cursor.execute('''
            INSERT INTO genre_counts_user (user_id, genre, count, last_played)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(user_id, genre) DO UPDATE SET 
                count = count + 1,
                last_played = ?
            ''', (user_id, genre, datetime.now(), datetime.now()))
        conn.commit()
        conn.close()

    def get_top_genres(self, user_id, limit=5):
        """Get user's top genres by play count"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT genre, count FROM genre_counts_user
        WHERE user_id = ?
        ORDER BY count DESC LIMIT ?
        ''', (user_id, limit))
        rows = cursor.fetchall()
        conn.close()
        return [row['genre'] for row in rows]

    # Playlists
    def _get_playlist_songs(self, cursor, playlist_id):
        cursor.execute('''
        SELECT id, title, artist, album, filename, file_path, url, thumbnail, duration
        FROM playlist_songs
        WHERE playlist_id = ?
        ORDER BY created_at ASC
        ''', (playlist_id,))
        rows = cursor.fetchall()
        songs = []
        for row in rows:
            songs.append({
                "id": row["id"],
                "title": row["title"],
                "artist": row["artist"] or "",
                "album": row["album"] or "",
                "filename": row["filename"] or "",
                "file_path": row["file_path"] or "",
                "url": row["url"] or "",
                "thumbnail": row["thumbnail"] or "",
                "duration": float(row["duration"] or 0.0),
            })
        return songs

    def _playlist_row_to_dict(self, cursor, row):
        return {
            "id": row["id"],
            "name": row["name"],
            "songs": self._get_playlist_songs(cursor, row["id"]),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "coverImage": row["cover_image"],
        }

    def get_all_playlists(self, user_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT id, name, cover_image, created_at, updated_at
        FROM playlists
        WHERE user_id = ?
        ORDER BY created_at DESC
        ''', (user_id,))
        rows = cursor.fetchall()
        playlists = {}
        for row in rows:
            playlist = self._playlist_row_to_dict(cursor, row)
            playlists[playlist["id"]] = playlist
        conn.close()
        return playlists

    def get_playlist(self, user_id, playlist_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT id, name, cover_image, created_at, updated_at
        FROM playlists
        WHERE user_id = ? AND id = ?
        ''', (user_id, playlist_id))
        row = cursor.fetchone()
        if not row:
            conn.close()
            return None
        playlist = self._playlist_row_to_dict(cursor, row)
        conn.close()
        return playlist

    def create_playlist(self, user_id, name, playlist_id=None, cover_image=None):
        conn = self.get_connection()
        cursor = conn.cursor()
        now = datetime.now().isoformat()
        playlist_id = playlist_id or uuid.uuid4().hex
        cursor.execute('''
        INSERT INTO playlists (id, user_id, name, cover_image, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ''', (playlist_id, user_id, name, cover_image, now, now))
        conn.commit()
        conn.close()
        return self.get_playlist(user_id, playlist_id)

    def update_playlist_name(self, user_id, playlist_id, name):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        UPDATE playlists
        SET name = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        ''', (name, datetime.now().isoformat(), playlist_id, user_id))
        changed = cursor.rowcount > 0
        conn.commit()
        conn.close()
        return changed

    def delete_playlist(self, user_id, playlist_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id FROM playlists WHERE id = ? AND user_id = ?', (playlist_id, user_id))
        existing = cursor.fetchone()
        if not existing:
            conn.close()
            return False
        cursor.execute('DELETE FROM playlist_songs WHERE playlist_id = ?', (playlist_id,))
        cursor.execute('DELETE FROM playlists WHERE id = ? AND user_id = ?', (playlist_id, user_id))
        conn.commit()
        conn.close()
        return True

    def add_song_to_playlist(self, user_id, playlist_id, song):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id FROM playlists WHERE id = ? AND user_id = ?', (playlist_id, user_id))
        existing = cursor.fetchone()
        if not existing:
            conn.close()
            return None

        song_id = song["id"]
        cursor.execute('SELECT id FROM playlist_songs WHERE playlist_id = ? AND id = ?', (playlist_id, song_id))
        if cursor.fetchone():
            conn.close()
            return self.get_playlist(user_id, playlist_id)

        if song.get("filename"):
            cursor.execute(
                'SELECT id FROM playlist_songs WHERE playlist_id = ? AND filename = ?',
                (playlist_id, song.get("filename")),
            )
            if cursor.fetchone():
                conn.close()
                return self.get_playlist(user_id, playlist_id)

        cursor.execute('''
        INSERT INTO playlist_songs (
            id, playlist_id, title, artist, album, filename, file_path, url, thumbnail, duration, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            song.get("id"),
            playlist_id,
            song.get("title"),
            song.get("artist"),
            song.get("album"),
            song.get("filename"),
            song.get("file_path"),
            song.get("url"),
            song.get("thumbnail"),
            song.get("duration"),
            datetime.now().isoformat(),
        ))
        cursor.execute(
            'UPDATE playlists SET updated_at = ? WHERE id = ? AND user_id = ?',
            (datetime.now().isoformat(), playlist_id, user_id),
        )
        conn.commit()
        conn.close()
        return self.get_playlist(user_id, playlist_id)

    def remove_song_from_playlist(self, user_id, playlist_id, song_id):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('SELECT id FROM playlists WHERE id = ? AND user_id = ?', (playlist_id, user_id))
        if not cursor.fetchone():
            conn.close()
            return None
        cursor.execute('DELETE FROM playlist_songs WHERE playlist_id = ? AND id = ?', (playlist_id, song_id))
        if cursor.rowcount > 0:
            cursor.execute(
                'UPDATE playlists SET updated_at = ? WHERE id = ? AND user_id = ?',
                (datetime.now().isoformat(), playlist_id, user_id),
            )
        conn.commit()
        conn.close()
        return self.get_playlist(user_id, playlist_id)

    def update_playlist_cover(self, user_id, playlist_id, cover_image):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        UPDATE playlists
        SET cover_image = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        ''', (cover_image, datetime.now().isoformat(), playlist_id, user_id))
        changed = cursor.rowcount > 0
        conn.commit()
        conn.close()
        return changed

    def clear_song_file_references(self, deleted_filename):
        conn = self.get_connection()
        cursor = conn.cursor()
        normalized = deleted_filename.replace("\\", "/")
        basename = normalized.split("/")[-1]
        cursor.execute('SELECT id, filename FROM playlist_songs WHERE filename IS NOT NULL AND filename != ""')
        rows = cursor.fetchall()
        updated_playlist_ids = set()
        for row in rows:
            song_filename = (row["filename"] or "").replace("\\", "/")
            if (
                song_filename == normalized
                or song_filename.endswith("/" + normalized)
                or song_filename == basename
            ):
                cursor.execute(
                    'UPDATE playlist_songs SET filename = "", file_path = "" WHERE id = ?',
                    (row["id"],),
                )
                cursor.execute('SELECT playlist_id FROM playlist_songs WHERE id = ?', (row["id"],))
                playlist_row = cursor.fetchone()
                if playlist_row:
                    updated_playlist_ids.add(playlist_row["playlist_id"])
        now = datetime.now().isoformat()
        for playlist_id in updated_playlist_ids:
            cursor.execute('UPDATE playlists SET updated_at = ? WHERE id = ?', (now, playlist_id))
        conn.commit()
        conn.close()

db = Database()

