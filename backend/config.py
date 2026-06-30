import os
from pathlib import Path
from dotenv import load_dotenv

# Load environment variables, resolved by absolute path (not CWD) so the server
# finds creds no matter where it is launched from or which .env holds them.
# backend/.env is loaded FIRST so its JWT_SECRET_KEY wins (override=False below),
# then the repo-root .env fills in anything missing (e.g. CLIENT_ID/CLIENT_SECRET).
_BACKEND_DIR = Path(__file__).resolve().parent      # .../myMusic/backend
_ROOT_DIR = _BACKEND_DIR.parent                       # .../myMusic
load_dotenv(_BACKEND_DIR / ".env")
load_dotenv(_ROOT_DIR / ".env", override=False)

class Settings:
    # Spotify Configuration
    # Variables will be loaded from .env, or return None if not found
    SPOTIFY_CLIENT_ID = os.getenv("CLIENT_ID")
    SPOTIFY_CLIENT_SECRET = os.getenv("CLIENT_SECRET")
    
    # Redirect URI is required by Spotify dashboard
    # Use loopback address as recommended by Spotify security guidelines
    SPOTIFY_REDIRECT_URI = "http://127.0.0.1:8000/callback"
    
    # Database Configuration
    DATABASE_URL = "sqlite:///./music_app.db"

    # Auth Configuration
    JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY", "change-me-in-production")
    JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
    JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "10080"))

settings = Settings()
