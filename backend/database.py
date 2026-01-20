import sqlite3
import json
import time
from datetime import datetime
from config import settings

class Database:
    def __init__(self):
        self.db_url = settings.DATABASE_URL.replace("sqlite:///", "")
        self.init_db()

    def get_connection(self):
        conn = sqlite3.connect(self.db_url)
        conn.row_factory = sqlite3.Row
        return conn

    def init_db(self):
        conn = self.get_connection()
        cursor = conn.cursor()
        
        # History table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            song_title TEXT NOT NULL,
            artist TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            duration_played REAL,
            spotify_id TEXT
        )
        ''')
        
        # Spotify Cache table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS spotify_cache (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            expiry REAL NOT NULL
        )
        ''')
        
        # Genre tracking table - tracks user's genre preferences
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS genre_counts (
            genre TEXT PRIMARY KEY,
            count INTEGER DEFAULT 0,
            last_played DATETIME
        )
        ''')
        
        conn.commit()
        conn.close()

    def add_history(self, song_title, artist, duration_played, spotify_id=None):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        INSERT INTO history (song_title, artist, duration_played, spotify_id, timestamp)
        VALUES (?, ?, ?, ?, ?)
        ''', (song_title, artist, duration_played, spotify_id, datetime.now()))
        conn.commit()
        conn.close()

    def get_recent_history(self, limit=50):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT * FROM history 
        ORDER BY timestamp DESC 
        LIMIT ?
        ''', (limit,))
        rows = cursor.fetchall()
        conn.close()
        return [dict(row) for row in rows]

    def get_top_artists(self, limit=10):
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT artist, COUNT(*) as count 
        FROM history 
        GROUP BY artist 
        ORDER BY count DESC 
        LIMIT ?
        ''', (limit,))
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

    def increment_genres(self, genres):
        """Increment play count for genres based on what user listens to"""
        if not genres:
            return
        conn = self.get_connection()
        cursor = conn.cursor()
        for genre in genres:
            cursor.execute('''
            INSERT INTO genre_counts (genre, count, last_played) 
            VALUES (?, 1, ?)
            ON CONFLICT(genre) DO UPDATE SET 
                count = count + 1,
                last_played = ?
            ''', (genre, datetime.now(), datetime.now()))
        conn.commit()
        conn.close()

    def get_top_genres(self, limit=5):
        """Get user's top genres by play count"""
        conn = self.get_connection()
        cursor = conn.cursor()
        cursor.execute('''
        SELECT genre, count FROM genre_counts 
        ORDER BY count DESC LIMIT ?
        ''', (limit,))
        rows = cursor.fetchall()
        conn.close()
        return [row['genre'] for row in rows]

db = Database()

